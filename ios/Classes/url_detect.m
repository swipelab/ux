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
        // Hostname segment + at least one dot-segment + `/` or `?` suffix.
        // ASCII-only; bare IDN domains stay undetected.
        NSString *pattern = @"\\b[a-z0-9-]+(\\.[a-z0-9-]+)+([/?][^\\s]*)";
        NSError *err = nil;
        regex = [NSRegularExpression
            regularExpressionWithPattern:pattern
                                 options:NSRegularExpressionCaseInsensitive
                                   error:&err];
    });
    return regex;
}

static NSData *ux_utf8(NSString *s) {
    return [s dataUsingEncoding:NSUTF8StringEncoding allowLossyConversion:YES];
}

__attribute__((visibility("default")))
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
                } else {
                    return;
                }
                if (url.length == 0) return;

                XUrlRawMatch *m = [[XUrlRawMatch alloc] init];
                m.start = (int32_t)r.location;
                m.end   = (int32_t)(r.location + r.length);
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
                NSString *substr = [text substringWithRange:r];
                NSString *withScheme = [@"http://" stringByAppendingString:substr];
                XUrlRawMatch *m = [[XUrlRawMatch alloc] init];
                m.start = (int32_t)r.location;
                m.end   = (int32_t)(r.location + r.length);
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

        // Greedy de-overlap.
        NSMutableArray<XUrlRawMatch *> *kept = [NSMutableArray arrayWithCapacity:raws.count];
        int32_t lastEnd = 0;
        BOOL haveAny = NO;
        for (XUrlRawMatch *m in raws) {
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

__attribute__((visibility("default")))
void ux_free(uint8_t *buf) {
    if (buf != NULL) free(buf);
}
