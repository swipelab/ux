#ifndef UX_AES_CTR_H_
#define UX_AES_CTR_H_

#include <array>
#include <cstdint>
#include <optional>
#include <vector>

namespace ux {

using AesKey = std::array<uint8_t, 32>;

// A counter block: a 128-bit big-endian counter, which wraps.
using AesCounter = std::array<uint8_t, 16>;

// [data] XORed with bytes [pos, pos + data.size()) of the AES-256-CTR keystream
// of [key] whose first counter block is [iv], so a slice encrypts as the same
// bytes of one stream from offset 0 do, and decrypts the same way; none when
// CNG fails. Counter blocks are encrypted with CNG's AES in ECB mode, which
// uses the CPU's AES instructions where it has them.
std::optional<std::vector<uint8_t>> AesCtr(const AesKey& key, const AesCounter& iv, uint64_t pos,
                                           std::vector<uint8_t> data);

}  // namespace ux

#endif  // UX_AES_CTR_H_
