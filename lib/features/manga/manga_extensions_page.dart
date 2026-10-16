import 'package:flutter/material.dart';

import '../sources/mihon_extensions_sheet.dart';

/// A distinct management destination reuses the production installer, signature
/// confirmation, pending-restore handling and platform restrictions unchanged.
class MangaExtensionsPage extends StatelessWidget {
  const MangaExtensionsPage({super.key});

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: MihonExtensionsSheet());
}
