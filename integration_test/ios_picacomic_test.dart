// Synthetic rule and production settings UI contracts, not real account login.
import '../test/picacomic_client_test.dart' as picacomic_client;
import '../test/picacomic_js_rule_test.dart' as picacomic;
import '../test/picacomic_settings_test.dart' as picacomic_settings;
import 'fixtures/ios_test_binding.dart';

void main() {
  initializeIosIntegrationBinding();
  picacomic.main();
  picacomic_client.main();
  picacomic_settings.main();
}
