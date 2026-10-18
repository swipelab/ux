// The oracle's probe, linked with a commit's native detector: url_detect.mm,
// or windows/url_detect.cpp on ICU for win_icu.
//
//   probe texts <in> <out> [-AppleLocale <locale>]
//     <in> holds one text per line, as base64 of its UTF-16LE code units. Each
//     line of <out> is a JSON object for the text on that line: "b", base64 of
//     ux_match_url's buffer, and "r", raw NSDataDetector's results for
//     .link | .phoneNumber as [start, end, "l" or "p", base64 of the URL's or
//     phone number's UTF-16LE code units].
//
//   probe stages <in> <out> [-AppleLocale <locale>]
//     As texts, each line also holding "c", url_detect.mm's candidates before
//     its sort, as [start, end, kind, base64 of the URL's UTF-8 bytes, "n" for
//     NSDataDetector's or "s" for the second pass's]. Only a build whose
//     url_detect.mm calls ux_probe_stages there reads them.
//
//   probe props <out>
//     <out> is a JSON object of inclusive code point ranges: "letter" and
//     "digit", NSCharacterSet's letterCharacterSet and decimalDigitCharacterSet,
//     and "word" and "space", ICU's \w and \s through NSRegularExpression.

#import <Foundation/Foundation.h>

#include <cstdio>
#include <optional>
#include <string>
#include <vector>

extern "C" uint8_t *ux_match_url(const uint16_t *utf16, int32_t len, int32_t *out_size);
extern "C" void ux_free(uint8_t *buf);

struct Candidate {
    int32_t start;
    int32_t end;
    uint32_t kind;
    std::string url;
    bool nsdd;
};

// The candidates of the ux_match_url call on this thread, where one is read.
static thread_local std::vector<Candidate> *stagesOut = nullptr;

// Called by url_detect.mm with its candidates, the first nsdd of them
// NSDataDetector's.
extern "C" void ux_probe_stages(NSArray *raws, NSUInteger nsdd) {
    if (stagesOut == nullptr) return;
    NSUInteger i = 0;
    for (id m in raws) {
        NSData *url = [m valueForKey:@"urlUtf8"];
        stagesOut->push_back({[[m valueForKey:@"start"] intValue], [[m valueForKey:@"end"] intValue],
                              [[m valueForKey:@"kind"] unsignedIntValue],
                              std::string((const char *)url.bytes, url.length), i < nsdd});
        i++;
    }
}

static NSString *Utf16Base64(NSString *s) {
    std::vector<unichar> units(s.length);
    [s getCharacters:units.data() range:NSMakeRange(0, s.length)];
    NSData *data = [NSData dataWithBytes:units.data() length:units.size() * sizeof(unichar)];
    return [data base64EncodedStringWithOptions:0];
}

static NSString *TextFromBase64(NSString *line) {
    NSData *data = [[NSData alloc] initWithBase64EncodedString:line options:0];
    return [[NSString alloc] initWithCharacters:(const unichar *)data.bytes length:data.length / sizeof(unichar)];
}

static NSString *Probe(NSDataDetector *detector, NSString *text, BOOL stages) {
    const NSUInteger len = text.length;
    std::vector<unichar> units(len);
    [text getCharacters:units.data() range:NSMakeRange(0, len)];
    std::vector<Candidate> candidates;
    stagesOut = stages ? &candidates : nullptr;
    int32_t size = 0;
    uint8_t *buf = len == 0 ? NULL : ux_match_url(units.data(), (int32_t)len, &size);
    stagesOut = nullptr;
    NSData *buffer = [NSData dataWithBytes:buf length:buf == NULL ? 0 : (NSUInteger)size];
    ux_free(buf);

    NSMutableArray *raw = [NSMutableArray array];
    [detector enumerateMatchesInString:text
                               options:0
                                 range:NSMakeRange(0, len)
                            usingBlock:^(NSTextCheckingResult *result, NSMatchingFlags flags, BOOL *stop) {
        const NSRange r = result.range;
        const BOOL phone = result.resultType == NSTextCheckingTypePhoneNumber;
        NSString *value = phone ? (result.phoneNumber ?: @"") : (result.URL.absoluteString ?: @"");
        [raw addObject:@[ @(r.location), @(NSMaxRange(r)), phone ? @"p" : @"l", Utf16Base64(value) ]];
    }];
    NSMutableDictionary *line = [@{@"b" : [buffer base64EncodedStringWithOptions:0], @"r" : raw} mutableCopy];
    if (stages) {
        NSMutableArray *c = [NSMutableArray array];
        for (const Candidate &m : candidates) {
            NSData *url = [NSData dataWithBytes:m.url.data() length:m.url.size()];
            [c addObject:@[ @(m.start), @(m.end), @(m.kind), [url base64EncodedStringWithOptions:0], m.nsdd ? @"n" : @"s" ]];
        }
        line[@"c"] = c;
    }
    NSData *json = [NSJSONSerialization dataWithJSONObject:line options:0 error:nil];
    return [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
}

static int Texts(NSString *inPath, NSString *outPath, BOOL stages) {
    NSString *input = [NSString stringWithContentsOfFile:inPath encoding:NSUTF8StringEncoding error:nil];
    if (input == nil) {
        std::fprintf(stderr, "probe: cannot read %s\n", inPath.UTF8String);
        return 1;
    }
    NSMutableArray<NSString *> *lines = [[input componentsSeparatedByString:@"\n"] mutableCopy];
    if (lines.lastObject.length == 0) [lines removeLastObject];
    NSDataDetector *detector =
        [NSDataDetector dataDetectorWithTypes:NSTextCheckingTypeLink | NSTextCheckingTypePhoneNumber error:nil];
    const NSUInteger count = lines.count;
    std::vector<NSString *> out(count);
    NSString *__strong *slots = out.data();
    dispatch_apply(count, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t i) {
        @autoreleasepool {
            slots[i] = Probe(detector, TextFromBase64(lines[i]), stages);
        }
    });
    NSMutableString *joined = [NSMutableString string];
    for (NSString *line : out) [joined appendFormat:@"%@\n", line];
    return [joined writeToFile:outPath atomically:YES encoding:NSUTF8StringEncoding error:nil] ? 0 : 1;
}

static NSArray *Ranges(BOOL (^member)(UTF32Char)) {
    NSMutableArray *ranges = [NSMutableArray array];
    std::optional<UTF32Char> start;
    for (UTF32Char c = 0; c <= 0x110000; c++) {
        const BOOL in = c < 0x110000 && !(c >= 0xD800 && c <= 0xDFFF) && member(c);
        if (in && !start.has_value()) start = c;
        if (!in && start.has_value()) {
            [ranges addObject:@[ @(*start), @(c - 1) ]];
            start.reset();
        }
    }
    return ranges;
}

static BOOL MatchesWhole(NSRegularExpression *re, UTF32Char c) {
    NSString *s = [[NSString alloc] initWithBytes:&c length:4 encoding:NSUTF32LittleEndianStringEncoding];
    const NSRange whole = NSMakeRange(0, s.length);
    return NSEqualRanges([re rangeOfFirstMatchInString:s options:NSMatchingAnchored range:whole], whole);
}

static int Props(NSString *outPath) {
    NSCharacterSet *letters = NSCharacterSet.letterCharacterSet;
    NSCharacterSet *digits = NSCharacterSet.decimalDigitCharacterSet;
    NSRegularExpression *word = [NSRegularExpression regularExpressionWithPattern:@"\\w" options:0 error:nil];
    NSRegularExpression *space = [NSRegularExpression regularExpressionWithPattern:@"\\s" options:0 error:nil];
    NSDictionary *props = @{
        @"letter" : Ranges(^BOOL(UTF32Char c) { return [letters longCharacterIsMember:c]; }),
        @"digit" : Ranges(^BOOL(UTF32Char c) { return [digits longCharacterIsMember:c]; }),
        @"word" : Ranges(^BOOL(UTF32Char c) { return MatchesWhole(word, c); }),
        @"space" : Ranges(^BOOL(UTF32Char c) { return MatchesWhole(space, c); }),
    };
    NSData *json = [NSJSONSerialization dataWithJSONObject:props options:0 error:nil];
    return [json writeToFile:outPath atomically:YES] ? 0 : 1;
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        const std::string mode = argc > 1 ? argv[1] : "";
        if ((mode == "texts" || mode == "stages") && argc >= 4) return Texts(@(argv[2]), @(argv[3]), mode == "stages");
        if (mode == "props" && argc >= 3) return Props(@(argv[2]));
        std::fprintf(stderr, "usage: probe texts|stages <in> <out> [-AppleLocale <locale>] | probe props <out>\n");
        return 2;
    }
}
