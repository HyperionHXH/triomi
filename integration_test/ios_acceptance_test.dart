import 'ios_anime_metadata_search_test.dart' as anime_search;
import 'ios_chinese_rules_test.dart' as chinese_rules;
import 'ios_ech_http_test.dart' as native_http;
import 'ios_js_runtime_test.dart' as javascript;
import 'ios_mainline_sync_test.dart' as mainline_sync;
import 'ios_reader_ports_test.dart' as reader_ports;
import 'ios_reader_state_test.dart' as reader_state;
import 'ios_source_recovery_test.dart' as source_recovery;
import 'ios_storage_live_test.dart' as storage;
import 'ios_video_live_test.dart' as video;

/// One simulator launch, all existing real-runtime scenarios. Keep individual
/// entrypoints runnable for focused diagnosis without rebuilding three apps in CI.
void main() {
  native_http.main();
  javascript.main();
  chinese_rules.main();
  reader_ports.main();
  source_recovery.main();
  anime_search.main();
  mainline_sync.main();
  reader_state.main();
  storage.main();
  video.main();
}
