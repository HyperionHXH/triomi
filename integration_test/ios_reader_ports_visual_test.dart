import '../test/manga_reader_scroll_regression_test.dart' as reader_scroll;
import '../test/reader_ports_ui_test.dart' as reader_ports_ui;
import 'fixtures/ios_test_binding.dart';

void main() {
  initializeIosIntegrationBinding();
  reader_ports_ui.main();
  reader_scroll.main();
}
