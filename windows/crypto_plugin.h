#ifndef UX_CRYPTO_PLUGIN_H_
#define UX_CRYPTO_PLUGIN_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar.h>

#include <memory>

#include "platform_thread.h"

namespace ux {

// `ux/crypto`: AES-256-CTR (aes_ctr.h) off the platform thread. `aesCtrRange`
// reads the range of a file itself, so only its ciphertext crosses the
// channel, and `aesCtrBytes` encrypts the bytes it is given.
class CryptoPlugin : public flutter::Plugin {
 public:
  explicit CryptoPlugin(flutter::BinaryMessenger* messenger);

  CryptoPlugin(const CryptoPlugin&) = delete;
  CryptoPlugin& operator=(const CryptoPlugin&) = delete;

 private:
  void HandleMethodCall(const flutter::MethodCall<flutter::EncodableValue>& call,
                        std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  PlatformThread platform_;
};

}  // namespace ux

#endif  // UX_CRYPTO_PLUGIN_H_
