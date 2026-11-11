import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/source_exception.dart';
import '../platform/platform_channel.dart';
import '../source/http_client.dart';
import '../source/source_providers.dart';
import '../theme/app_tokens.dart';
import 'source_network_image.dart';

/// 全屏图片查看器：缩放拖动、系统返回退出、长按保存图片。
///
/// 小说插图与漫画页共用。Android/iOS 保存到相册，Windows 保存到 Pictures/Triomi。
Future<void> showImageViewer(
  BuildContext context, {
  required String imageUrl,
  required String sourceId,
  Map<String, String> imageHeaders = const {},
  String? heroTag,
}) {
  return Navigator.of(context, rootNavigator: true).push(
    PageRouteBuilder<void>(
      opaque: false,
      barrierColor: Colors.black,
      pageBuilder: (context, animation, secondaryAnimation) => _ImageViewerPage(
        imageUrl: imageUrl,
        sourceId: sourceId,
        imageHeaders: imageHeaders,
      ),
      transitionsBuilder: (context, animation, secondaryAnimation, child) =>
          FadeTransition(opacity: animation, child: child),
    ),
  );
}

class _ImageViewerPage extends ConsumerStatefulWidget {
  const _ImageViewerPage({
    required this.imageUrl,
    required this.sourceId,
    required this.imageHeaders,
  });

  final String imageUrl;
  final String sourceId;
  final Map<String, String> imageHeaders;

  @override
  ConsumerState<_ImageViewerPage> createState() => _ImageViewerPageState();
}

class _ImageViewerPageState extends ConsumerState<_ImageViewerPage> {
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
                  child: RetryableImage(
                    image: widget.imageUrl.startsWith('file:')
                        ? FileImage(File.fromUri(Uri.parse(widget.imageUrl)))
                        : !widget.imageUrl.contains('://')
                        ? FileImage(File(widget.imageUrl))
                        : SourceNetworkImage(
                            widget.imageUrl,
                            http: ref.watch(sourceHttpClientProvider),
                            sourceId: widget.sourceId,
                            headers: widget.imageHeaders,
                          ),
                    fit: BoxFit.contain,
                    errorColor: Colors.white70,
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
    imageHeaders: widget.imageHeaders,
  );
}

/// Retries only the selected image, without changing its parent's layout or
/// resetting the reader position. The HTTP client and headers remain part of
/// the provider's cache identity; no global cache clear or automatic loop.
class RetryableImage extends StatefulWidget {
  const RetryableImage({
    super.key,
    required this.image,
    this.fit = BoxFit.contain,
    this.errorLabel = '图片加载失败',
    this.errorColor,
    this.errorBackgroundColor,
  });

  final ImageProvider image;
  final BoxFit fit;
  final String errorLabel;
  final Color? errorColor;
  final Color? errorBackgroundColor;

  @override
  State<RetryableImage> createState() => _RetryableImageState();
}

class _RetryableImageState extends State<RetryableImage> {
  int _attempt = 0;
  int _generation = 0;
  bool _retrying = false;

  @override
  void didUpdateWidget(RetryableImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.image != widget.image) {
      _generation++;
      _attempt = 0;
      _retrying = false;
    }
  }

  Future<void> _retry() async {
    if (_retrying) return;
    final generation = _generation;
    final image = widget.image;
    setState(() => _retrying = true);
    await image.evict();
    if (!mounted || generation != _generation) return;
    setState(() {
      _attempt++;
      _retrying = false;
    });
  }

  @override
  Widget build(BuildContext context) => Image(
    // Eviction alone does not re-resolve an unchanged ImageProvider in Image.
    key: ValueKey((widget.image, _attempt)),
    image: widget.image,
    width: double.infinity,
    height: double.infinity,
    fit: widget.fit,
    gaplessPlayback: false,
    frameBuilder: (context, child, frame, synchronous) =>
        synchronous || frame != null
        ? child
        : const Center(
            child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
    errorBuilder: (context, error, stack) {
      final detail = SourceException.sanitizeMessage(
        error is SourceException ? error.userMessage : '$error',
      );
      return ColoredBox(
        color: widget.errorBackgroundColor ?? Colors.transparent,
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(AppSpacing.sm),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  widget.errorLabel,
                  style: TextStyle(color: widget.errorColor),
                ),
                Tooltip(
                  message: detail,
                  child: Text(
                    detail,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: widget.errorColor, fontSize: 12),
                  ),
                ),
                TextButton.icon(
                  onPressed: _retrying ? null : _retry,
                  style: TextButton.styleFrom(
                    foregroundColor: widget.errorColor,
                  ),
                  icon: const Icon(Icons.refresh),
                  label: const Text('重新加载'),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

/// 保存图片：加载字节（本地读文件 / 网络走统一网络层）→
/// 平台存储 → SnackBar 显示实际保存位置。
Future<void> saveImageWithFeedback(
  BuildContext context, {
  required String imageUrl,
  required String sourceId,
  Map<String, String> imageHeaders = const {},
}) async {
  final Uint8List? bytes;
  try {
    bytes = await loadImageBytes(
      imageUrl,
      sourceId: sourceId,
      headers: imageHeaders,
      http: ProviderScope.containerOf(
        context,
        listen: false,
      ).read(sourceHttpClientProvider),
    );
  } catch (error) {
    if (!context.mounted) return;
    final detail = SourceException.sanitizeMessage(
      error is SourceException ? error.userMessage : '$error',
    );
    _showToast(context, '图片数据获取失败：$detail');
    return;
  }
  if (!context.mounted) return;
  if (bytes == null) {
    _showToast(context, '图片数据获取失败');
    return;
  }
  final fileName = 'triomi-${DateTime.now().millisecondsSinceEpoch}.png';
  final uri = await platformChannel.saveImageToGallery(bytes, fileName);
  if (!context.mounted) return;
  _showToast(
    context,
    uri == null
        ? '保存失败'
        : Platform.isWindows
        ? '已保存到本机：$uri'
        : Platform.isIOS
        ? '已保存到相册'
        : '已保存到相册（Pictures/Triomi）',
  );
}

/// 加载图片字节：本地路径直接读文件；网络图走 [SourceHttpClient.fetchBytes]
/// （统一 UA / 超时 / 错误分类）。
/// 网络错误保留原异常，由保存入口显示；无效或不存在的本地路径返回 null。
Future<Uint8List?> loadImageBytes(
  String url, {
  required String sourceId,
  SourceHttpClient? http,
  Map<String, String> headers = const {},
}) async {
  final scheme = Uri.tryParse(url)?.scheme.toLowerCase();
  if (scheme == 'http' || scheme == 'https') {
    if (http == null) return null;
    final data = await http.fetchBytes(
      url,
      sourceId: sourceId,
      headers: headers,
    );
    return data is Uint8List ? data : Uint8List.fromList(data);
  }
  try {
    final windowsPath = RegExp(r'^[A-Za-z]:[\\/]').hasMatch(url);
    final hasScheme = RegExp(r'^[A-Za-z][A-Za-z0-9+.-]*:').hasMatch(url);
    final uri = hasScheme && !windowsPath ? Uri.parse(url) : null;
    if (uri != null &&
        (uri.scheme != 'file' ||
            uri.host.isNotEmpty ||
            uri.hasQuery ||
            uri.hasFragment ||
            !uri.path.startsWith('/'))) {
      return null;
    }
    final file = uri == null ? File(url) : File.fromUri(uri);
    return await file.exists() ? await file.readAsBytes() : null;
  } catch (_) {
    return null;
  }
}

void _showToast(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}
