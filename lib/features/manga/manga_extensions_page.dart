import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/models/media_type.dart';
import '../sources/mihon_extensions_sheet.dart';
import '../sources/sources_page.dart';

/// A distinct management destination reuses the production installer, signature
/// confirmation, pending-restore handling and platform restrictions unchanged.
class MangaExtensionsPage extends StatelessWidget {
  const MangaExtensionsPage({super.key, this.initialQuery});

  final String? initialQuery;

  @override
  Widget build(BuildContext context) {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
      return SourcesPage(
        initialType: MediaType.manga,
        initialQuery: initialQuery,
      );
    }
    return Scaffold(
      appBar: Navigator.of(context).canPop()
          ? AppBar(title: const Text('插件库'))
          : null,
      body: MihonExtensionsSheet(initialQuery: initialQuery),
    );
  }
}
