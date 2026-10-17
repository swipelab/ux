// Native data detection for XUrl. Synchronous, callable via dart:ffi.
//
// Exports two symbols:
//   uint8_t* ux_match_url(const uint16_t* utf16, int32_t len, int32_t* out_size);
//   void     ux_free(uint8_t* buf);
//
// Output buffer layout (little-endian on Apple ARM64 / x86_64):
//   u32 count
//   count * { i32 start, i32 end, u32 kind, u32 url_len, u8[url_len] url_utf8 }
// where kind ∈ { 0=web, 1=email, 2=phone }.
//
// Backed by NSDataDetector (.link | .phoneNumber) and a second pass for the
// web links it misses, such as a host on a TLD it does not know, IPv4
// addresses and a URL with a scheme whose port runs into text. A web match
// with no scheme links only where its host is an IPv4 address or ends in a
// TLD IsTld holds for.

#import <Foundation/Foundation.h>
#import <stdint.h>
#import <stdlib.h>
#import <string.h>

#include <string>

#include "../../../../src/tld.h"

static const uint32_t kKindWeb   = 0;
static const uint32_t kKindEmail = 1;
static const uint32_t kKindPhone = 2;

@interface XUrlRawMatch : NSObject
@property (nonatomic) int32_t start;
@property (nonatomic) int32_t end;
@property (nonatomic) uint32_t kind;
@property (nonatomic, copy) NSData *urlUtf8;
@end
@implementation XUrlRawMatch
@end

static NSDataDetector *ux_url_data_detector(void) {
    static NSDataDetector *detector;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSError *err = nil;
        NSTextCheckingTypes types =
            NSTextCheckingTypeLink | NSTextCheckingTypePhoneNumber;
        detector = [NSDataDetector dataDetectorWithTypes:types error:&err];
    });
    return detector;
}

static NSRegularExpression *ux_url_web_regex(void) {
    static NSRegularExpression *regex;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // ux_is_unspaced's letters.
        NSString *unspaced = @"[\\u0E00-\\u0EFF\\u1000-\\u109F\\u1100-\\u11FF\\u1780-\\u17FF\\u2E80-\\u9FFF"
                             @"\\uA960-\\uA97F\\uAC00-\\uD7FF\\uF900-\\uFAFF\\uFF66-\\uFFDC\\U00020000-\\U0003FFFF]";
        // ux_is_cjk_punctuation's punctuation.
        NSString *cjk = @"\\u3001-\\u3003\\u3008-\\u3011\\u3014-\\u301F\\uFE10-\\uFE19\\uFE30-\\uFE6B"
                        @"\\uFF01-\\uFF0F\\uFF1A-\\uFF20\\uFF3B-\\uFF40\\uFF5B-\\uFF65";
        // ux_is_ucs_char's characters outside the CJK punctuation.
        NSString *ucs = [NSString stringWithFormat:
            @"[[\\u00A1-\\uD7FF\\uF900-\\uFFEF\\U00010000-\\U000EFFFD]--[\\p{Noncharacter_Code_Point}"
            @"\\u2000-\\u200A\\u2028\\u2029\\u202F\\u3000\\U000E0000-\\U000E0FFF%@]]",
            cjk];
        NSString *ipv4 = @"(?:25[0-5]|2[0-4][0-9]|[0-1][0-9]{2}|[1-9][0-9]|[1-9])"
                         @"\\.(?:25[0-5]|2[0-4][0-9]|[0-1][0-9]{2}|[1-9][0-9]|[1-9]|0)"
                         @"\\.(?:25[0-5]|2[0-4][0-9]|[0-1][0-9]{2}|[1-9][0-9]|[1-9]|0)"
                         @"\\.(?:25[0-5]|2[0-4][0-9]|[0-1][0-9]{2}|[1-9][0-9]|[0-9])";
        // The path ends before whitespace, the CJK punctuation and the ASCII
        // marks ux_web_end ends a path before, so a bare domain glued after
        // one links on its own.
        NSString *path = [NSString stringWithFormat:@"[/?](?:[^\\s\"%%<>\\[\\\\\\]^`{|}%@]|%%[0-9a-f]{2})*", cjk];
        // Patterns.WEB_URL's protocol, user info, host name or IPv4 address
        // and port, then a path or a word boundary, or a port of ASCII digits
        // that an unspaced letter follows. With no protocol, its host name with
        // ASCII labels or its IPv4 address and its port, then a path, or a
        // word boundary or an unspaced letter where no '@' and an email's
        // domain follow; a port that an unspaced letter follows has ASCII
        // digits. A host name has no CJK punctuation. A match starts at a word
        // boundary, after a '_' or after an unspaced letter, but neither after
        // a scheme's "://" nor inside a label or a host the pass does not
        // match from its start: after a letter, mark or digit outside the
        // unspaced scripts and a run of '_' and '-' or a '.'.
        // NSRegularExpression can miss a second '\b' in a row at the end of
        // the text, so the end of the text ends a port of its own.
        NSString *pattern = [NSString stringWithFormat:
            @"(?:\\b|(?<=[_%1$@]))(?<![[\\p{L}\\p{M}\\p{Nd}]--%1$@](?:[_-]{1,62}|\\.))(?<!://)"
            @"(?:((?:https?|rtsp|ftp)://(?:(?:[a-z0-9$_.+!*'(),;?&=-]|%%[0-9a-f]{2}){1,64}"
            @"(?::(?:[a-z0-9$_.+!*'(),;?&=-]|%%[0-9a-f]{2}){1,25})?@)?)"
            @"(?:(?:[a-z0-9%3$@](?:[a-z0-9_\\-%3$@]{0,61}[a-z0-9%3$@])?\\.)+(?:(?-i:xn)--[\\w-]{0,58}\\w|[a-z%3$@]{2,63})"
            @"|%4$@)(?::[0-9]{1,5}(?=%1$@)|(?::\\d{1,5})?(?:%2$@|\\b))"
            @"|(?:(?:[a-z0-9](?:[a-z0-9_-]{0,61}[a-z0-9])?\\.)+(?:xn--[a-z0-9-]{0,58}[a-z0-9]|[a-z]{2,63})|%4$@)"
            @"(?::[0-9]{1,5}|:\\d{1,5}\\b)?(?:%2$@|(?:\\b|$|(?=%1$@))(?!@[a-z0-9][a-z0-9-]{0,64}\\.[a-z0-9])))",
            unspaced, path, ucs, ipv4];
        NSError *err = nil;
        regex = [NSRegularExpression
            regularExpressionWithPattern:pattern
                                 options:NSRegularExpressionCaseInsensitive
                                   error:&err];
    });
    return regex;
}

// The start of the path, query or fragment of the web match [start, end): its
// first '/', '?' or '#' past the "//" that follows a scheme.
static NSUInteger ux_path_start(const uint16_t *chars, NSUInteger start, NSUInteger end) {
    NSUInteger i = start;
    while (i < end && chars[i] != ':' && chars[i] != '/' && chars[i] != '?' && chars[i] != '#') i++;
    if (i + 2 < end && chars[i] == ':' && chars[i + 1] == '/' && chars[i + 2] == '/') i += 3;
    while (i < end && chars[i] != '/' && chars[i] != '?' && chars[i] != '#') i++;
    return i;
}

static BOOL ux_is_hex(uint16_t c) {
    return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
}

// Whether the code point c is in Patterns.WEB_URL's UCS_CHAR.
static BOOL ux_is_ucs_char(uint32_t c) {
    if (c > 0xFFFF) return (c & 0xFFFF) <= 0xFFFD && c < 0xF0000 && !(c >= 0xE0000 && c < 0xE1000);
    return ((c > 0xA0 && c <= 0xD7FF) || (c >= 0xF900 && c <= 0xFDCF) || (c >= 0xFDF0 && c <= 0xFFEF)) &&
           !((c >= 0x2000 && c <= 0x200A) || c == 0x2028 || c == 0x2029 || c == 0x202F || c == 0x3000);
}

// The first character in [i, end) that Patterns.WEB_URL's path does not take:
// an ASCII control or space, '"', '<', '>', '[', '\', ']', '^', '`', '{', '|',
// '}', a '%' that two hex digits do not follow or a character outside
// UCS_CHAR; `end` where there is none.
static NSUInteger ux_path_mark(const uint16_t *chars, NSUInteger i, NSUInteger end) {
    while (i < end) {
        const uint16_t c = chars[i];
        NSUInteger next = i + 1;
        BOOL mark;
        if (c == '%') {
            mark = !(i + 2 < end && ux_is_hex(chars[i + 1]) && ux_is_hex(chars[i + 2]));
        } else if (c < 0x80) {
            mark = c <= 0x20 || c == 0x7F || c == '"' || c == '<' || c == '>' || c == '[' || c == '\\' ||
                   c == ']' || c == '^' || c == '`' || c == '{' || c == '|' || c == '}';
        } else if (CFStringIsSurrogateHighCharacter(c) && next < end && CFStringIsSurrogateLowCharacter(chars[next])) {
            mark = !ux_is_ucs_char(CFStringGetLongCharacterForSurrogatePair(c, chars[next++]));
        } else {
            mark = !ux_is_ucs_char(c);
        }
        if (mark) break;
        i = next;
    }
    return i;
}

// U+3000's block's punctuation and the vertical, compatibility, small,
// fullwidth and halfwidth forms of punctuation.
static BOOL ux_is_cjk_punctuation(uint16_t c) {
    return (c >= 0x3001 && c <= 0x3003) || (c >= 0x3008 && c <= 0x3011) ||
           (c >= 0x3014 && c <= 0x301F) || (c >= 0xFE10 && c <= 0xFE19) ||
           (c >= 0xFE30 && c <= 0xFE6B) || (c >= 0xFF01 && c <= 0xFF0F) ||
           (c >= 0xFF1A && c <= 0xFF20) || (c >= 0xFF3B && c <= 0xFF40) ||
           (c >= 0xFF5B && c <= 0xFF65);
}

static BOOL ux_is_path_delimiter(uint16_t c) {
    return c == '/' || c == '?' || c == '#' || c == '&' || c == '=';
}

// Whether c belongs to a script whose text runs onto a domain with no space
// between: Han, kana, Bopomofo, Hangul, Thai, Lao, Khmer and Myanmar by block,
// and an ideograph of the supplementary planes by its high surrogate.
static BOOL ux_is_unspaced(uint16_t c) {
    return (c >= 0x0E00 && c <= 0x0EFF) || (c >= 0x1000 && c <= 0x109F) ||
           (c >= 0x1100 && c <= 0x11FF) || (c >= 0x1780 && c <= 0x17FF) ||
           (c >= 0x2E80 && c <= 0x9FFF) || (c >= 0xA960 && c <= 0xA97F) ||
           (c >= 0xAC00 && c <= 0xD7FF) || (c >= 0xD840 && c <= 0xD8BF) ||
           (c >= 0xF900 && c <= 0xFAFF) || (c >= 0xFF66 && c <= 0xFFDC);
}

// Whether the character at i of the text of length len is a letter.
static BOOL ux_is_letter(const uint16_t *chars, NSUInteger len, NSUInteger i) {
    UTF32Char c = chars[i];
    if (CFStringIsSurrogateHighCharacter(chars[i]) && i + 1 < len && CFStringIsSurrogateLowCharacter(chars[i + 1])) {
        c = CFStringGetLongCharacterForSurrogatePair(chars[i], chars[i + 1]);
    }
    return [NSCharacterSet.letterCharacterSet longCharacterIsMember:c];
}

// Whether the character at i of the text of length len is a letter outside
// the unspaced scripts.
static BOOL ux_is_spaced_letter(const uint16_t *chars, NSUInteger len, NSUInteger i) {
    return !ux_is_unspaced(chars[i]) && ux_is_letter(chars, len, i);
}

// Whether the web match [start, end) is a host alone that a '.' glues a word
// to: a letter outside the unspaced scripts follows the '.'.
static BOOL ux_glues_word(const uint16_t *chars, NSUInteger len, NSUInteger start, NSUInteger end) {
    if (end + 1 >= len || chars[end] != '.') return NO;
    for (NSUInteger i = start; i < end; i++) {
        if (chars[i] == ':' || chars[i] == '/' || chars[i] == '?' || chars[i] == '#') return NO;
    }
    return ux_is_spaced_letter(chars, len, end + 1);
}

// The end of the host of the web match [start, end), which has no scheme: its
// first ':', '/', '?' or '#'.
static NSUInteger ux_host_end(const uint16_t *chars, NSUInteger start, NSUInteger end) {
    NSUInteger i = start;
    while (i < end && chars[i] != ':' && chars[i] != '/' && chars[i] != '?' && chars[i] != '#') i++;
    return i;
}

// The end of the web match [start, end), which has no scheme, before the port
// that ends it where a letter follows, since no word boundary ends
// Patterns.WEB_URL's port there. A port that an unspaced letter follows stays
// where it has ASCII digits.
static NSUInteger ux_port_end(const uint16_t *chars, NSUInteger len, NSUInteger start, NSUInteger end) {
    const NSUInteger host_end = ux_host_end(chars, start, end);
    if (host_end == end || chars[host_end] != ':' || end == len || !ux_is_letter(chars, len, end)) return end;
    BOOL ascii = YES;
    for (NSUInteger i = host_end + 1; i < end; i++) {
        if (![NSCharacterSet.decimalDigitCharacterSet characterIsMember:chars[i]]) return end;
        ascii = ascii && chars[i] >= '0' && chars[i] <= '9';
    }
    return ascii && ux_is_unspaced(chars[end]) ? end : host_end;
}

// Whether the web match [start, end), which has no scheme, has the TLD it
// needs: an IPv4 address needs none, and a host's last label is one where
// IsTld holds.
static BOOL ux_has_tld(const uint16_t *chars, NSUInteger start, NSUInteger end) {
    const NSUInteger host_end = ux_host_end(chars, start, end);
    NSUInteger label = host_end;
    while (label > start && chars[label - 1] != '.') label--;
    return (chars[label] >= '0' && chars[label] <= '9') || IsTld(std::u16string(chars + label, chars + host_end));
}

// The fullwidth '(' that ends the stretch of the text between CJK punctuation
// the web match [start, end) ends in, where the match has a path that runs on
// to it; nil otherwise.
static NSNumber *ux_path_paren(const uint16_t *chars, NSUInteger len, NSUInteger start, NSUInteger end) {
    if (ux_path_start(chars, start, end) == end) return nil;
    NSUInteger paren = end;
    while (paren < len && !ux_is_cjk_punctuation(chars[paren])) paren++;
    if (paren == len || chars[paren] != 0xFF08 || ux_path_mark(chars, end, paren) < paren) return nil;
    return @(paren);
}

// Whether the web match [start, end) continues the path that runs on to the
// fullwidth '(' at `paren`: the match lies past `paren` in a stretch of the
// text right after a fullwidth ')' that holds a path delimiter before the
// match, and the path runs on from `paren` through the match.
static BOOL ux_continues_path(const uint16_t *chars, NSUInteger paren, NSUInteger start, NSUInteger end) {
    if (start <= paren) return NO;
    NSUInteger from = start;
    while (!ux_is_cjk_punctuation(chars[from - 1])) from--;
    if (chars[from - 1] != 0xFF09) return NO;
    while (from < start && !ux_is_path_delimiter(chars[from])) from++;
    return from < start && ux_path_mark(chars, paren, end) == end;
}

// The end of the web match [start, end), which the web regex's suffix and
// NSDataDetector run past. The match ends before the first character its path
// does not take, then before a trailing '.', ',', ';', '!', '\'' or '(' and a
// trailing ')' it does not open.
static NSUInteger ux_web_end(const uint16_t *chars, NSUInteger start, NSUInteger end) {
    end = ux_path_mark(chars, ux_path_start(chars, start, end), end);
    NSInteger unopened = 0;
    for (NSUInteger i = start; i < end; i++) {
        if (chars[i] == ')') unopened++;
        if (chars[i] == '(') unopened--;
    }
    while (end > start) {
        const uint16_t c = chars[end - 1];
        if (c == ')' && unopened > 0) {
            unopened--;
        } else if (c == '(') {
            unopened++;
        } else if (!(c == '.' || c == ',' || c == ';' || c == '!' || c == '\'')) {
            break;
        }
        end--;
    }
    return end;
}

// Whether the range r of the text is a dotted IPv4 address: ASCII digits and
// '.' alone that the web regex matches whole, and that no '0', a national
// trunk prefix, starts.
static BOOL ux_is_ipv4(NSRegularExpression *webRe, NSString *text, const uint16_t *chars, NSRange r) {
    if (chars[r.location] == '0') return NO;
    for (NSUInteger i = r.location; i < NSMaxRange(r); i++) {
        if (chars[i] != '.' && (chars[i] < '0' || chars[i] > '9')) return NO;
    }
    return NSEqualRanges([webRe rangeOfFirstMatchInString:text options:NSMatchingAnchored range:r], r);
}

static NSData *ux_utf8(NSString *s) {
    return [s dataUsingEncoding:NSUTF8StringEncoding allowLossyConversion:YES];
}

extern "C" __attribute__((used, visibility("default")))
uint8_t *ux_match_url(const uint16_t *utf16, int32_t len, int32_t *out_size) {
    if (out_size) *out_size = 0;
    if (utf16 == NULL || len <= 0) return NULL;

    @autoreleasepool {
        NSString *text = [[NSString alloc] initWithCharacters:(const unichar *)utf16
                                                        length:(NSUInteger)len];
        if (text.length == 0) return NULL;

        NSRange whole = NSMakeRange(0, text.length);
        NSMutableArray<XUrlRawMatch *> *raws = [NSMutableArray array];

        NSRegularExpression *webRe = ux_url_web_regex();
        NSDataDetector *detector = ux_url_data_detector();
        if (detector != nil) {
            [detector enumerateMatchesInString:text
                                       options:0
                                         range:whole
                                    usingBlock:^(NSTextCheckingResult *result,
                                                 NSMatchingFlags flags,
                                                 BOOL *stop) {
                if (result == nil) return;
                const NSRange r = result.range;
                if (r.location == NSNotFound || r.length == 0) return;

                NSUInteger end = NSMaxRange(r);
                NSString *url = nil;
                uint32_t kind = kKindWeb;
                if (result.resultType == NSTextCheckingTypePhoneNumber) {
                    if (ux_is_ipv4(webRe, text, utf16, r)) return;
                    NSString *raw = result.phoneNumber ?: @"";
                    // Compat-decompose so full-width / Arabic-Indic digits
                    // collapse to ASCII before we filter — tel: URIs only
                    // accept [0-9+] per RFC 3966. Stop at the first
                    // letter run so "ext.99" extensions don't get fused
                    // into the dialed number.
                    NSString *folded = [raw decomposedStringWithCompatibilityMapping];
                    NSMutableString *digits = [NSMutableString stringWithCapacity:folded.length];
                    BOOL seenLetter = NO;
                    NSUInteger digitCount = 0;
                    for (NSUInteger i = 0; i < folded.length; i++) {
                        unichar c = [folded characterAtIndex:i];
                        if ((c >= '0' && c <= '9') || c == '+') {
                            if (seenLetter) break;
                            [digits appendFormat:@"%C", c];
                            if (c >= '0' && c <= '9') digitCount++;
                        } else if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')) {
                            seenLetter = YES;
                        }
                    }
                    // 7 digits is the conventional minimum dialable
                    // length; below that the match is almost certainly a
                    // short code / version / ZIP / score, not a phone.
                    if (digitCount < 7) return;
                    url = [NSString stringWithFormat:@"tel:%@", digits];
                    kind = kKindPhone;
                } else if (result.resultType == NSTextCheckingTypeLink) {
                    NSURL *u = result.URL;
                    if (u == nil) return;
                    NSString *scheme = u.scheme.lowercaseString ?: @"";
                    kind = [scheme isEqualToString:@"mailto"] ? kKindEmail : kKindWeb;
                    url = u.absoluteString;
                    if (kind == kKindWeb) {
                        end = ux_web_end(utf16, r.location, end);
                        // After Chinese or Japanese text, NSDataDetector links
                        // such a host cut before the '.'; elsewhere it links
                        // none.
                        if (ux_glues_word(utf16, text.length, r.location, end)) return;
                        NSString *kept = [text substringWithRange:NSMakeRange(r.location, end - r.location)];
                        NSString *prefix = [scheme stringByAppendingString:@":"];
                        const BOOL written = [kept.lowercaseString hasPrefix:prefix];
                        if (!written) {
                            end = ux_port_end(utf16, text.length, r.location, end);
                            if (!ux_has_tld(utf16, r.location, end)) return;
                            kept = [kept substringToIndex:end - r.location];
                        }
                        // NSDataDetector's URL escapes the text's '%' escapes
                        // again, lowercases its host and punycodes an IDN
                        // host, so a web link's URL is the text it keeps,
                        // after the scheme NSDataDetector adds where the text
                        // has none.
                        url = written ? kept : [NSString stringWithFormat:@"%@//%@", prefix, kept];
                    }
                } else {
                    return;
                }
                if (url.length == 0) return;

                XUrlRawMatch *m = [[XUrlRawMatch alloc] init];
                m.start = (int32_t)r.location;
                m.end   = (int32_t)end;
                m.kind  = kind;
                m.urlUtf8 = ux_utf8(url);
                [raws addObject:m];
            }];
        }

        if (webRe != nil) {
            [webRe enumerateMatchesInString:text
                                    options:0
                                      range:whole
                                 usingBlock:^(NSTextCheckingResult *result,
                                              NSMatchingFlags flags,
                                              BOOL *stop) {
                if (result == nil) return;
                const NSRange r = result.range;
                if (r.location == NSNotFound || r.length == 0) return;
                const NSUInteger end = ux_web_end(utf16, r.location, NSMaxRange(r));
                const BOOL written = [result rangeAtIndex:1].location != NSNotFound;
                if (ux_glues_word(utf16, text.length, r.location, end) ||
                    (!written && !ux_has_tld(utf16, r.location, end))) return;
                NSString *substr = [text substringWithRange:NSMakeRange(r.location, end - r.location)];
                XUrlRawMatch *m = [[XUrlRawMatch alloc] init];
                m.start = (int32_t)r.location;
                m.end   = (int32_t)end;
                m.kind  = kKindWeb;
                m.urlUtf8 = ux_utf8(written ? substr : [@"http://" stringByAppendingString:substr]);
                [raws addObject:m];
            }];
        }

        if (raws.count == 0) return NULL;

        // Sort: start asc, then length desc, then kind desc (phone > email > web on tie).
        [raws sortUsingComparator:^NSComparisonResult(XUrlRawMatch *a, XUrlRawMatch *b) {
            if (a.start != b.start) return a.start < b.start ? NSOrderedAscending : NSOrderedDescending;
            int32_t la = a.end - a.start;
            int32_t lb = b.end - b.start;
            if (la != lb) return la > lb ? NSOrderedAscending : NSOrderedDescending;
            if (a.kind != b.kind) return a.kind > b.kind ? NSOrderedAscending : NSOrderedDescending;
            return NSOrderedSame;
        }];

        // Greedy de-overlap. Past a web match whose path runs on to a fullwidth
        // '(', kept or not, a web match that continues that path is no link of
        // its own.
        NSMutableArray<XUrlRawMatch *> *kept = [NSMutableArray arrayWithCapacity:raws.count];
        int32_t lastEnd = 0;
        BOOL haveAny = NO;
        NSNumber *cut = nil;
        for (XUrlRawMatch *m in raws) {
            if (m.kind == kKindWeb) {
                if (cut != nil && ux_continues_path(utf16, cut.unsignedIntegerValue, m.start, m.end)) continue;
                cut = ux_path_paren(utf16, text.length, m.start, m.end) ?: cut;
            }
            if (haveAny && m.start < lastEnd) continue;
            [kept addObject:m];
            lastEnd = m.end;
            haveAny = YES;
        }

        NSUInteger total = 4;
        for (XUrlRawMatch *m in kept) {
            total += 16 + (NSUInteger)m.urlUtf8.length;
        }

        uint8_t *buf = (uint8_t *)malloc(total);
        if (buf == NULL) return NULL;
        uint32_t cnt = (uint32_t)kept.count;
        memcpy(buf, &cnt, 4);
        NSUInteger off = 4;
        for (XUrlRawMatch *m in kept) {
            int32_t start = m.start;
            int32_t end   = m.end;
            uint32_t kind = m.kind;
            uint32_t urlLen = (uint32_t)m.urlUtf8.length;
            memcpy(buf + off + 0,  &start,  4);
            memcpy(buf + off + 4,  &end,    4);
            memcpy(buf + off + 8,  &kind,   4);
            memcpy(buf + off + 12, &urlLen, 4);
            memcpy(buf + off + 16, m.urlUtf8.bytes, urlLen);
            off += 16 + urlLen;
        }
        if (out_size) *out_size = (int32_t)total;
        return buf;
    }
}

extern "C" __attribute__((used, visibility("default")))
void ux_free(uint8_t *buf) {
    if (buf != NULL) free(buf);
}
