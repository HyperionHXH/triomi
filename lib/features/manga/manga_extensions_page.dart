import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/models/media_type.dart';
import '../sources/ios_plugin_library_page.dart';
import '../sources/mihon_extensions_sheet.dart';
import '../sources/sources_page.dart';

/// A distinct management destination reuses the production installer, signature
/// confirmation, pending-restore handling and platform restrictions unchanged.
/// iOS cannot execute APKs, so it gets the same plugin library screens backed
/// by Triomi JS / API rules and compatible catalog repositories.
class MangaExtensionsPage extends StatelessWidget {
  const MangaExtensionsPage({super.key, this.initialQuery});

  final String? initialQuery;

  @override
  Widget build(BuildContext context) {
    Future<void> rules() => Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => const SourcesPage(initialType: MediaType.manga),
      ),
    );
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
      return IosPluginLibraryPage(initialQuery: initialQuery, onRules: rules);
    }
    return MihonExtensionsSheet(initialQuery: initialQuery, onRules: rules);
  }
}
