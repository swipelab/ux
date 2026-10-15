#include "work_queue.h"

#include <utility>

namespace ux {

WorkQueue::WorkQueue() : state_(std::make_shared<State>()), thread_(Run, state_) {}

WorkQueue::~WorkQueue() {
  {
    std::lock_guard<std::mutex> lock(state_->mutex);
    state_->closed = true;
  }
  state_->posted.notify_one();
  thread_.join();
}

WorkQueue::Poster WorkQueue::poster() const {
  return [state = state_](std::function<void()> task) { Post(state, std::move(task)); };
}

void WorkQueue::Post(const std::shared_ptr<State>& state, std::function<void()> task) {
  {
    std::lock_guard<std::mutex> lock(state->mutex);
    if (state->closed) return;
    state->tasks.push_back(std::move(task));
  }
  state->posted.notify_one();
}

void WorkQueue::Run(std::shared_ptr<State> state) {
  for (;;) {
    std::function<void()> task;
    {
      std::unique_lock<std::mutex> lock(state->mutex);
      state->posted.wait(lock, [&state] { return !state->tasks.empty() || state->closed; });
      if (state->tasks.empty()) return;
      task = std::move(state->tasks.front());
      state->tasks.pop_front();
    }
    task();
  }
}

}  // namespace ux
