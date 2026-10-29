import 'package:flutter/material.dart';

/// Native XCTest owns all activity in this host. Do not start production source
/// loading, backup recovery or cache maintenance concurrently with bridge tests.
/// Real TriomiApp behavior is exercised separately by the iOS acceptance suite
/// and production visual tour; this entrypoint never enters the release IPA.
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(home: Scaffold(body: SizedBox.expand())));
}
