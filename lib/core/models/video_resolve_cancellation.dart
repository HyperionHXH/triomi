import 'package:flutter/foundation.dart';

/// One foreground browser operation. Never share this owner between jobs.
class VideoResolveCancellation extends ChangeNotifier {
  String? _reason;
  bool get isCancelled => _reason != null;
  String get reason => _reason ?? '网页解析已取消，请在前台继续下载';

  void cancel([String reason = '网页解析已取消，请在前台继续下载']) {
    if (isCancelled) return;
    _reason = reason;
    notifyListeners();
  }
}

class VideoResolveCancelled extends StateError {
  VideoResolveCancelled(super.message);
}
