import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;

/// Pure HTML parsing ported from Android E-Hentai 1.6.36 `EhentaiParsers.kt`
/// and the selectors in `Constants.kt`. Uses package:html; jsoup's
/// whitespace-normalized `text()` and `absUrl()` are reproduced below.

const _listTagsSelector = 'div.gt';
const _galleryTitleEn = '#gn';
const _galleryTitleJp = '#gj';
const _galleryCover = '#gd1';
const _galleryMetaRows = '#gdd table tr';
const _galleryUploader = '#gdn a[href]';
const _galleryTagRows = '#taglist table tr';
const _galleryTagNamespace = 'td.tc';
const _galleryDescription = '#gd2';
const _galleryViewerLinks = '#gdt a[href]';
const _galleryPageLinks = 'table.ptt a[href]';
const _galleryPageCountText = 'p.gpc';
const _viewerImage = 'img#img';
const _viewerOriginalLink = 'a[href]';

/// Android `Constants.THUMBNAILS_PER_PAGE` / `MAX_THUMB_PAGES`.
const ehentaiThumbnailsPerPage = 20;
const ehentaiMaxThumbPages = 1000;

Document parseEhentaiHtml(String html) => html_parser.parse(html);

const _blockTags = {
  'address', 'article', 'aside', 'blockquote', 'dd', 'div', 'dl', 'dt',
  'fieldset', 'figcaption', 'figure', 'footer', 'form', 'h1', 'h2', 'h3',
  'h4', 'h5', 'h6', 'header', 'hr', 'li', 'main', 'nav', 'ol', 'p', 'pre',
  'section', 'table', 'tbody', 'td', 'tfoot', 'th', 'thead', 'tr', 'ul',
};

/// jsoup `Element.text()`: block boundaries become spaces, whitespace is
/// collapsed and the result trimmed.
String ehText(Node? node) {
  if (node == null) return '';
  final buffer = StringBuffer();
  void visit(Node current) {
    if (current is Text) {
      buffer.write(current.data);
      return;
    }
    if (current is Element) {
      final block = _blockTags.contains(current.localName);
      if (block || current.localName == 'br') buffer.write(' ');
      for (final child in current.nodes) {
        visit(child);
      }
      if (block) buffer.write(' ');
      return;
    }
    for (final child in current.nodes) {
      visit(child);
    }
  }

  visit(node);
  return buffer.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
}

String _attr(Element element, String name) => element.attributes[name] ?? '';

/// jsoup `absUrl`: empty when the attribute cannot be resolved.
String ehAbsUrl(String baseUrl, String? value) {
  final raw = value?.trim() ?? '';
  if (raw.isEmpty) return '';
  try {
    final resolved = Uri.parse(baseUrl).resolve(raw);
    return resolved.hasScheme ? resolved.toString() : '';
  } on FormatException {
    return '';
  }
}

// ---------------------------------------------------------------------------
// List pages (search results / popular / front page share one structure)
// ---------------------------------------------------------------------------

class EhentaiListEntry {
  const EhentaiListEntry({
    required this.url,
    required this.title,
    this.coverUrl,
    this.tags = const [],
  });

  /// Absolute gallery URL as linked by the page.
  final String url;
  final String title;
  final String? coverUrl;

  /// Inline `namespace:tag` previews (Android `genre`).
  final List<String> tags;
}

bool _containsGlink(Element element) =>
    element.querySelector('.glink') != null;

/// Android `parseMangaList`.
List<EhentaiListEntry> parseEhentaiMangaList(Document doc, String pageUrl) {
  final result = <EhentaiListEntry>[];
  for (final link in doc.querySelectorAll('a[href]')) {
    if (!_attr(link, 'href').contains('/g/')) continue;
    if (!_containsGlink(link)) continue;
    Element? row;
    for (var parent = link.parent; parent != null; parent = parent.parent) {
      if (parent.localName == 'tr' && _containsGlink(parent)) {
        row = parent;
        break;
      }
    }
    if (row == null) {
      for (var parent = link.parent; parent != null; parent = parent.parent) {
        if (_containsGlink(parent) && parent.querySelector('img') != null) {
          row = parent;
          break;
        }
      }
    }
    row ??= link;
    final title = link.querySelector('.glink');
    if (title == null) continue;
    final cover = _parseCoverUrl(row);
    result.add(
      EhentaiListEntry(
        url: ehAbsUrl(pageUrl, link.attributes['href']),
        title: ehText(title),
        coverUrl: cover == null || cover.isEmpty
            ? null
            : ehAbsUrl(pageUrl, cover),
        tags: [
          for (final tag in row.querySelectorAll(_listTagsSelector))
            if (_attr(tag, 'title').trim().isNotEmpty) _attr(tag, 'title'),
        ],
      ),
    );
  }
  return result;
}

List<Element> _selfAndDescendants(Element element, String tag) => [
  if (element.localName == tag) element,
  ...element.querySelectorAll(tag),
];

/// Lazy `data-src` first; skips placeholder GIFs and torrent/arrow icons.
String? _parseCoverUrl(Element row) {
  for (final img in _selfAndDescendants(row, 'img')) {
    final dataSrc = _attr(img, 'data-src');
    final src = dataSrc.trim().isEmpty ? _attr(img, 'src') : dataSrc;
    if (src.startsWith('data:') ||
        src.contains('/g/t.png') ||
        src.contains('/g/td.png')) {
      continue;
    }
    return src;
  }
  return null;
}

/// Reads the user's ten favorite category labels from the favorites page.
List<String> parseEhentaiFavoriteCategoryNames(Document doc) {
  var blocks = doc.querySelectorAll('.nosel > .fp');
  if (blocks.isEmpty) blocks = doc.querySelectorAll('.fp');
  final names = <String>[];
  for (final block in blocks) {
    // jsoup `select("div")` includes the block itself.
    final divs = _selfAndDescendants(block, 'div');
    if (divs.isEmpty) continue;
    final text = ehText(divs.last).trim();
    if (text.isNotEmpty) names.add(text);
  }
  return names.take(10).toList();
}

class AccountTag {
  const AccountTag({
    required this.name,
    required this.watched,
    required this.hidden,
    required this.weight,
  });
  final String name;
  final bool watched;
  final bool hidden;
  final int weight;
}

class AccountTagSet {
  const AccountTagSet({
    required this.numbers,
    required this.selectedNumber,
    required this.selectedName,
    required this.enabled,
    required this.tags,
  });
  final List<int> numbers;
  final int selectedNumber;
  final String? selectedName;
  final bool enabled;
  final List<AccountTag> tags;
}

/// Parses one E-Hentai My Tags set. The same account settings apply to ExHentai.
AccountTagSet parseEhentaiAccountTagSet(Document doc) {
  var options = doc.querySelectorAll(
    '#tagset_outer > div > select > option[value]',
  );
  if (options.isEmpty) {
    options = doc.querySelectorAll('#tagset_outer select option[value]');
  }
  final numbers = <int>[
    ...{
      for (final option in options)
        if (int.tryParse(_attr(option, 'value')) case final value?
            when value > 0)
          value,
    },
  ];
  final selected =
      options.where((o) => o.attributes.containsKey('selected')).firstOrNull ??
      options.firstOrNull;
  final selectedValue = int.tryParse(
    selected == null ? '' : _attr(selected, 'value'),
  );
  final selectedName = selected == null ? null : ehText(selected).trim();
  final tags = <AccountTag>[];
  for (final block in doc.querySelectorAll('#usertags_outer > div')) {
    final id = int.tryParse(block.id.replaceFirst(RegExp('^usertag_'), ''));
    if (id == null || id <= 0) continue;
    final preview = block.querySelector('#tagpreview_$id');
    final name = preview == null ? '' : _attr(preview, 'title').trim();
    if (name.isEmpty) continue;
    bool checked(String selector) =>
        block.querySelector(selector)?.attributes.containsKey('checked') ==
        true;
    final weight = block.querySelector('#tagweight_$id');
    tags.add(
      AccountTag(
        name: name,
        watched: checked('#tagwatch_$id'),
        hidden: checked('#taghide_$id'),
        weight: int.tryParse(weight == null ? '' : _attr(weight, 'value')) ?? 0,
      ),
    );
  }
  return AccountTagSet(
    numbers: numbers,
    selectedNumber: selectedValue != null && selectedValue > 0
        ? selectedValue
        : 1,
    selectedName: selectedName == null || selectedName.isEmpty
        ? null
        : selectedName,
    enabled:
        doc.querySelector('#tagset_enable')?.attributes.containsKey(
          'checked',
        ) ==
        true,
    tags: tags,
  );
}

/// Android `exactTagTerm`: `namespace:"tag$"`.
String? ehentaiExactTagTerm(String raw) {
  final value = ehentaiCanonicalTag(raw);
  if (value == null) return null;
  final index = value.indexOf(':');
  final namespace = value.substring(0, index);
  final tag = value.substring(index + 1);
  return '$namespace:"${tag.replaceAll('"', r'\"')}\$"';
}

/// Android `canonicalTag`: lowercase `namespace:tag` (default namespace `tag`).
String? ehentaiCanonicalTag(String raw) {
  var value = raw.trim();
  if (value.startsWith('~')) value = value.substring(1);
  if (value.startsWith('-')) value = value.substring(1);
  value = value.trim();
  if (value.isEmpty) return null;
  final colon = value.indexOf(':');
  final namespace = (colon < 0 ? 'tag' : value.substring(0, colon))
      .trim()
      .toLowerCase();
  var tag = (colon < 0 ? value : value.substring(colon + 1)).trim();
  if (tag.length >= 2 && tag.startsWith('"') && tag.endsWith('"')) {
    tag = tag.substring(1, tag.length - 1);
  }
  if (tag.endsWith(r'$')) tag = tag.substring(0, tag.length - 1);
  tag = tag.trim().toLowerCase();
  if (tag.isEmpty) return null;
  return '$namespace:$tag';
}

// ---------------------------------------------------------------------------
// Pagination (cursor based: `var nexturl="..."` / `a#dnext`)
// ---------------------------------------------------------------------------

final _nextUrlRegex = RegExp(
  r'''var\s+nexturl\s*=\s*["']([^"']*)["']''',
  caseSensitive: false,
);

/// The next results page, or null on the last page.
String? parseEhentaiNextUrl(String html, [String? currentUrl]) {
  final match = _nextUrlRegex.firstMatch(html)?.group(1);
  if (match != null) {
    final value = match.replaceAll(r'\/', '/').replaceAll('&amp;', '&');
    if (value.isNotEmpty) return value;
  }
  final doc = html_parser.parse(html);
  final link = doc.querySelector('a#dnext[href]');
  if (link != null) {
    final absolute = ehAbsUrl(currentUrl ?? '', link.attributes['href']);
    final value = (absolute.isEmpty ? _attr(link, 'href') : absolute)
        .replaceAll('&amp;', '&');
    if (value.isNotEmpty) return value;
  }
  return currentUrl == null ? null : _parseNumberedNextUrl(doc, currentUrl);
}

/// Toplists use numbered `p` links instead of the `dnext` cursor.
String? _parseNumberedNextUrl(Document doc, String currentUrl) {
  final parsed = Uri.tryParse(currentUrl);
  if (parsed == null || !parsed.hasScheme) return null;
  final segments = parsed.pathSegments;
  if (segments.isEmpty || segments.last != 'toplist.php') return null;
  final currentPage = int.tryParse(parsed.queryParameters['p'] ?? '') ?? 0;
  (int, String)? best;
  for (final link in doc.querySelectorAll(
    'table.ptt a[href], table.ptb a[href]',
  )) {
    final href = ehAbsUrl(currentUrl, link.attributes['href']);
    if (href.isEmpty) continue;
    final page =
        int.tryParse(RegExp(r'[?&]p=(\d+)').firstMatch(href)?.group(1) ?? '') ??
        0;
    if (page <= currentPage) continue;
    if (best == null || page < best.$1) best = (page, href);
  }
  return best?.$2;
}

// ---------------------------------------------------------------------------
// Gallery detail page
// ---------------------------------------------------------------------------

class EhentaiGalleryDetails {
  const EhentaiGalleryDetails({
    required this.title,
    this.coverUrl,
    this.uploader,
    this.tags = const [],
    this.description,
    this.posted,
  });
  final String title;
  final String? coverUrl;
  final String? uploader;
  final List<String> tags;
  final String? description;
  final DateTime? posted;
}

/// Android `parseGalleryDetails`; [fallbackTitle]/[fallbackCover] are the
/// existing manga values.
EhentaiGalleryDetails parseEhentaiGalleryDetails(
  Document doc,
  String pageUrl, {
  String? fallbackTitle,
  String? fallbackCover,
}) {
  final titleEn = ehText(doc.querySelector(_galleryTitleEn));
  final titleJp = ehText(doc.querySelector(_galleryTitleJp));
  final title = titleEn.trim().isNotEmpty
      ? titleEn
      : titleJp.trim().isNotEmpty
      ? titleJp
      : (fallbackTitle ?? '').trim().isNotEmpty
      ? fallbackTitle!
      : throw const FormatException('Gallery page did not contain a title');
  return EhentaiGalleryDetails(
    title: title,
    coverUrl: parseEhentaiGalleryCover(doc, pageUrl) ?? fallbackCover,
    uploader: parseEhentaiUploader(doc),
    tags: parseEhentaiTags(doc),
    description: parseEhentaiDescription(doc),
    posted: parseEhentaiDate(parseEhentaiMeta(doc, 'Posted')),
  );
}

final _coverUrlRegex = RegExp(r'''url\(['"]?(https?://[^)'"]+)['"]?\)''');

/// `#gd1 img[src]`, else the CSS background `url(...)` of a `#gd1` div.
String? parseEhentaiGalleryCover(Document doc, String pageUrl) {
  final img = doc.querySelector('$_galleryCover img[src]');
  if (img != null) {
    final src = ehAbsUrl(pageUrl, img.attributes['src']);
    if (src.trim().isNotEmpty) return src;
  }
  final container = doc.querySelector(_galleryCover);
  if (container == null) return null;
  final div = container
      .querySelectorAll('div')
      .where((e) => _attr(e, 'style').contains('url'))
      .firstOrNull;
  if (div == null) return null;
  return _coverUrlRegex.firstMatch(_attr(div, 'style'))?.group(1);
}

/// Metadata value, e.g. `parseEhentaiMeta(doc, 'Posted')`.
String? parseEhentaiMeta(Document doc, String name) {
  for (final row in doc.querySelectorAll(_galleryMetaRows)) {
    final label = row.querySelector('td.gdt1');
    if (label == null) continue;
    var text = ehText(label);
    while (text.endsWith(':')) {
      text = text.substring(0, text.length - 1);
    }
    if (text.toLowerCase() != name.toLowerCase()) continue;
    final value = row.querySelector('td.gdt2');
    return value == null ? null : ehText(value).trim();
  }
  return null;
}

String? parseEhentaiUploader(Document doc) {
  final link = doc
      .querySelectorAll(_galleryUploader)
      .where((e) => _attr(e, 'href').contains('/uploader/'))
      .firstOrNull;
  return link == null ? null : ehText(link);
}

/// All tags as `namespace:tag` (without namespace column headers).
List<String> parseEhentaiTags(Document doc) {
  final parts = <String>{};
  for (final row in doc.querySelectorAll(_galleryTagRows)) {
    final label = row.querySelector(_galleryTagNamespace);
    if (label == null) continue;
    var namespace = ehText(label);
    while (namespace.endsWith(':')) {
      namespace = namespace.substring(0, namespace.length - 1);
    }
    namespace = namespace.trim();
    if (namespace.isEmpty) continue;
    final cells = row.querySelectorAll('td');
    if (cells.length < 2) continue;
    for (final anchor in cells[1].querySelectorAll('a')) {
      final tag = ehText(anchor).trim();
      if (tag.isNotEmpty) parts.add('$namespace:$tag');
    }
  }
  return parts.toList();
}

/// `#gd2` text with the `#gn`/`#gj` headings stripped.
String? parseEhentaiDescription(Document doc) {
  final container = doc.querySelector(_galleryDescription);
  if (container == null) return null;
  var text = ehText(container).trim();
  for (final selector in const [_galleryTitleEn, _galleryTitleJp]) {
    final heading = doc.querySelector(selector);
    if (heading == null) continue;
    final value = ehText(heading);
    text = text.trim();
    if (text.startsWith(value)) text = text.substring(value.length);
    text = text.trim();
  }
  return text.isEmpty ? null : text;
}

final _pageCountRegex = RegExp(r'(\d+)\s+pages');
final _showingRegex = RegExp(r'of\s+(\d+)\s+images');

/// "Length: N pages", else "Showing x - y of z images"; -1 when unknown.
int parseEhentaiPageCount(Document doc) {
  final length = parseEhentaiMeta(doc, 'Length');
  if (length != null) {
    final value = int.tryParse(
      _pageCountRegex.firstMatch(length)?.group(1) ?? '',
    );
    if (value != null) return value;
  }
  final footer = doc.querySelector(_galleryPageCountText);
  if (footer != null) {
    final value = int.tryParse(
      _showingRegex.firstMatch(ehText(footer))?.group(1) ?? '',
    );
    if (value != null) return value;
  }
  return -1;
}

/// Number of thumbnail pages exposed by the gallery navigation (`?p=N`).
int parseEhentaiThumbnailPageCount(Document doc) {
  int? max;
  for (final link in doc.querySelectorAll(_galleryPageLinks)) {
    final page = int.tryParse(
      RegExp(r'[?&]p=(\d+)').firstMatch(_attr(link, 'href'))?.group(1) ?? '',
    );
    if (page != null && (max == null || page > max)) max = page;
  }
  return max == null ? 1 : max + 1;
}

/// Viewer page URLs of one thumbnail page.
List<String> parseEhentaiViewerLinks(Document doc, String pageUrl) => [
  for (final link in doc.querySelectorAll(_galleryViewerLinks))
    if (_attr(link, 'href').contains('/s/'))
      if (ehAbsUrl(pageUrl, link.attributes['href']) case final url
          when url.trim().isNotEmpty)
        url,
];

/// `/fullimg/` original link when [wantOriginal], else `img#img` src.
String parseEhentaiImageUrl(
  Document doc,
  String pageUrl, {
  required bool wantOriginal,
}) {
  if (wantOriginal) {
    final original = parseEhentaiOriginalLink(doc, pageUrl);
    if (original != null) return original;
  }
  final img = doc.querySelector(_viewerImage);
  final src = img == null ? '' : ehAbsUrl(pageUrl, img.attributes['src']);
  if (src.trim().isEmpty) {
    throw const FormatException(
      'Could not find a non-empty image URL in the viewer page',
    );
  }
  return src;
}

String? parseEhentaiOriginalLink(Document doc, String pageUrl) {
  final link = doc
      .querySelectorAll(_viewerOriginalLink)
      .where((e) => _attr(e, 'href').contains('/fullimg/'))
      .firstOrNull;
  if (link == null) return null;
  final url = ehAbsUrl(pageUrl, link.attributes['href']);
  return url.trim().isEmpty ? null : url;
}

// ---------------------------------------------------------------------------
// Dates
// ---------------------------------------------------------------------------

const _months = [
  'january', 'february', 'march', 'april', 'may', 'june', 'july', 'august',
  'september', 'october', 'november', 'december',
];

/// `yyyy-MM-dd HH:mm` (current) or `dd MMMM yyyy, HH:mm` (legacy). E-Hentai
/// prints these in UTC; null when unparseable (Android's 0L).
DateTime? parseEhentaiDate(String? text) {
  final value = text?.trim() ?? '';
  if (value.isEmpty) return null;
  final current = RegExp(
    r'^(\d{4})-(\d{1,2})-(\d{1,2}) (\d{1,2}):(\d{1,2})',
  ).firstMatch(value);
  if (current != null) {
    return DateTime.utc(
      int.parse(current[1]!),
      int.parse(current[2]!),
      int.parse(current[3]!),
      int.parse(current[4]!),
      int.parse(current[5]!),
    );
  }
  final legacy = RegExp(
    r'^(\d{1,2}) ([A-Za-z]+) (\d{4}), (\d{1,2}):(\d{1,2})',
  ).firstMatch(value);
  if (legacy != null) {
    final month = _months.indexOf(legacy[2]!.toLowerCase());
    if (month < 0) return null;
    return DateTime.utc(
      int.parse(legacy[3]!),
      month + 1,
      int.parse(legacy[1]!),
      int.parse(legacy[4]!),
      int.parse(legacy[5]!),
    );
  }
  return null;
}
