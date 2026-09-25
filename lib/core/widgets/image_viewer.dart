import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../platform/platform_channel.dart';
import '../source/http_client.dart';
import '../source/source_providers.dart';
import '../theme/app_tokens.dart';

/// 全屏图片查看器：缩放拖动、系统返回退出、长按保存到相册。
///
/// 小说插图与漫画页共用。零插件：保存走 MethodChannel（MediaStore）。
Future<void> showImageViewer(
  BuildContext context, {
  required String imageUrl,
  required String sourceId,
  String? heroTag,
}) {
  return Navigator.of(context, rootNavigator: true).push(
    PageRouteBuilder<void>(
      opaque: false,
      barrierColor: Colors.black,
      pageBuilder: (context, animation, secondaryAnimation) =>
          _ImageViewerPage(imageUrl: imageUrl, sourceId: sourceId),
      transitionsBuilder: (context, animation, secondaryAnimation, child) =>
          FadeTransition(opacity: animation, child: child),
    ),
  );
}

class _ImageViewerPage extends StatefulWidget {
  const _ImageViewerPage({required this.imageUrl, required this.sourceId});

  final String imageUrl;
  final String sourceId;

  @override
  State<_ImageViewerPage> createState() => _ImageViewerPageState();
}

class _ImageViewerPageState extends State<_ImageViewerPage> {
  final TransformationController _transform = TransformationController();

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: <Widget>[
          Positioned.fill(
            child: GestureDetector(
              onLongPress: _saveToGallery,
              child: InteractiveViewer(
                transformationController: _transform,
                maxScale: 5.0,
                child: Center(
                  child: Image.network(
                    widget.imageUrl,
                    fit: BoxFit.contain,
                    loadingBuilder: (context, child, progress) {
                      if (progress == null) return child;
                      return Center(
                        child: CircularProgressIndicator(
                          value: progress.expectedTotalBytes == null
                              ? null
                              : progress.cumulativeBytesLoaded /
                                    progress.expectedTotalBytes!,
                        ),
                      );
                    },
                    errorBuilder: (context, error, stack) => const Center(
                      child: Text(
                        '图片加载失败',
                        style: TextStyle(color: Colors.white70),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          SafeArea(
            child: Align(
              alignment: Alignment.topRight,
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.sm),
                child: IconButton(
                  icon: const Icon(Icons.close, color: Colors.white),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _saveToGallery() => saveImageWithFeedback(
    context,
    imageUrl: widget.imageUrl,
    sourceId: widget.sourceId,
  );
}

/// 长按保存到相册：加载字节（本地读文件 / 网络走统一网络层）→
/// MethodChannel（MediaStore）→ SnackBar 反馈。
Future<void> saveImageWithFeedback(
  BuildContext context, {
  required String imageUrl,
  required String sourceId,
}) async {
  final bytes = await loadImageBytes(
    imageUrl,
    sourceId: sourceId,
    http: ProviderScope.containerOf(
      context,
      listen: false,
    ).read(sourceHttpClientProvider),
  );
  if (!context.mounted) return;
  if (bytes == null) {
    _showToast(context, '图片数据获取失败');
    return;
  }
  final fileName = 'triomi-${DateTime.now().millisecondsSinceEpoch}.png';
  final uri = await platformChannel.saveImageToGallery(bytes, fileName);
  if (!context.mounted) return;
  _showToast(context, uri == null ? '保存失败' : '已保存到相册（Pictures/Triomi）');
}

/// 加载图片字节：本地路径直接读文件；网络图走 [SourceHttpClient.fetchBytes]
/// （统一 UA / 超时 / 错误分类）。
Future<Uint8List?> loadImageBytes(
  String url, {
  required String sourceId,
  SourceHttpClient? http,
}) async {
  if (url.startsWith('http://') || url.startsWith('https://')) {
    if (http == null) return null;
    try {
      final data = await http.fetchBytes(url, sourceId: sourceId);
      return Uint8List.fromList(data);
    } catch (_) {
      return null;
    }
  }
  try {
    final file = File(url);
    return await file.exists() ? await file.readAsBytes() : null;
  } catch (_) {
    return null;
  }
}

void _showToast(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}
