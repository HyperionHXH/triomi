/// Recognizes local reading-order numbers without changing source identity or
/// source-owned request metadata. Based on Komikku's ChapterRecognition: strip
/// the work title and volume/version tags, prefer `Ch.`, then use the first
/// remaining number, including decimal and numbered extra/omake suffixes.
///
/// Unlike a positional fallback, an unnumbered special stays unknown. Explicit
/// native numbers (including the -2 special sentinel) are authoritative.
double? recognizeMangaChapterNumber({
  required String mangaTitle,
  required String chapterTitle,
  double? providedNumber,
}) {
  if (providedNumber != null &&
      providedNumber.isFinite &&
      providedNumber != -1) {
    return providedNumber;
  }
  var name = chapterTitle.toLowerCase();
  if (mangaTitle.isNotEmpty) {
    name = _removeWorkTitle(name, mangaTitle.toLowerCase());
  }
  name = name.trim().replaceAll(',', '.').replaceAll('-', '.');
  name = name
      .replaceAllMapped(_whitespace, (match) {
        // Match whitespace independently of the suffix. A failing suffix
        // lookahead at each position of a long run would retry quadratically.
        return name.startsWith('extra', match.end) ||
                name.startsWith('special', match.end) ||
                name.startsWith('omake', match.end)
            ? ''
            : match[0]!;
      })
      .replaceAll(_volumeTags, '');
  final explicit = _chapterPrefix.firstMatch(name);
  // "Extra 1" is a special's own numbering, not chapter 1. A numbered
  // chapter suffix such as "12 extra" is recognized below, as in Komikku.
  if (explicit == null && _standaloneSpecial.hasMatch(name)) {
    return providedNumber;
  }
  final match = explicit ?? _chapterNumber.firstMatch(name);
  if (match == null) return providedNumber;
  final initial = double.tryParse(match[1]!);
  if (initial == null || !initial.isFinite) return providedNumber;
  final decimal = match[2];
  if (decimal != null) {
    final result = initial + double.parse(decimal);
    return result.isFinite ? result : providedNumber;
  }
  final suffix = match[3];
  if (suffix == null) return initial;
  if (suffix.contains('extra')) return initial + 0.99;
  if (suffix.contains('omake')) return initial + 0.98;
  if (suffix.contains('special')) return initial + 0.97;
  final alpha = suffix.startsWith('.') ? suffix.substring(1) : suffix;
  if (alpha.length == 1) {
    final ordinal = alpha.codeUnitAt(0) - 'a'.codeUnitAt(0) + 1;
    if (ordinal > 0 && ordinal < 10) return initial + ordinal / 10;
  }
  return initial;
}

String _removeWorkTitle(String name, String title) {
  StringBuffer? result;
  var copiedUntil = 0;
  var index = name.indexOf(title);
  while (index >= 0) {
    final end = index + title.length;
    final startsToken =
        index > 0 &&
        (_titleTokenCharacter.hasMatch(name.substring(index - 1, index)) ||
            index > 1 &&
                _decimalSeparator(name.codeUnitAt(index - 1)) &&
                _digit(name.codeUnitAt(index - 2)) &&
                _digit(title.codeUnitAt(0)));
    final endsToken =
        end < name.length &&
        (_titleTokenCharacter.hasMatch(name.substring(end, end + 1)) ||
            end + 1 < name.length &&
                _decimalSeparator(name.codeUnitAt(end)) &&
                _digit(name.codeUnitAt(end + 1)) &&
                _digit(title.codeUnitAt(title.length - 1)));
    if (!startsToken && !endsToken) {
      result ??= StringBuffer();
      result.write(name.substring(copiedUntil, index));
      copiedUntil = end;
    }
    index = name.indexOf(title, end);
  }
  if (result == null) return name;
  result.write(name.substring(copiedUntil));
  return result.toString();
}

bool _digit(int value) => value >= 48 && value <= 57;
bool _decimalSeparator(int value) => value == 46 || value == 44;

const _numberPattern = r'([0-9]+)(\.[0-9]+)?(\.?[a-z]+)?';
final _chapterNumber = RegExp(_numberPattern);
// Keep Komikku's explicit Ch. priority. Other chapter/localized prefixes need
// no special handling: after tag removal their number is the first candidate.
final _chapterPrefix = RegExp(r'\bch\.\s*' + _numberPattern);
final _volumeTags = RegExp(
  r'\b(?:v|ver|vol|version|volume|season|s)[ .]*[0-9]+(?:\.[0-9]+)?',
);
final _whitespace = RegExp(r'\s+');
final _titleTokenCharacter = RegExp(r'[\p{L}\p{N}_]', unicode: true);
final _standaloneSpecial = RegExp(
  r'''^[\s.:\[\](){}【】「」『』（）"'“”‘’]*(?:(?:extra|special|omake)\b|番外|特別|特别|外传|外傳)''',
);
