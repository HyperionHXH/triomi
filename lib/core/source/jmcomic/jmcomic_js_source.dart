import '../http_client.dart';
import '../js/js_runtime.dart';
import '../js/js_source.dart';
import '../rule_schema.dart';
import 'jmcomic_client.dart';

class JmcomicJsSource extends JsSource {
  factory JmcomicJsSource({
    required SourceRule rule,
    required JsRuntime runtime,
    required SourceHttpClient http,
  }) {
    if (rule.descriptor.id != 'jmcomic' ||
        rule.descriptor.nsfw != true ||
        !const [
          'https://18comic.vip',
          'https://18comic.ink',
          'https://jmcomic-zzz.one',
          'https://jmcomic-zzz.org',
        ].contains(rule.baseUrl)) {
      throw const RuleFormatException('JM 规则需要声明官方镜像和 NSFW 分级');
    }
    return JmcomicJsSource._(rule, runtime, JmcomicClient(http));
  }
  JmcomicJsSource._(SourceRule rule, JsRuntime runtime, this.client)
    : super(rule: rule, runtime: runtime, http: client);
  final JmcomicClient client;

  @override
  void dispose() {
    client.close();
    super.dispose();
  }
}
