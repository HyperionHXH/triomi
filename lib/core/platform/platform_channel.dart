import 'package:flutter/services.dart';

/// 平台能力通道（`triomi/platform`）的 Dart 侧封装。
///
/// 约定：所有方法在平台未实现（测试环境 / 桌面端）或调用失败时静默降级
/// （返回 null / false），不向调用方抛错——阅读器不该因平台差异崩溃。
class PlatformChannel {
  const PlatformChannel._();

  static const MethodChannel _channel = MethodChannel('triomi/platform');

  /// 屏幕常亮（Android FLAG_KEEP_SCREEN_ON）。
  Future<void> setKeepScreenOn(bool enabled) async {
    try {
      await _channel.invokeMethod<bool>('keepScreenOn', enabled);
    } on PlatformException {
      // 平台实现缺失或调用失败：静默降级。
    } on MissingPluginException {
      // 非 Android 平台。
    }
  }

  /// 保存图片到系统相册（Android MediaStore，Pictures/Triomi 目录）。
  ///
  /// 返回内容 URI；失败返回 null（Android 10+ 不需要存储权限）。
  Future<String?> saveImageToGallery(Uint8List bytes, String fileName) async {
    try {
      return await _channel.invokeMethod<String>(
        'saveImageToGallery',
        <String, Object?>{'bytes': bytes, 'fileName': fileName},
      );
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}

/// 全局单例（无状态，直接用）。
const PlatformChannel platformChannel = PlatformChannel._();
