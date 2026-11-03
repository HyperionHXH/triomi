// Synthetic contracts, not live-site acceptance.
import '../test/ehentai_image_test.dart' as ehentai_image;
import '../test/ehentai_js_rule_test.dart' as ehentai;
import 'fixtures/ios_test_binding.dart';

void main() {
  initializeIosIntegrationBinding();
  ehentai.main();
  ehentai_image.main();
}
