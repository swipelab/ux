#include <windows.h>

#include <bcrypt.h>

#include <array>
#include <cstdint>
#include <optional>
#include <vector>

#include "../aes_ctr.h"
#include "check.h"

using ux::AesCounter;
using ux::AesCtr;
using ux::AesKey;

namespace {

// NIST SP 800-38A, F.5.5 CTR-AES256.Encrypt.
constexpr AesKey kKey = {0x60, 0x3d, 0xeb, 0x10, 0x15, 0xca, 0x71, 0xbe, 0x2b, 0x73, 0xae, 0xf0, 0x85, 0x7d, 0x77, 0x81,
                         0x1f, 0x35, 0x2c, 0x07, 0x3b, 0x61, 0x08, 0xd7, 0x2d, 0x98, 0x10, 0xa3, 0x09, 0x14, 0xdf, 0xf4};
constexpr AesCounter kInitialCounter = {0xf0, 0xf1, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7,
                                        0xf8, 0xf9, 0xfa, 0xfb, 0xfc, 0xfd, 0xfe, 0xff};
const std::vector<uint8_t> kPlaintext = {
    0x6b, 0xc1, 0xbe, 0xe2, 0x2e, 0x40, 0x9f, 0x96, 0xe9, 0x3d, 0x7e, 0x11, 0x73, 0x93, 0x17, 0x2a,
    0xae, 0x2d, 0x8a, 0x57, 0x1e, 0x03, 0xac, 0x9c, 0x9e, 0xb7, 0x6f, 0xac, 0x45, 0xaf, 0x8e, 0x51,
    0x30, 0xc8, 0x1c, 0x46, 0xa3, 0x5c, 0xe4, 0x11, 0xe5, 0xfb, 0xc1, 0x19, 0x1a, 0x0a, 0x52, 0xef,
    0xf6, 0x9f, 0x24, 0x45, 0xdf, 0x4f, 0x9b, 0x17, 0xad, 0x2b, 0x41, 0x7b, 0xe6, 0x6c, 0x37, 0x10,
};
const std::vector<uint8_t> kCiphertext = {
    0x60, 0x1e, 0xc3, 0x13, 0x77, 0x57, 0x89, 0xa5, 0xb7, 0xa7, 0xf5, 0x04, 0xbb, 0xf3, 0xd2, 0x28,
    0xf4, 0x43, 0xe3, 0xca, 0x4d, 0x62, 0xb5, 0x9a, 0xca, 0x84, 0xe9, 0x90, 0xca, 0xca, 0xf5, 0xc5,
    0x2b, 0x09, 0x30, 0xda, 0xa2, 0x3d, 0xe9, 0x4c, 0xe8, 0x70, 0x17, 0xba, 0x2d, 0x84, 0x98, 0x8d,
    0xdf, 0xc9, 0xc5, 0x8d, 0xb6, 0x7a, 0xad, 0xa6, 0x13, 0xc2, 0xdd, 0x08, 0x45, 0x79, 0x41, 0xa6,
};

std::vector<uint8_t> Slice(const std::vector<uint8_t>& bytes, size_t from, size_t to) {
  return std::vector<uint8_t>(bytes.begin() + from, bytes.begin() + to);
}

std::vector<uint8_t> Ramp(size_t length) {
  std::vector<uint8_t> bytes(length);
  for (size_t i = 0; i < length; i++) bytes[i] = static_cast<uint8_t>(i * 31 + 7);
  return bytes;
}

// AES-256-CTR with one CNG call per counter block, incrementing the counter
// byte by byte.
std::vector<uint8_t> Reference(const AesKey& key, AesCounter counter, uint64_t pos, const std::vector<uint8_t>& data) {
  const auto increment = [&counter] {
    for (size_t i = counter.size(); i-- > 0 && ++counter[i] == 0;) {
    }
  };
  BCRYPT_KEY_HANDLE handle = nullptr;
  CHECK(BCRYPT_SUCCESS(BCryptGenerateSymmetricKey(BCRYPT_AES_ECB_ALG_HANDLE, &handle, nullptr, 0,
                                                  const_cast<PUCHAR>(key.data()), static_cast<ULONG>(key.size()), 0)));
  for (uint64_t block = 0; block < pos / 16; block++) increment();
  std::vector<uint8_t> out = data;
  size_t skip = pos % 16;
  for (size_t i = 0; i < out.size(); increment()) {
    std::array<uint8_t, 16> keystream;
    ULONG encrypted = 0;
    CHECK(BCRYPT_SUCCESS(
        BCryptEncrypt(handle, counter.data(), 16, nullptr, nullptr, 0, keystream.data(), 16, &encrypted, 0)));
    for (size_t k = skip; k < keystream.size() && i < out.size(); k++) out[i++] ^= keystream[k];
    skip = 0;
  }
  BCryptDestroyKey(handle);
  return out;
}

}  // namespace

void CryptoSuite() {
  CHECK(AesCtr(kKey, kInitialCounter, 0, kPlaintext) == kCiphertext);
  CHECK(AesCtr(kKey, kInitialCounter, 21, Slice(kPlaintext, 21, 51)) == Slice(kCiphertext, 21, 51));

  // From inside a block, across several CNG calls, and through the carry from
  // the counter's low 64 bits into its high 64 bits, 625 blocks in.
  const AesCounter low_wraps = {0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01,
                                0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xec, 0x78};
  const std::vector<uint8_t> long_data = Ramp(200003);
  CHECK(AesCtr(kKey, low_wraps, 70001, long_data) == Reference(kKey, low_wraps, 70001, long_data));

  // Advancing by pos wraps the whole counter to zero.
  AesCounter all_ones;
  all_ones.fill(0xff);
  const std::vector<uint8_t> short_data = Ramp(32);
  CHECK(AesCtr(kKey, all_ones, 16, short_data) == Reference(kKey, all_ones, 16, short_data));
}
