#ifndef UX_TEST_CHECK_H_
#define UX_TEST_CHECK_H_

#include <atomic>
#include <cstdio>

// The failed checks of the running suite.
inline std::atomic<int> check_failures{0};

#define CHECK(condition)                                                  \
  do {                                                                    \
    if (!(condition)) {                                                   \
      std::printf("%s:%d: CHECK(%s) failed\n", __FILE__, __LINE__, #condition); \
      check_failures++;                                                   \
    }                                                                     \
  } while (false)

#endif  // UX_TEST_CHECK_H_
