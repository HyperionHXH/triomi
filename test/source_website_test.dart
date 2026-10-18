import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/source/source_website.dart';

void main() {
  test(
    'source homepage preserves public navigation and configured LAN sites',
    () {
      for (final url in [
        'https://mangadex.org/',
        'https://example.org/comics?lang=zh&page=2#popular',
        'https://example.org/#/comics?lang=zh&page=2',
        'https://example.org/#lang=zh&view=popular',
        'http://192.168.1.8:8080/comics',
        'http://localhost:8080/',
      ]) {
        expect(publicSourceWebsiteUri(url).toString(), url);
      }
    },
  );

  test('browser rejects unsafe schemes and exported authentication links', () {
    for (final url in [
      'file:///private/data',
      'intent://reader',
      'javascript:alert(1)',
      'https:///missing-host',
      'https://user:password@example.org/',
      'https://example.org/?access_token=secret',
      'https://example.org/?X-Amz-Signature=secret',
      'https://example.org/?api_key=secret',
      'https://example.org/#token=secret',
      'https://example.org/#/login?token=secret',
      'https://example.org/#/login?lang=zh&access_token=secret',
      'https://example.org/#/login?%74oken=secret',
      'https://example.org/#/login?X-Amz-Signature=secret',
      'https://example.org/#token=secret?view=popular',
      'https://example.org/\\private',
      'https://example.org/\nprivate',
    ]) {
      expect(
        () => publicSourceWebsiteUri(url),
        throwsFormatException,
        reason:
            'A source must not hand credential/request URLs to another browser',
      );
    }
  });
}
