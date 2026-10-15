#ifndef UX_TEST_CHECK_H_
#define UX_TEST_CHECK_H_

#include <atomic>
#include <cstdio>
#include <optional>

// The failed checks of the running suite.
inline std::atomic<int> check_failures{0};

// Why the running suite cannot run in this process, which ux_test reports as
// a skip.
inline std::optional<const char*> check_skipped;

#define CHECK(condition)                                                  \
  do {                                                                    \
    if (!(condition)) {                                                   \
      std::printf("%s:%d: CHECK(%s) failed\n", __FILE__, __LINE__, #condition); \
      check_failures++;                                                   \
    }                                                                     \
  } while (false)

#endif  // UX_TEST_CHECK_H_
