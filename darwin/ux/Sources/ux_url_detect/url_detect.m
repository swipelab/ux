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
// Backed by NSDataDetector (.link | .phoneNumber). The detector itself
// won't flag bare domains like `google.com` (Apple's stock apps make
// the same trade-off), so we run a second pass with a tight regex that
// requires a `/` or `?` after the domain — that pulls in `example.com/path`
// without dragging in `etc.` / `v1.2.3` / `Mr.Smith` false positives.

#import <Foundation/Foundation.h>
#import <stdint.h>
#import <stdlib.h>
#import <string.h>

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

static NSRegularExpression *ux_url_bare_domain_regex(void) {
    static NSRegularExpression *regex;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Hostname segment + at least one dot-segment + `/` or `?` suffix,
        // which ends before whitespace, ux_is_cjk_punctuation's CJK
        // punctuation and the ASCII marks ux_web_end ends a path before, so a
        // bare domain glued after one links on its own.
        // ASCII-only; bare IDN domains stay undetected.
        NSString *pattern = @"\\b[a-z0-9-]+(\\.[a-z0-9-]+)+([/?](?:[^\\s\"%<>\\[\\\\\\]^`{|}"
                            @"\\u3001-\\u3003\\u3008-\\u3011\\u3014-\\u301F\\uFE10-\\uFE19\\uFE30-\\uFE6B"
                            @"\\uFF01-\\uFF0F\\uFF1A-\\uFF20\\uFF3B-\\uFF40\\uFF5B-\\uFF65]|%[0-9a-f]{2})*)";
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

// The first character in [i, end) that Patterns.WEB_URL's path does not take:
// whitespace, '"', '<', '>', '[', '\', ']', '^', '`', '{', '|', '}' or a '%'
// that two hex digits do not follow; `end` where there is none.
static NSUInteger ux_path_mark(const uint16_t *chars, NSUInteger i, NSUInteger end) {
    NSCharacterSet *whitespace = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    for (; i < end; i++) {
        const uint16_t c = chars[i];
        if (c == '%' ? !(i + 2 < end && ux_is_hex(chars[i + 1]) && ux_is_hex(chars[i + 2]))
                     : (c == '"' || c == '<' || c == '>' || c == '[' || c == '\\' || c == ']' ||
                        c == '^' || c == '`' || c == '{' || c == '|' || c == '}' ||
                        [whitespace characterIsMember:c])) {
            break;
        }
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

// The fullwidth '(' that ends the stretch of the text between CJK punctuation
// the web link [start, end) ends in, where the link has a path that runs on to
// it; nil otherwise.
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

// The end of the web match [start, end), which the bare-domain regex's suffix
// and NSDataDetector run past. The match ends before the first character its
// path does not take, then before a trailing '.', ',', ';', '!', '\'' or '('
// and a trailing ')' it does not open.
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

static NSData *ux_utf8(NSString *s) {
    return [s dataUsingEncoding:NSUTF8StringEncoding allowLossyConversion:YES];
}

__attribute__((used, visibility("default")))
uint8_t *ux_match_url(const uint16_t *utf16, int32_t len, int32_t *out_size) {
    if (out_size) *out_size = 0;
    if (utf16 == NULL || len <= 0) return NULL;

    @autoreleasepool {
        NSString *text = [[NSString alloc] initWithCharacters:(const unichar *)utf16
                                                        length:(NSUInteger)len];
        if (text.length == 0) return NULL;

        NSRange whole = NSMakeRange(0, text.length);
        NSMutableArray<XUrlRawMatch *> *raws = [NSMutableArray array];

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
                        // NSDataDetector's URL covers the uncut text, escaped,
                        // so a cut link's URL is the text it keeps, after the
                        // scheme NSDataDetector adds where the text has none.
                        if (end < NSMaxRange(r)) {
                            NSString *kept = [text substringWithRange:NSMakeRange(r.location, end - r.location)];
                            NSString *prefix = [scheme stringByAppendingString:@":"];
                            url = [kept.lowercaseString hasPrefix:prefix]
                                      ? kept
                                      : [NSString stringWithFormat:@"%@//%@", prefix, kept];
                        }
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

        NSRegularExpression *bareRe = ux_url_bare_domain_regex();
        if (bareRe != nil) {
            [bareRe enumerateMatchesInString:text
                                     options:0
                                       range:whole
                                  usingBlock:^(NSTextCheckingResult *result,
                                               NSMatchingFlags flags,
                                               BOOL *stop) {
                if (result == nil) return;
                const NSRange r = result.range;
                if (r.location == NSNotFound || r.length == 0) return;
                const NSUInteger end = ux_web_end(utf16, r.location, NSMaxRange(r));
                NSString *substr = [text substringWithRange:NSMakeRange(r.location, end - r.location)];
                NSString *withScheme = [@"http://" stringByAppendingString:substr];
                XUrlRawMatch *m = [[XUrlRawMatch alloc] init];
                m.start = (int32_t)r.location;
                m.end   = (int32_t)end;
                m.kind  = kKindWeb;
                m.urlUtf8 = ux_utf8(withScheme);
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

        // Greedy de-overlap. Past a web link whose path runs on to a fullwidth
        // '(', a web match that continues that path is no link of its own.
        NSMutableArray<XUrlRawMatch *> *kept = [NSMutableArray arrayWithCapacity:raws.count];
        int32_t lastEnd = 0;
        BOOL haveAny = NO;
        NSNumber *cut = nil;
        for (XUrlRawMatch *m in raws) {
            if (haveAny && m.start < lastEnd) continue;
            if (m.kind == kKindWeb && cut != nil &&
                ux_continues_path(utf16, cut.unsignedIntegerValue, m.start, m.end)) continue;
            [kept addObject:m];
            lastEnd = m.end;
            haveAny = YES;
            if (m.kind == kKindWeb) cut = ux_path_paren(utf16, text.length, m.start, m.end) ?: cut;
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

__attribute__((used, visibility("default")))
void ux_free(uint8_t *buf) {
    if (buf != NULL) free(buf);
}
