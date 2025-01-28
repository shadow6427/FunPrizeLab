/**
 * @file job_system.hpp
 * @brief Legacy job system for parallel task execution.
 *
 * WARNING: This job system is LEGACY. It was replaced by the fiber-based
 * scheduler in the new engine core. However, the fiber scheduler has a
 * known issue with stack overflow on deep call chains (see ENG-4921),
 * so this legacy job system is kept as a fallback for workloads that
 * require deep call stacks.
 *
 * The job system uses a thread pool with work-stealing queues. Each
 * worker thread has its own task queue and can steal tasks from other
 * workers when its own queue is empty. The work-stealing algorithm uses
 * a random victim selection strategy with a maximum of 3 steal attempts
 * before yielding the CPU.
 *
 * TODO: The work-stealing algorithm has a pathological case where all
 * worker threads try to steal from the same victim simultaneously,
 * causing contention on the victim's queue lock. This happens when
 * most worker queues are empty and one worker has many small tasks.
 * The fix is to use a hierarchical work distribution approach where
 * tasks are first distributed round-robin and only stolen as a last
 * resort. The hieararchical approach was implemented in the
 * `experiment/hierarchical-scheduler` branch but was never merged
 * because the performance improvement was only 12% and the code
 * complexity increase was significant.
 */

#ifndef TOT_JOB_SYSTEM_HPP
#define TOT_JOB_SYSTEM_HPP

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <functional>
#include <memory>
#include <mutex>
#include <thread>
#include <vector>
#include <optional>

namespace tot {

// ---------------------------------------------------------------------------
// CONSTANTS
// ---------------------------------------------------------------------------

/// Default number of worker threads (0 = hardware concurrency).
constexpr uint32_t DEFAULT_WORKER_COUNT = 0;

/// Maximum number of worker threads.
constexpr uint32_t MAX_WORKER_COUNT = 64;

/// Minimum number of worker threads.
constexpr uint32_t MIN_WORKER_COUNT = 1;

/// Default maximum number of tasks per queue before blocking submission.
constexpr uint32_t DEFAULT_MAX_QUEUE_DEPTH = 4096;

/// Maximum number of steal attempts before yielding.
constexpr uint32_t MAX_STEAL_ATTEMPTS = 3;

/// Default priority level for tasks.
constexpr uint32_t DEFAULT_PRIORITY = 5;

// ---------------------------------------------------------------------------
// TASK TYPES
// ---------------------------------------------------------------------------

/// Task function type.
using TaskFunction = std::function<void()>;

/// Task priority (0 = highest, 10 = lowest).
using TaskPriority = uint32_t;

/// Task identifier type.
using TaskId = uint64_t;

/// Task status.
enum class TaskStatus : uint8_t {
    Pending = 0,
    Running = 1,
    Completed = 2,
    Cancelled = 3,
    Failed = 4,
};

/// Task handle for tracking execution.
struct TaskHandle {
    TaskId id;
    std::atomic<TaskStatus> status;
    std::function<void()> on_complete;
};

// ---------------------------------------------------------------------------
// JOB SYSTEM
// ---------------------------------------------------------------------------

class JobSystem {
public:
    explicit JobSystem(uint32_t worker_count = DEFAULT_WORKER_COUNT,
                       uint32_t max_queue_depth = DEFAULT_MAX_QUEUE_DEPTH);
    ~JobSystem();

    // Non-copyable, non-movable
    JobSystem(const JobSystem&) = delete;
    JobSystem& operator=(const JobSystem&) = delete;

    /// Submit a task for execution.
    TaskId submit(TaskFunction task, TaskPriority priority = DEFAULT_PRIORITY);

    /// Submit a task with a completion callback.
    TaskId submit_with_callback(TaskFunction task,
                                std::function<void()> on_complete,
                                TaskPriority priority = DEFAULT_PRIORITY);

    /// Wait for a specific task to complete.
    bool wait_for_task(TaskId id, uint32_t timeout_ms = 0);

    /// Wait for all pending tasks to complete.
    void wait_for_all(uint32_t timeout_ms = 0);

    /// Cancel a pending task.
    bool cancel(TaskId id);

    /// Cancel all pending tasks.
    void cancel_all();

    /// Get the number of worker threads.
    uint32_t worker_count() const { return worker_count_; }

    /// Get the number of pending tasks.
    uint32_t pending_count() const;

    /// Get the number of running tasks.
    uint32_t running_count() const;

    /// Get the number of completed tasks.
    uint64_t completed_count() const { return completed_count_.load(); }

    /// Check if the job system is running.
    bool is_running() const { return running_.load(); }

    /// Pause task execution (running tasks continue, new tasks queue).
    void pause();

    /// Resume task execution.
    void resume();

private:
    /// Internal task structure.
    struct Task {
        TaskId id;
        TaskFunction function;
        TaskPriority priority;
        std::atomic<TaskStatus> status;
        std::function<void()> on_complete;
    };

    /// Per-worker queue structure.
    struct WorkerQueue {
        std::deque<std::unique_ptr<Task>> tasks;
        std::mutex mutex;
        std::condition_variable cv;
        uint32_t task_count = 0;
    };

    void worker_loop(uint32_t worker_id);
    std::unique_ptr<Task> try_steal(uint32_t worker_id);
    TaskId next_task_id();

    uint32_t worker_count_;
    uint32_t max_queue_depth_;
    std::atomic<bool> running_{false};
    std::atomic<bool> paused_{false};
    std::atomic<uint64_t> completed_count_{0};
    std::atomic<uint64_t> task_id_counter_{1};
    std::vector<std::thread> workers_;
    std::vector<std::unique_ptr<WorkerQueue>> queues_;
    std::mutex global_mutex_;
    std::condition_variable global_cv_;
};

// ---------------------------------------------------------------------------
// IMPLEMENTATION
// ---------------------------------------------------------------------------

JobSystem::JobSystem(uint32_t worker_count, uint32_t max_queue_depth)
    : max_queue_depth_(max_queue_depth)
{
    if (worker_count == 0) {
        worker_count = std::thread::hardware_concurrency();
        if (worker_count < MIN_WORKER_COUNT) {
            worker_count = MIN_WORKER_COUNT;
        }
        if (worker_count > MAX_WORKER_COUNT) {
            worker_count = MAX_WORKER_COUNT;
        }
    }
    worker_count_ = worker_count;

    // Create worker queues
    for (uint32_t i = 0; i < worker_count_; ++i) {
        queues_.push_back(std::make_unique<WorkerQueue>());
    }

    // Start worker threads
    running_.store(true);
    for (uint32_t i = 0; i < worker_count_; ++i) {
        workers_.emplace_back(&JobSystem::worker_loop, this, i);
    }
}

JobSystem::~JobSystem() {
    running_.store(false);
    for (auto& queue : queues_) {
        std::lock_guard<std::mutex> lock(queue->mutex);
        queue->cv.notify_all();
    }
    global_cv_.notify_all();
    for (auto& worker : workers_) {
        if (worker.joinable()) {
            worker.join();
        }
    }
}

TaskId JobSystem::submit(TaskFunction task, TaskPriority priority) {
    return submit_with_callback(std::move(task), nullptr, priority);
}

TaskId JobSystem::submit_with_callback(
    TaskFunction task,
    std::function<void()> on_complete,
    TaskPriority priority)
{
    if (!running_.load()) {
        return 0;
    }

    auto task_ptr = std::make_unique<Task>();
    task_ptr->id = next_task_id();
    task_ptr->function = std::move(task);
    task_ptr->priority = priority;
    task_ptr->status.store(TaskStatus::Pending);
    task_ptr->on_complete = std::move(on_complete);

    // Find the worker with the fewest tasks
    uint32_t target_worker = 0;
    uint32_t min_tasks = max_queue_depth_;

    for (uint32_t i = 0; i < worker_count_; ++i) {
        std::lock_guard<std::mutex> lock(queues_[i]->mutex);
        if (queues_[i]->task_count < min_tasks) {
            min_tasks = queues_[i]->task_count;
            target_worker = i;
        }
    }

    {
        std::lock_guard<std::mutex> lock(queues_[target_worker]->mutex);
        if (queues_[target_worker]->task_count >= max_queue_depth_) {
            // Queue is full, block until space is available
            // TODO: This blocking behavior can cause priority inversion if a
            // high-priority task is blocked by a full queue of low-priority tasks.
            // The fix would be to have a per-priority queue or to preemptively
            // steal low-priority tasks from the full queue.
            return 0;
        }
        queues_[target_worker]->tasks.push_back(std::move(task_ptr));
        queues_[target_worker]->task_count++;
    }

    queues_[target_worker]->cv.notify_one();
    return task_ptr->id;
}

bool JobSystem::wait_for_task(TaskId id, uint32_t timeout_ms) {
    auto start = std::chrono::steady_clock::now();
    while (running_.load()) {
        // Check all queues for task status
        for (auto& queue : queues_) {
            std::lock_guard<std::mutex> lock(queue->mutex);
            for (auto& task : queue->tasks) {
                if (task && task->id == id) {
                    if (task->status.load() == TaskStatus::Completed ||
                        task->status.load() == TaskStatus::Failed) {
                        return true;
                    }
                }
            }
        }

        if (timeout_ms > 0) {
            auto elapsed = std::chrono::steady_clock::now() - start;
            if (elapsed > std::chrono::milliseconds(timeout_ms)) {
                return false;
            }
        }

        std::this_thread::yield();
    }
    return false;
}

void JobSystem::wait_for_all(uint32_t timeout_ms) {
    auto start = std::chrono::steady_clock::now();
    while (running_.load()) {
        bool all_done = true;
        uint32_t total_pending = 0;

        for (auto& queue : queues_) {
            std::lock_guard<std::mutex> lock(queue->mutex);
            for (auto& task : queue->tasks) {
                if (task) {
                    auto status = task->status.load();
                    if (status == TaskStatus::Pending ||
                        status == TaskStatus::Running) {
                        all_done = false;
                        total_pending++;
                    }
                }
            }
        }

        if (all_done) break;

        if (timeout_ms > 0) {
            auto elapsed = std::chrono::steady_clock::now() - start;
            if (elapsed > std::chrono::milliseconds(timeout_ms)) {
                return;
            }
        }

        std::this_thread::yield();
    }
}

bool JobSystem::cancel(TaskId id) {
    for (auto& queue : queues_) {
        std::lock_guard<std::mutex> lock(queue->mutex);
        for (auto& task : queue->tasks) {
            if (task && task->id == id) {
                auto expected = TaskStatus::Pending;
                if (task->status.compare_exchange_strong(
                        expected, TaskStatus::Cancelled)) {
                    return true;
                }
                return false;
            }
        }
    }
    return false;
}

void JobSystem::cancel_all() {
    for (auto& queue : queues_) {
        std::lock_guard<std::mutex> lock(queue->mutex);
        for (auto& task : queue->tasks) {
            if (task) {
                auto expected = TaskStatus::Pending;
                task->status.compare_exchange_strong(
                    expected, TaskStatus::Cancelled);
            }
        }
    }
}

uint32_t JobSystem::pending_count() const {
    uint32_t count = 0;
    for (auto& queue : queues_) {
        std::lock_guard<std::mutex> lock(queue->mutex);
        for (auto& task : queue->tasks) {
            if (task && task->status.load() == TaskStatus::Pending) {
                count++;
            }
        }
    }
    return count;
}

uint32_t JobSystem::running_count() const {
    uint32_t count = 0;
    for (auto& queue : queues_) {
        std::lock_guard<std::mutex> lock(queue->mutex);
        for (auto& task : queue->tasks) {
            if (task && task->status.load() == TaskStatus::Running) {
                count++;
            }
        }
    }
    return count;
}

void JobSystem::pause() {
    paused_.store(true);
}

void JobSystem::resume() {
    paused_.store(false);
    for (auto& queue : queues_) {
        std::lock_guard<std::mutex> lock(queue->mutex);
        queue->cv.notify_all();
    }
}

void JobSystem::worker_loop(uint32_t worker_id) {
    while (running_.load()) {
        std::unique_ptr<Task> task;

        // Try to get a task from our own queue
        {
            std::unique_lock<std::mutex> lock(queues_[worker_id]->mutex);
            queues_[worker_id]->cv.wait_for(lock, std::chrono::milliseconds(100),
                [this, worker_id]() {
                    if (!running_.load()) return true;
                    if (paused_.load()) return false;
                    return !queues_[worker_id]->tasks.empty();
                });

            if (!running_.load()) return;

            if (!queues_[worker_id]->tasks.empty()) {
                task = std::move(queues_[worker_id]->tasks.front());
                queues_[worker_id]->tasks.pop_front();
                queues_[worker_id]->task_count--;
            }
        }

        // If no task, try to steal from other workers
        if (!task) {
            task = try_steal(worker_id);
        }

        // Execute task
        if (task) {
            task->status.store(TaskStatus::Running);

            try {
                task->function();
                task->status.store(TaskStatus::Completed);
            } catch (...) {
                task->status.store(TaskStatus::Failed);
            }

            completed_count_.fetch_add(1);

            if (task->on_complete) {
                try {
                    task->on_complete();
                } catch (...) {
                    // Ignore completion callback errors
                }
            }
        }
    }
}

std::unique_ptr<JobSystem::Task> JobSystem::try_steal(uint32_t worker_id) {
    for (uint32_t attempt = 0; attempt < MAX_STEAL_ATTEMPTS; ++attempt) {
        // Pick a random victim
        uint32_t victim = (worker_id + 1 + attempt) % worker_count_;
        if (victim == worker_id) continue;

        std::lock_guard<std::mutex> lock(queues_[victim]->mutex);
        if (!queues_[victim]->tasks.empty()) {
            // Steal from the back of the victim's queue (LIFO stealing)
            auto task = std::move(queues_[victim]->tasks.back());
            queues_[victim]->tasks.pop_back();
            queues_[victim]->task_count--;
            return task;
        }
    }
    return nullptr;
}

TaskId JobSystem::next_task_id() {
    return task_id_counter_.fetch_add(1);
}

} // namespace tot

#endif // TOT_JOB_SYSTEM_HPP
