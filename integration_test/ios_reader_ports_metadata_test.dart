// Real anonymous metadata only. Failure remains a failure; no image/UI claim.
import '../tools/live_reader_ports_probe.dart' as metadata;
import 'fixtures/ios_test_binding.dart';

void main() {
  initializeIosIntegrationBinding();
  metadata.main();
}
