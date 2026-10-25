import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

bool _initialized = false;

/// XCTest requests accessibility after Dart starts. Establish the enabled
/// platform semantics owner before testWidgets records its leak baseline.
/// Semantics remain enabled, and test-owned handles are still leak-checked.
void initializeIosIntegrationBinding() {
  if (_initialized) return;
  _initialized = true;
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.platformDispatcher.semanticsEnabledTestValue = true;
  tearDownAll(binding.platformDispatcher.clearSemanticsEnabledTestValue);
}
