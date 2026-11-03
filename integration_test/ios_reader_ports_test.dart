// Synthetic source contracts. This entry is also part of iOS acceptance.
import '../test/host_features_test.dart' as host_features;
import '../test/jmcomic_client_test.dart' as jmcomic_client;
import '../test/jmcomic_image_test.dart' as jmcomic_image;
import '../test/jmcomic_js_rule_test.dart' as jmcomic;
import '../test/reader_ports_pipeline_test.dart' as pipeline;
import '../test/reader_ports_registry_test.dart' as registry;
import '../test/wnacg_js_rule_test.dart' as wnacg;
import 'fixtures/ios_test_binding.dart';
import 'ios_ehentai_test.dart' as ehentai;
import 'ios_picacomic_test.dart' as picacomic;

void main() {
  initializeIosIntegrationBinding();
  host_features.main();
  picacomic.main();
  registry.main();
  pipeline.main();
  wnacg.main();
  jmcomic.main();
  jmcomic_client.main();
  jmcomic_image.main();
  ehentai.main();
}
