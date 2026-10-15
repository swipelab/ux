#include <windows.h>

#include <set>
#include <vector>

#include "../work_queue.h"
#include "check.h"

void WorkQueueSuite() {
  std::vector<int> ran;
  std::set<DWORD> threads;
  {
    ux::WorkQueue queue;
    const ux::WorkQueue::Poster post = queue.poster();
    for (int i = 0; i < 100; i++) {
      post([&ran, &threads, i] {
        ran.push_back(i);
        threads.insert(GetCurrentThreadId());
      });
    }
  }
  std::vector<int> posted;
  for (int i = 0; i < 100; i++) posted.push_back(i);
  CHECK(ran == posted);
  CHECK(threads.size() == 1 && threads.count(GetCurrentThreadId()) == 0);

  ux::WorkQueue::Poster stale;
  {
    ux::WorkQueue queue;
    stale = queue.poster();
  }
  bool late = false;
  stale([&late] { late = true; });
  CHECK(!late);
}
