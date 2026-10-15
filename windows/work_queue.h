#ifndef UX_WORK_QUEUE_H_
#define UX_WORK_QUEUE_H_

#include <condition_variable>
#include <deque>
#include <functional>
#include <memory>
#include <mutex>
#include <thread>

namespace ux {

// Runs posted tasks one at a time, in order, on a thread of its own.
class WorkQueue {
 public:
  // Hands a task to the queue from any thread. A task posted once the queue's
  // destructor has started does not run.
  using Poster = std::function<void(std::function<void()>)>;

  WorkQueue();
  // Runs the tasks posted before it, then joins the thread.
  ~WorkQueue();

  WorkQueue(const WorkQueue&) = delete;
  WorkQueue& operator=(const WorkQueue&) = delete;

  Poster poster() const;

 private:
  struct State {
    std::mutex mutex;
    std::condition_variable posted;
    std::deque<std::function<void()>> tasks;
    bool closed = false;
  };

  static void Post(const std::shared_ptr<State>& state, std::function<void()> task);
  static void Run(std::shared_ptr<State> state);

  const std::shared_ptr<State> state_;
  std::thread thread_;
};

}  // namespace ux

#endif  // UX_WORK_QUEUE_H_
