#include "aes_ctr.h"

#include <windows.h>

#include <bcrypt.h>

#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <utility>

namespace ux {

namespace {

constexpr size_t kBlockBytes = 16;

// The counter blocks one CNG call encrypts.
constexpr size_t kBatchBlocks = 4096;

// A counter block's two halves, in host order.
struct Counter {
  uint64_t high;
  uint64_t low;
};

Counter Load(const AesCounter& block) {
  Counter counter{0, 0};
  for (size_t i = 0; i < 8; i++) counter.high = counter.high << 8 | block[i];
  for (size_t i = 8; i < kBlockBytes; i++) counter.low = counter.low << 8 | block[i];
  return counter;
}

void Advance(Counter& counter, uint64_t blocks) {
  const uint64_t low = counter.low + blocks;
  if (low < counter.low) counter.high++;
  counter.low = low;
}

}  // namespace

std::optional<std::vector<uint8_t>> AesCtr(const AesKey& key, const AesCounter& iv, uint64_t pos,
                                           std::vector<uint8_t> data) {
  BCRYPT_KEY_HANDLE handle = nullptr;
  if (!BCRYPT_SUCCESS(BCryptGenerateSymmetricKey(BCRYPT_AES_ECB_ALG_HANDLE, &handle, nullptr, 0,
                                                 const_cast<PUCHAR>(key.data()), static_cast<ULONG>(key.size()), 0))) {
    return std::nullopt;
  }
  const std::unique_ptr<void, decltype(&BCryptDestroyKey)> owned(handle, BCryptDestroyKey);

  Counter counter = Load(iv);
  Advance(counter, pos / kBlockBytes);
  size_t skip = pos % kBlockBytes;
  // Each counter block as its two halves, big-endian.
  std::vector<uint64_t> blocks(2 * kBatchBlocks);
  std::vector<uint64_t> keystream(2 * kBatchBlocks);
  uint8_t* out = data.data();
  size_t left = data.size();
  while (left > 0) {
    const size_t count = std::min<size_t>(kBatchBlocks, (skip + left + kBlockBytes - 1) / kBlockBytes);
    uint64_t* block = blocks.data();
    for (size_t i = 0; i < count; i++) {
      *block++ = _byteswap_uint64(counter.high);
      *block++ = _byteswap_uint64(counter.low);
      Advance(counter, 1);
    }
    const auto bytes = static_cast<ULONG>(count * kBlockBytes);
    ULONG encrypted = 0;
    if (!BCRYPT_SUCCESS(BCryptEncrypt(handle, reinterpret_cast<PUCHAR>(blocks.data()), bytes, nullptr, nullptr, 0,
                                      reinterpret_cast<PUCHAR>(keystream.data()), bytes, &encrypted, 0)) ||
        encrypted != bytes) {
      return std::nullopt;
    }
    const uint8_t* stream = reinterpret_cast<const uint8_t*>(keystream.data()) + skip;
    const size_t n = std::min<size_t>(left, bytes - skip);
    // Word by word, since a debug build does not vectorize a loop over bytes.
    size_t i = 0;
    for (; i + sizeof(uint64_t) <= n; i += sizeof(uint64_t)) {
      uint64_t word;
      uint64_t key_word;
      std::memcpy(&word, out + i, sizeof(word));
      std::memcpy(&key_word, stream + i, sizeof(key_word));
      word ^= key_word;
      std::memcpy(out + i, &word, sizeof(word));
    }
    for (; i < n; i++) out[i] ^= stream[i];
    out += n;
    left -= n;
    skip = 0;
  }
  return std::move(data);
}

}  // namespace ux
