import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/source/source_providers.dart';
import '../../core/storage/preferences.dart';
import '../../core/widgets/source_network_image.dart';

final _extensionArtworkProvider = StreamProvider.autoDispose<Object?>(
  (ref) => ref.watch(preferencesProvider).watch('mihon.hostStatus'),
);

/// Repository artwork is display metadata, independent of executable trust.
String? mihonExtensionIconUrl(Object? value) {
  final text = value?.toString().trim() ?? '';
  final uri = Uri.tryParse(text);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment) {
    return null;
  }
  return uri.toString();
}

class MihonExtensionIcon extends ConsumerWidget {
  const MihonExtensionIcon({
    super.key,
    required this.packageName,
    this.iconUrl,
    this.size = 40,
    this.enabled = true,
  });

  final String packageName;
  final String? iconUrl;
  final double size;
  final bool enabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final metadata =
        ref.watch(_extensionArtworkProvider).value ??
        ref.watch(preferencesProvider).get<Object?>('mihon.hostStatus');
    final status = metadata is Map ? metadata[packageName] : null;
    final url =
        mihonExtensionIconUrl(iconUrl) ??
        mihonExtensionIconUrl(status is Map ? status['iconUrl'] : null);
    Widget fallback() => Icon(
      enabled ? Icons.extension_outlined : Icons.pause_circle_outline,
      size: size * .65,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    return SizedBox.square(
      dimension: size,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: url == null
            ? Center(child: fallback())
            : Image(
                image: SourceNetworkImage(
                  url,
                  http: ref.watch(sourceHttpClientProvider),
                  sourceId: 'mihon-icon:$packageName',
                ),
                fit: BoxFit.contain,
                width: size,
                height: size,
                excludeFromSemantics: true,
                errorBuilder: (_, _, _) => Center(child: fallback()),
                frameBuilder: (_, child, frame, synchronous) =>
                    frame != null || synchronous
                    ? child
                    : Center(child: fallback()),
              ),
      ),
    );
  }
}
