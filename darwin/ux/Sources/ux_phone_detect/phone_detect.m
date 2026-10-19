// XUrl.match's phones on iOS, over dart:ffi:
//
//   uint8_t *ux_match_phones(const uint16_t *utf16, int32_t len, int32_t *out_size);
//   void     ux_free(uint8_t *buf);
//
// The buffer, of out_size bytes in the platform's byte order, holds a u32
// count and then, for each phone NSDataDetector reads, its i32 start, i32 end
// and u32 length and that many UTF-16 units of its phoneNumber.

#import <Foundation/Foundation.h>
#import <stdint.h>
#import <stdlib.h>
#import <string.h>

static NSDataDetector *ux_phone_detector(void) {
    static NSDataDetector *detector;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        detector = [NSDataDetector dataDetectorWithTypes:NSTextCheckingTypePhoneNumber error:NULL];
    });
    return detector;
}

__attribute__((used, visibility("default")))
uint8_t *ux_match_phones(const uint16_t *utf16, int32_t len, int32_t *out_size) {
    @autoreleasepool {
        NSString *text = [[NSString alloc] initWithCharacters:(const unichar *)utf16
                                                       length:(NSUInteger)len];
        NSArray<NSTextCheckingResult *> *phones =
            [ux_phone_detector() matchesInString:text options:0 range:NSMakeRange(0, text.length)];
        size_t size = 4;
        for (NSTextCheckingResult *phone in phones) size += 12 + 2 * phone.phoneNumber.length;
        uint8_t *buf = malloc(size);
        uint32_t count = (uint32_t)phones.count;
        memcpy(buf, &count, 4);
        size_t at = 4;
        for (NSTextCheckingResult *phone in phones) {
            int32_t start = (int32_t)phone.range.location;
            int32_t end = (int32_t)NSMaxRange(phone.range);
            NSString *number = phone.phoneNumber;
            uint32_t length = (uint32_t)number.length;
            memcpy(buf + at, &start, 4);
            memcpy(buf + at + 4, &end, 4);
            memcpy(buf + at + 8, &length, 4);
            [number getCharacters:(unichar *)(buf + at + 12) range:NSMakeRange(0, length)];
            at += 12 + 2 * (size_t)length;
        }
        *out_size = (int32_t)size;
        return buf;
    }
}

__attribute__((used, visibility("default")))
void ux_free(uint8_t *buf) {
    free(buf);
}
