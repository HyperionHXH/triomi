import 'ios_ech_http_test.dart' as native_http;
import 'ios_js_runtime_test.dart' as javascript;
import 'ios_storage_live_test.dart' as storage;
import 'ios_video_live_test.dart' as video;

/// One simulator launch, all existing real-runtime scenarios. Keep individual
/// entrypoints runnable for focused diagnosis without rebuilding three apps in CI.
void main() {
  native_http.main();
  javascript.main();
  storage.main();
  video.main();
}
