#include "crypto_plugin.h"

#include <windows.h>

#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <array>
#include <cstdint>
#include <optional>
#include <string>
#include <utility>
#include <variant>
#include <vector>

#include "aes_ctr.h"
#include "method_args.h"

namespace ux {

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;

// A call's ciphertext, or why it has none.
using Outcome = std::variant<std::vector<uint8_t>, std::string>;

// A non-negative integer argument.
std::optional<uint64_t> OffsetArg(const EncodableMap* args, const char* key) {
  const std::optional<int64_t> number = IntArg(args, key);
  if (!number || *number < 0) return std::nullopt;
  return static_cast<uint64_t>(*number);
}

const std::vector<uint8_t>* BytesArg(const EncodableMap* args, const char* key) {
  return std::get_if<std::vector<uint8_t>>(Arg(args, key));
}

// A bytes argument that holds exactly N bytes.
template <size_t N>
std::optional<std::array<uint8_t, N>> FixedBytesArg(const EncodableMap* args, const char* key) {
  const std::vector<uint8_t>* bytes = BytesArg(args, key);
  if (bytes == nullptr || bytes->size() != N) return std::nullopt;
  std::array<uint8_t, N> fixed;
  std::copy(bytes->begin(), bytes->end(), fixed.begin());
  return fixed;
}

// Bytes [pos, pos + size) of the file at [path], or none when it cannot be
// opened or ends before pos + size.
std::optional<std::vector<uint8_t>> ReadRange(const std::wstring& path, uint64_t pos, uint64_t size) {
  const HANDLE file = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                                  nullptr, OPEN_EXISTING, FILE_FLAG_SEQUENTIAL_SCAN, nullptr);
  if (file == INVALID_HANDLE_VALUE) return std::nullopt;
  const std::unique_ptr<void, decltype(&CloseHandle)> owned(file, CloseHandle);
  LARGE_INTEGER length;
  if (!GetFileSizeEx(file, &length)) return std::nullopt;
  const auto end = static_cast<uint64_t>(length.QuadPart);
  if (pos > end || size > end - pos) return std::nullopt;
  LARGE_INTEGER offset;
  offset.QuadPart = static_cast<LONGLONG>(pos);
  if (!SetFilePointerEx(file, offset, nullptr, FILE_BEGIN)) return std::nullopt;
  std::vector<uint8_t> bytes(static_cast<size_t>(size));
  for (size_t read = 0; read < bytes.size();) {
    const auto chunk = static_cast<DWORD>(std::min<size_t>(bytes.size() - read, MAXDWORD));
    DWORD got = 0;
    if (!ReadFile(file, bytes.data() + read, chunk, &got, nullptr) || got == 0) return std::nullopt;
    read += got;
  }
  return bytes;
}

Outcome Encrypt(const AesKey& key, const AesCounter& iv, uint64_t pos, std::vector<uint8_t> plain) {
  std::optional<std::vector<uint8_t>> cipher = AesCtr(key, iv, pos, std::move(plain));
  if (!cipher) return std::string("CNG could not encrypt the counter blocks");
  return std::move(*cipher);
}

}  // namespace

CryptoPlugin::CryptoPlugin(flutter::BinaryMessenger* messenger)
    : channel_(std::make_unique<flutter::MethodChannel<EncodableValue>>(
          messenger, "ux/crypto", &flutter::StandardMethodCodec::GetInstance())) {
  channel_->SetMethodCallHandler([this](const auto& call, auto result) { HandleMethodCall(call, std::move(result)); });
}

void CryptoPlugin::HandleMethodCall(const flutter::MethodCall<EncodableValue>& call,
                                    std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  const std::string& method = call.method_name();
  if (method != "aesCtrRange" && method != "aesCtrBytes") {
    result->NotImplemented();
    return;
  }
  const auto* args = std::get_if<EncodableMap>(call.arguments());
  const std::optional<AesKey> key = FixedBytesArg<32>(args, "key");
  const std::optional<AesCounter> iv = FixedBytesArg<16>(args, "iv");
  const std::optional<uint64_t> pos = OffsetArg(args, "pos");
  if (!key || !iv || !pos) {
    result->Error("bad_args", "key must be 32 bytes, iv 16, and pos >= 0");
    return;
  }
  std::shared_ptr<flutter::MethodResult<EncodableValue>> reply = std::move(result);
  const auto answer = [reply](Outcome outcome) {
    if (auto* cipher = std::get_if<std::vector<uint8_t>>(&outcome)) {
      reply->Success(EncodableValue(std::move(*cipher)));
    } else {
      reply->Error("aes_failed", std::get<std::string>(outcome));
    }
  };
  if (method == "aesCtrBytes") {
    const std::vector<uint8_t>* data = BytesArg(args, "data");
    if (data == nullptr) {
      reply->Error("bad_args", "data is required");
      return;
    }
    platform_.Background<Outcome>(
        [key = *key, iv = *iv, pos = *pos, plain = *data]() mutable { return Encrypt(key, iv, pos, std::move(plain)); },
        answer);
    return;
  }
  std::optional<std::wstring> path = PathArg(args, "path");
  const std::optional<uint64_t> size = OffsetArg(args, "size");
  if (!path || !size) {
    reply->Error("bad_args", "path and size >= 0 are required");
    return;
  }
  platform_.Background<Outcome>(
      [path = std::move(*path), key = *key, iv = *iv, pos = *pos, size = *size]() -> Outcome {
        std::optional<std::vector<uint8_t>> plain = ReadRange(path, pos, size);
        if (!plain) return "cannot read " + std::to_string(size) + " bytes at " + std::to_string(pos);
        return Encrypt(key, iv, pos, std::move(*plain));
      },
      answer);
}

}  // namespace ux
