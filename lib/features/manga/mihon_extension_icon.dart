import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/source/mihon_icon_storage.dart';
import '../../core/source/source_providers.dart';
import '../../core/storage/preferences.dart';
import '../../core/widgets/source_network_image.dart';

final _extensionArtworkProvider = StreamProvider.autoDispose<Object?>(
  (ref) => ref.watch(preferencesProvider).watch('mihon.hostStatus'),
);
final _installedPackagesProvider = StreamProvider.autoDispose<Object?>(
  (ref) => ref.watch(preferencesProvider).watch('mihon.installedPackages'),
);
final _installedIconProvider = FutureProvider.autoDispose
    .family<File?, ({String package, String? url})>((ref, artwork) {
      // Re-read after an install/update even when the repository URL is stable.
      ref.watch(_extensionArtworkProvider);
      return MihonIconStorage(http: ref.watch(sourceHttpClientProvider))
          .obtain(artwork.package, artwork.url);
    });

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
    final preferences = ref.watch(preferencesProvider);
    final metadata =
        ref.watch(_extensionArtworkProvider).value ??
        preferences.get<Object?>('mihon.hostStatus');
    final installed =
        ref.watch(_installedPackagesProvider).value ??
        preferences.get<Object?>('mihon.installedPackages');
    final status = metadata is Map ? metadata[packageName] : null;
    final url =
        MihonIconStorage.iconUrl(iconUrl) ??
        MihonIconStorage.iconUrl(status is Map ? status['iconUrl'] : null);
    final isInstalled = installed is Map && installed.containsKey(packageName);
    final local = isInstalled
        ? ref
              .watch(_installedIconProvider((package: packageName, url: url)))
              .value
        : null;
    final ImageProvider? image = isInstalled
        ? (local == null ? null : FileImage(local))
        : (url == null
              ? null
              : SourceNetworkImage(
                  url,
                  http: ref.watch(sourceHttpClientProvider),
                  sourceId: 'mihon-icon:$packageName',
                ));
    Widget fallback() => Icon(
      enabled ? Icons.extension_outlined : Icons.pause_circle_outline,
      size: size * .65,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    return SizedBox.square(
      dimension: size,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: image == null
            ? Center(child: fallback())
            : Image(
                key: local == null ? null : ObjectKey(local),
                image: image,
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
