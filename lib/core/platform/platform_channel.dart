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

  /// SAF 目录选择器（ACTION_OPEN_DOCUMENT_TREE），返回 tree URI。
  /// 用户取消或平台不支持时返回 null。
  Future<String?> pickDirectory() async {
    try {
      return await _channel.invokeMethod<String>('pickDirectory');
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// 向授权目录写文件（DocumentsContract.createDocument）。
  ///
  /// 失败抛 [PlatformException]——调用方（备份导出）据此回退应用私有目录。
  Future<String?> writeToTree(
    String treeUri,
    String fileName,
    Uint8List bytes,
  ) {
    return _channel.invokeMethod<String>('writeToTree', <String, Object?>{
      'treeUri': treeUri,
      'fileName': fileName,
      'bytes': bytes,
      'mime': 'application/zip',
    });
  }

  /// 注册 / 取消后台更新提醒（Android JobScheduler 周期任务）。
  ///
  /// 返回是否登记成功；平台未实现（桌面端 / 测试）时返回 false。
  Future<bool> scheduleBackgroundCheck(bool enabled) async {
    try {
      final ok = await _channel.invokeMethod<bool>(
        'scheduleBackgroundCheck',
        enabled,
      );
      return ok ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 后台更新提醒当前是否已在系统里排程。
  Future<bool> backgroundCheckScheduled() async {
    try {
      final ok = await _channel.invokeMethod<bool>('backgroundCheckScheduled');
      return ok ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 申请通知权限（Android 13+ 是运行时权限）。
  ///
  /// 低版本或已授权时直接返回 true；用户拒绝返回 false。
  Future<bool> requestNotificationPermission() async {
    try {
      final granted = await _channel.invokeMethod<bool>(
        'requestNotificationPermission',
      );
      return granted ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 选一张图片（评论配图用，SAF `ACTION_OPEN_DOCUMENT` + `image/*`）。
  ///
  /// 用户取消 / 平台不支持时返回 null；失败抛 [PlatformException]，
  /// 由调用方决定怎么提示（选图失败与上传失败要给不同的话术）。
  Future<PickedImage?> pickImage() async {
    try {
      final raw = await _channel.invokeMethod<Object?>('pickImage');
      if (raw is! Map) return null;
      final bytes = raw['bytes'];
      if (bytes is! Uint8List || bytes.isEmpty) return null;
      return PickedImage(
        bytes: bytes,
        fileName: '${raw['name'] ?? 'comment.jpg'}',
        mimeType: '${raw['mime'] ?? 'image/jpeg'}',
      );
    } on MissingPluginException {
      // 非 Android 平台：没有系统选择器。
      return null;
    }
  }
}

/// 用户选中的图片（字节 + 原始文件名 + MIME）。
class PickedImage {
  const PickedImage({
    required this.bytes,
    required this.fileName,
    required this.mimeType,
  });

  final Uint8List bytes;
  final String fileName;
  final String mimeType;

  int get sizeInBytes => bytes.length;
}

/// 全局单例（无状态，直接用）。
const PlatformChannel platformChannel = PlatformChannel._();
