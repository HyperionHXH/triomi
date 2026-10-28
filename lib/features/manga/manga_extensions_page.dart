import 'package:flutter/material.dart';

import '../sources/mihon_extensions_sheet.dart';

/// A distinct management destination reuses the production installer, signature
/// confirmation, pending-restore handling and platform restrictions unchanged.
class MangaExtensionsPage extends StatelessWidget {
  const MangaExtensionsPage({super.key, this.initialQuery});

  final String? initialQuery;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: Navigator.of(context).canPop()
        ? AppBar(title: const Text('插件库'))
        : null,
    body: MihonExtensionsSheet(initialQuery: initialQuery),
  );
}
