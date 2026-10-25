import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/source/system_proxy.dart';

void main() {
  test(
    'plain IO callers do not initialize a Flutter binding for system routing',
    () async {
      // Deliberately do not call TestWidgetsFlutterBinding.ensureInitialized().
      expect(() => ServicesBinding.instance, throwsA(anything));
      expect(
        await systemProxyForUri(
          Uri.parse('https://next.bgm.tv/p1/subjects/400602/comments'),
        ),
        'DIRECT',
      );
      expect(() => ServicesBinding.instance, throwsA(anything));
    },
  );
}
