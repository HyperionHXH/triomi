import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:xpath_selector/xpath_selector.dart';

/// 字段提取规则。
///
/// 一条规则从「取哪个元素」到「取元素上的什么值」再到「怎么加工」：
/// - [selector]：CSS 选择器（`.item a`）或 XPath（`.//a`、`//a/@href`）；
///   以 `.//` / `./` 开头表示相对当前节点，`//` 开头表示相对整个文档。
/// - [attr]：`text`（默认）/ `html` / 任意属性名。
/// - [regex]：命中后的进一步提取，配合 [group] 取捕获组。
/// - [absolute]：把取到的相对地址补全为绝对地址（需要 baseUrl）。
class FieldSpec {
  const FieldSpec({
    required this.selector,
    this.attr = 'text',
    this.regex,
    this.group = 1,
    this.trim = true,
    this.absolute = false,
  });

  final String selector;
  final String attr;
  final String? regex;
  final int group;
  final bool trim;
  final bool absolute;

  static FieldSpec? parse(Object? value) {
    if (value == null) return null;
    if (value is String) {
      return value.trim().isEmpty ? null : parseInline(value);
    }
    if (value is Map) {
      final selector = value['selector']?.toString() ?? '';
      if (selector.trim().isEmpty) return null;
      return FieldSpec(
        selector: selector,
        attr: value['attr']?.toString() ?? 'text',
        regex: value['regex']?.toString(),
        group: int.tryParse(value['group']?.toString() ?? '') ?? 1,
        trim: value['trim']?.toString() != 'false',
        absolute: value['absolute']?.toString() == 'true',
      );
    }
    return null;
  }

  /// 简写形式：`img.cover@data-src`（`@` 后面是属性名，省略则取 `text`）。
  static FieldSpec parseInline(String raw, {String defaultAttr = 'text'}) {
    final value = raw.trim();
    final at = value.lastIndexOf('@');
    if (at > 0 && at < value.length - 1) {
      return FieldSpec(
        selector: value.substring(0, at),
        attr: value.substring(at + 1),
      );
    }
    return FieldSpec(selector: value, attr: defaultAttr);
  }
}

/// 选择器命中的一个节点。
///
/// 同时保存所属文档根节点，用于支持 `//` 这类文档级 XPath 查询。
class HtmlNode {
  HtmlNode.fromElement(this.element, {this.documentRoot, this.directAttribute});

  final dom.Element element;

  /// 文档根元素（用于文档级 XPath）。
  final dom.Element? documentRoot;

  /// XPath 直接选中属性时（如 `//a/@href`），值在这里。
  final String? directAttribute;

  /// 按 [attr] 取值：`text` / `html` / 属性名。
  String? value(String attr) {
    switch (attr) {
      case 'text':
        return directAttribute ?? element.text;
      case 'html':
        return directAttribute ?? element.innerHtml;
      case 'outerHtml':
        return directAttribute ?? element.outerHtml;
      default:
        return directAttribute ?? element.attributes[attr];
    }
  }

  /// 节点自身的 HTML 片段（用于在列表项内部继续提取）。
  String get outerHtml => element.outerHtml;
}

/// 选择器引擎：CSS 与 XPath 双语法。
abstract final class HtmlSelector {
  /// 判断是否按 XPath 处理。
  static bool looksLikeXPath(String selector) {
    final value = selector.trimLeft();
    return value.startsWith('//') ||
        value.startsWith('.//') ||
        value.startsWith('./');
  }

  /// 是否为相对选择器（相对当前节点）。
  static bool isRelative(String selector) {
    final value = selector.trimLeft();
    return value.startsWith('.//') || value.startsWith('./');
  }

  /// 在整篇 HTML 里查询。
  static List<HtmlNode> selectAll(String html, String selector) {
    final document = html_parser.parse(html);
    return selectInDocument(document, selector);
  }

  static HtmlNode? selectFirst(String html, String selector) {
    final nodes = selectAll(html, selector);
    return nodes.isEmpty ? null : nodes.first;
  }

  /// 在已解析的文档里查询（避免同一份 HTML 反复解析）。
  static List<HtmlNode> selectInDocument(
    dom.Document document,
    String selector,
  ) {
    final root = document.documentElement;
    if (root == null) return const <HtmlNode>[];

    if (looksLikeXPath(selector)) {
      final result = XPath<dom.Element>(_HtmlXPathNode(root)).query(selector);
      final nodes = <HtmlNode>[];
      for (var index = 0; index < result.nodes.length; index++) {
        nodes.add(
          HtmlNode.fromElement(
            result.nodes[index].node,
            documentRoot: root,
            directAttribute: index < result.attrs.length
                ? result.attrs[index]
                : null,
          ),
        );
      }
      return nodes;
    }

    return <HtmlNode>[
      for (final element in document.querySelectorAll(selector))
        HtmlNode.fromElement(element, documentRoot: root),
    ];
  }

  /// 在某个节点内部查询（字段提取的主要入口）。
  static List<HtmlNode> selectWithin(HtmlNode node, String selector) {
    final query = selector.trim();
    if (query.isEmpty || query == '.') return <HtmlNode>[node];

    if (!looksLikeXPath(query)) {
      return <HtmlNode>[
        for (final element in node.element.querySelectorAll(query))
          HtmlNode.fromElement(element, documentRoot: node.documentRoot),
      ];
    }

    final root = isRelative(query)
        ? _HtmlXPathNode(node.element)
        : _HtmlXPathNode(node.documentRoot ?? node.element);
    final result = XPath<dom.Element>(root).query(query);
    return <HtmlNode>[
      for (var index = 0; index < result.nodes.length; index++)
        HtmlNode.fromElement(
          result.nodes[index].node,
          documentRoot: node.documentRoot,
          directAttribute: index < result.attrs.length
              ? result.attrs[index]
              : null,
        ),
    ];
  }

  /// 取第一个命中值，并按 [FieldSpec] 加工。
  static String? extract(String html, FieldSpec spec, {String? baseUrl}) {
    final nodes = selectAll(html, spec.selector);
    if (nodes.isEmpty) return null;
    return _apply(spec, nodes.first.value(spec.attr), baseUrl: baseUrl);
  }

  /// 在节点内部取第一个命中值。
  static String? extractWithin(
    HtmlNode node,
    FieldSpec spec, {
    String? baseUrl,
  }) {
    final nodes = selectWithin(node, spec.selector);
    if (nodes.isEmpty) return null;
    return _apply(spec, nodes.first.value(spec.attr), baseUrl: baseUrl);
  }

  /// 取全部命中值（用于图片列表这类多值字段）。
  static List<String> extractAll(
    String html,
    FieldSpec spec, {
    String? baseUrl,
  }) {
    final nodes = selectAll(html, spec.selector);
    return _values(nodes, spec, baseUrl: baseUrl);
  }

  static List<String> extractAllWithin(
    HtmlNode node,
    FieldSpec spec, {
    String? baseUrl,
  }) {
    return _values(selectWithin(node, spec.selector), spec, baseUrl: baseUrl);
  }

  static List<String> _values(
    List<HtmlNode> nodes,
    FieldSpec spec, {
    String? baseUrl,
  }) {
    final values = <String>[];
    for (final node in nodes) {
      final processed = _apply(spec, node.value(spec.attr), baseUrl: baseUrl);
      if (processed != null && processed.isNotEmpty) values.add(processed);
    }
    return values;
  }

  static String? _apply(FieldSpec spec, String? raw, {String? baseUrl}) =>
      applyFieldSpec(spec, raw, baseUrl: baseUrl);
}

/// 按字段规则加工原始值：正则提取 → 去空白 → 补全绝对地址。
///
/// 暴露出来是为了让 JSON 响应的取値（点路径）复用同一套加工逻辑，
/// 保证 html 与 json 两种来源的字段语义完全一致。
String? applyFieldSpec(FieldSpec spec, String? raw, {String? baseUrl}) {
  if (raw == null) return null;
  var value = raw;

  final pattern = spec.regex;
  if (pattern != null && pattern.isNotEmpty) {
    final match = RegExp(pattern, dotAll: true).firstMatch(value);
    if (match == null) return null;
    value = match.group(spec.group) ?? match.group(0) ?? '';
  }

  if (spec.trim) value = value.trim();
  if (value.isEmpty) return null;

  if (spec.absolute) {
    final resolved = resolveUrl(baseUrl, value);
    if (resolved != null) value = resolved;
  }
  return value;
}

/// 把正文 HTML 转成纯文本：保留段落换行、去掉标签、还原实体。
String htmlToPlainText(String html) {
  final withBreaks = html
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'</(p|div|section|li)>', caseSensitive: false), '\n');
  final stripped = withBreaks.replaceAll(RegExp(r'<[^>]*>'), '');
  final decoded = html_parser.parseFragment(stripped).text ?? stripped;
  return decoded
      .replaceAll(RegExp(r'[ \t]+\n'), '\n')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();
}

/// 把相对地址补全为绝对地址；已是绝对地址或无法解析时返回原值。
String? resolveUrl(String? baseUrl, String? url) {
  if (url == null) return null;
  final value = url.trim();
  if (value.isEmpty) return null;
  if (value.startsWith('http://') || value.startsWith('https://')) return value;
  if (value.startsWith('data:')) return value;

  if (baseUrl == null || baseUrl.isEmpty) return value;
  final base = Uri.tryParse(baseUrl);
  if (base == null) return value;
  if (value.startsWith('//')) {
    return '${base.scheme}:$value';
  }
  return base.resolve(value).toString();
}

/// `xpath_selector` 需要宿主提供节点模型，这里用 package:html 实现一份。
class _HtmlXPathNode extends XPathNode<dom.Element> {
  _HtmlXPathNode(super.node);

  @override
  NodeTagName? get name {
    final local = node.localName;
    return local == null ? null : NodeTagName(localName: local);
  }

  @override
  String? get text => node.text;

  @override
  XPathNode<dom.Element>? get parent {
    final parentElement = node.parent;
    if (parentElement == null) return null;
    return _HtmlXPathNode(parentElement);
  }

  @override
  List<XPathNode<dom.Element>> get children =>
      node.children.map(_HtmlXPathNode.new).toList();

  @override
  Map<String, String> get attributes => <String, String>{
    for (final entry in node.attributes.entries)
      entry.key.toString(): entry.value,
  };

  @override
  XPathNode<dom.Element>? get nextSibling {
    final next = node.nextElementSibling;
    return next == null ? null : _HtmlXPathNode(next);
  }

  @override
  XPathNode<dom.Element>? get previousSibling {
    final previous = node.previousElementSibling;
    return previous == null ? null : _HtmlXPathNode(previous);
  }

  @override
  bool get isElement => true;

  @override
  bool operator ==(Object other) =>
      other is _HtmlXPathNode && identical(other.node, node);

  @override
  int get hashCode => node.hashCode;
}
