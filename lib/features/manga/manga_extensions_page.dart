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
  Widget build(BuildContext context) => MihonExtensionsSheet(
    initialQuery: initialQuery,
    onRules: () async {
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => const SourcesPage(initialType: MediaType.manga),
        ),
      );
    },
  );
}
