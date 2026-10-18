import 'package:ux/src/url/unicode.dart' as u;

/// The code point that starts at [i] of [text].
int cpAt(String text, int i) {
  final high = text.codeUnitAt(i);
  if (high >= 0xD800 && high <= 0xDBFF && i + 1 < text.length) {
    final low = text.codeUnitAt(i + 1);
    if (low >= 0xDC00 && low <= 0xDFFF) {
      return 0x10000 + ((high - 0xD800) << 10) + (low - 0xDC00);
    }
  }
  return high;
}

/// The code point that ends before [i] of [text].
int cpBefore(String text, int i) {
  final low = text.codeUnitAt(i - 1);
  if (i >= 2 && low >= 0xDC00 && low <= 0xDFFF) {
    final high = text.codeUnitAt(i - 2);
    if (high >= 0xD800 && high <= 0xDBFF) {
      return 0x10000 + ((high - 0xD800) << 10) + (low - 0xDC00);
    }
  }
  return low;
}

/// [cp]'s UTF-16 length.
int width(int cp) => cp > 0xFFFF ? 2 : 1;

/// Whether [cp] is in general category L.
bool isLetter(int cp) => u.classesOf(cp) & u.letter != 0;

/// Whether [cp] is in general category M.
bool isMark(int cp) => u.classesOf(cp) & u.mark != 0;

/// Whether [cp] is in general category Nd.
bool isDigit(int cp) => u.classesOf(cp) & u.digit != 0;

/// Whether [cp] is in general category Cf.
bool isFormat(int cp) => u.classesOf(cp) & u.format != 0;

/// Whether NSCharacterSet.letterCharacterSet holds [cp]: general categories
/// L and M.
bool isMacLetter(int cp) => u.classesOf(cp) & (u.letter | u.mark) != 0;

/// Whether [cp] is a letter, mark, digit or symbol (So or Sk).
bool isJoinable(int cp) =>
    u.classesOf(cp) & (u.letter | u.mark | u.digit | u.symbol) != 0;

/// Whether [cp] is a letter, mark or digit.
bool isLetterMarkDigit(int cp) =>
    u.classesOf(cp) & (u.letter | u.mark | u.digit) != 0;

/// Whether [cp] is in ICU's `\w`: Alphabetic, M, Nd, Pc, U+200C and U+200D.
bool isWord(int cp) =>
    cp == 0x200C ||
    cp == 0x200D ||
    u.classesOf(cp) & (u.alphabetic | u.mark | u.digit | u.connector) != 0;

/// Whether ICU's `\b` skips [cp] when it looks for the character before a
/// position: Grapheme_Extend and Cf.
bool isBoundaryTransparent(int cp) =>
    u.classesOf(cp) & (u.extend | u.format) != 0;

/// Whether [cp] is in ICU's `\s`: tab, LF, FF, CR and general category Z.
bool isIcuSpace(int cp) =>
    cp == 0x09 ||
    cp == 0x0A ||
    cp == 0x0C ||
    cp == 0x0D ||
    u.classesOf(cp) & u.separator != 0;

/// Whether the UTF-16 unit [c] is in Dart's RegExp `\s`.
bool isDartSpace(int c) =>
    (c >= 0x09 && c <= 0x0D) ||
    c == 0x20 ||
    c == 0xA0 ||
    c == 0x1680 ||
    (c >= 0x2000 && c <= 0x200A) ||
    c == 0x2028 ||
    c == 0x2029 ||
    c == 0x202F ||
    c == 0x205F ||
    c == 0x3000 ||
    c == 0xFEFF;

/// Whether [cp] belongs to a script written without spaces: Han, kana,
/// Bopomofo, Hangul, Thai, Lao, Khmer and Myanmar, with CJK symbols and
/// punctuation, by block.
bool isUnspaced(int cp) =>
    (cp >= 0x0E00 && cp <= 0x0EFF) ||
    (cp >= 0x1000 && cp <= 0x109F) ||
    (cp >= 0x1100 && cp <= 0x11FF) ||
    (cp >= 0x1780 && cp <= 0x17FF) ||
    (cp >= 0x2E80 && cp <= 0x9FFF) ||
    (cp >= 0xA960 && cp <= 0xA97F) ||
    (cp >= 0xAC00 && cp <= 0xD7FF) ||
    (cp >= 0xF900 && cp <= 0xFAFF) ||
    (cp >= 0xFF66 && cp <= 0xFFDC) ||
    (cp >= 0x20000 && cp <= 0x3FFFF);

/// Whether the UTF-16 unit [c] is in an unspaced script's block, a high
/// surrogate of the supplementary ideographs included.
bool isUnspacedUnit(int c) =>
    (c >= 0x0E00 && c <= 0x0EFF) ||
    (c >= 0x1000 && c <= 0x109F) ||
    (c >= 0x1100 && c <= 0x11FF) ||
    (c >= 0x1780 && c <= 0x17FF) ||
    (c >= 0x2E80 && c <= 0x9FFF) ||
    (c >= 0xA960 && c <= 0xA97F) ||
    (c >= 0xAC00 && c <= 0xD7FF) ||
    (c >= 0xD840 && c <= 0xD8BF) ||
    (c >= 0xF900 && c <= 0xFAFF) ||
    (c >= 0xFF66 && c <= 0xFFDC);

/// Whether [cp] is a letter, mark or digit outside the unspaced scripts.
bool isSpacedLetterMarkDigit(int cp) =>
    isLetterMarkDigit(cp) && !isUnspaced(cp);

/// Whether the UTF-16 unit [c] is CJK punctuation: U+3000's block's
/// punctuation and the vertical, compatibility, small, fullwidth and
/// halfwidth forms of punctuation.
bool isCjkPunctuation(int c) =>
    (c >= 0x3001 && c <= 0x3003) ||
    (c >= 0x3008 && c <= 0x3011) ||
    (c >= 0x3014 && c <= 0x301F) ||
    (c >= 0xFE10 && c <= 0xFE19) ||
    (c >= 0xFE30 && c <= 0xFE6B) ||
    (c >= 0xFF01 && c <= 0xFF0F) ||
    (c >= 0xFF1A && c <= 0xFF20) ||
    (c >= 0xFF3B && c <= 0xFF40) ||
    (c >= 0xFF5B && c <= 0xFF65);

/// Whether [cp] is in Patterns.WEB_URL's UCS_CHAR.
bool isUcsChar(int cp) {
  if (cp > 0xFFFF) {
    return (cp & 0xFFFF) <= 0xFFFD &&
        cp < 0xF0000 &&
        !(cp >= 0xE0000 && cp < 0xE1000);
  }
  return ((cp > 0xA0 && cp <= 0xD7FF) ||
          (cp >= 0xF900 && cp <= 0xFDCF) ||
          (cp >= 0xFDF0 && cp <= 0xFFEF)) &&
      !((cp >= 0x2000 && cp <= 0x200A) ||
          cp == 0x2028 ||
          cp == 0x2029 ||
          cp == 0x202F ||
          cp == 0x3000);
}

/// Whether the UTF-16 unit [c] is an ASCII digit.
bool isAsciiDigit(int c) => c >= 0x30 && c <= 0x39;

/// Whether the UTF-16 unit [c] is an ASCII letter.
bool isAsciiLetter(int c) => (c | 0x20) >= 0x61 && (c | 0x20) <= 0x7A;

/// Whether the UTF-16 unit [c] is a hex digit.
bool isHex(int c) =>
    isAsciiDigit(c) || ((c | 0x20) >= 0x61 && (c | 0x20) <= 0x66);

/// Whether [cp] is one of Unicode's Bidi_Control characters.
bool isBidiControl(int cp) =>
    cp == 0x061C ||
    cp == 0x200E ||
    cp == 0x200F ||
    (cp >= 0x202A && cp <= 0x202E) ||
    (cp >= 0x2066 && cp <= 0x2069);
