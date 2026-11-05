import 'package:flutter_test/flutter_test.dart';

import 'anime_metadata_search_test.dart' as search;

/// Match integration_test's input registration so reconnect bugs fail locally.
class _NativeInputBinding extends AutomatedTestWidgetsFlutterBinding {
  @override
  bool get registerTestTextInput => false;
}

void main() {
  _NativeInputBinding();
  search.main();
}
