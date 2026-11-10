import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

bool _initialized = false;

/// XCTest requests accessibility after Dart starts. Establish the enabled
/// platform semantics owner before testWidgets records its leak baseline.
/// Semantics remain enabled, and test-owned handles are still leak-checked.
void initializeIosIntegrationBinding() {
  if (_initialized) return;
  _initialized = true;
  final binding = const bool.fromEnvironment('TRIOMI_DEVICE_ACCEPTANCE')
      ? _UsbAcceptanceBinding()
      : IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.platformDispatcher.semanticsEnabledTestValue = true;
  tearDownAll(binding.platformDispatcher.clearSemanticsEnabledTestValue);
}

// Unit scenarios inject editing updates rather than drive a hardware keyboard.
// In release, the framework ignores the debug-only client -1 used by an
// unregistered TestTextInput. Register a real test client for USB acceptance.
class _UsbAcceptanceBinding extends IntegrationTestWidgetsFlutterBinding {
  @override
  bool get registerTestTextInput => true;
}

Future<void> captureIosDeviceEvidence(String name) async {
  if (!const bool.fromEnvironment('TRIOMI_DEVICE_ACCEPTANCE')) return;
  final documents = await getApplicationDocumentsDirectory();
  final runId = await File('${documents.path}/device-run-id.txt')
      .readAsString();
  final key = '$runId:$name';
  // Flutter raster screenshots omit the AVPlayer platform layer. Ask the USB
  // host for an actual display screenshot and wait until it acknowledges it.
  await File('${documents.path}/device-capture.json')
      .writeAsString(jsonEncode({'runId': runId, 'name': name}), flush: true);
  final ack = File('${documents.path}/device-capture-ack.txt');
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  while (DateTime.now().isBefore(deadline)) {
    if (await ack.exists() && await ack.readAsString() == key) return;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  throw StateError('USB host did not capture $name');
}
