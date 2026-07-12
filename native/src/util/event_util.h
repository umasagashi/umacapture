#pragma once

#include <atomic>
#include <cstddef>
#include <stdexcept>
#include <thread>
#include <utility>

#include <eventpp/eventdispatcher.h>
#include <eventpp/eventqueue.h>

#include "util/logger_util.h"
#include "util/thread_util.h"

namespace uma::event_util {

enum QueueLimitMode {
    NoLimit,
    Discard,
    Block,
};

// Default depth of a Discard/Block-mode connection's queue. In Discard mode the depth is a burst
// absorber, not a throughput fix: a consumer that is slow for a few events keeps them queued instead
// of dropping, but a consumer that is slower than the producer on average eventually drops no matter
// the depth. Deeper queues trade memory (queued args stay alive) and worst-case staleness
// (depth x production interval) for burst tolerance; pass a per-connection size where that trade
// matters (see the frame-path runners in native_api.cpp).
inline constexpr size_t kDefaultQueueLimitSize = 3;

namespace event_util_impl {

template<typename... Args>
class ConnectionInterface;

template<typename... Args>
struct DirectConnectionBuilder;

template<template<typename...> typename Builder, std::size_t first, typename... Args, std::size_t... indices>
Builder<std::tuple_element_t<first + indices, std::tuple<Args...>>...> _subset_dummy(std::index_sequence<indices...>);

template<template<typename...> typename Builder, std::size_t first, std::size_t n, typename... Args>
using SubsetArgs = decltype(_subset_dummy<Builder, first, Args...>(std::make_index_sequence<n>{}));

template<typename... Args>
class SenderBase {
public:
    virtual ~SenderBase() = default;

    virtual void send(Args... args) = 0;

    template<
        typename... LeftArgs,
        std::size_t first = sizeof...(LeftArgs),
        std::size_t n = sizeof...(Args) - sizeof...(LeftArgs)>
    inline auto bindLeft(LeftArgs... left_args) {
        const auto connection = SubsetArgs<DirectConnectionBuilder, first, n, Args...>().build();
        connection->listen([=](const auto &...right_args) { send(left_args..., right_args...); });
        return connection;
    }

    template<typename... RightArgs, std::size_t n = sizeof...(Args) - sizeof...(RightArgs)>
    [[maybe_unused]] inline auto bindRight(RightArgs... right_args) {
        const auto connection = SubsetArgs<DirectConnectionBuilder, 0, n, Args...>().build();
        connection->listen([=](const auto &...left_args) { send(left_args..., right_args...); });
        return connection;
    }
};

template<typename... Args>
class ListenerInterface {
public:
    virtual ~ListenerInterface() = default;

    virtual void listen(const std::function<void(Args...)> &method) = 0;
};

class EventProcessorInterface {
public:
    virtual ~EventProcessorInterface() = default;

    virtual void waitFor(int milliseconds) const = 0;

    virtual void processIf(const std::function<bool()> &predicate) = 0;
    virtual void processOne() = 0;

    // Wake any producer blocked in a Block-mode send() so teardown cannot deadlock on a full queue whose
    // consumer has already stopped draining. One-way for the connection's lifetime; connections are recreated
    // per pipeline session, so the flag starts clear each time. No-op for connections that never block.
    virtual void abort() {}
};

template<typename... Args>
class ConnectionInterface : public SenderBase<Args...>, public ListenerInterface<Args...> {};

template<typename... Args>
class DirectConnectionImpl : public ConnectionInterface<Args...> {
public:
    ~DirectConnectionImpl() override = default;

    void send(Args... args) override { connection.dispatch(0, args...); }

    void listen(const std::function<void(Args...)> &method) override { connection.appendListener(0, method); }

private:
    eventpp::EventDispatcher<int, void(Args...)> connection;
};

template<typename... Args>
class QueuedConnectionImpl : public ConnectionInterface<Args...>, public EventProcessorInterface {
public:
    explicit QueuedConnectionImpl(QueueLimitMode queue_limit_mode, size_t queue_limit_size = kDefaultQueueLimitSize)
        : queue_limit_mode(queue_limit_mode)
        , queue_limit_size(queue_limit_size)
        , notifier(nullptr)
        , id(0) {}

    QueuedConnectionImpl(
        QueueLimitMode queue_limit_mode,
        size_t queue_limit_size,
        const std::shared_ptr<SenderBase<int>> &notifier,
        int id)
        : queue_limit_mode(queue_limit_mode)
        , queue_limit_size(queue_limit_size)
        , notifier(notifier)
        , id(id) {}

    ~QueuedConnectionImpl() override = default;

    void send(Args... args) override {
        if (!ready()) {
            switch (queue_limit_mode) {
                case Discard: return;
                case Block:
                    waitUntilReady();
                    // waitUntilReady() also returns when abort() was requested during teardown; the queue is
                    // still full then, so drop this frame instead of enqueueing onto a stopped consumer.
                    if (!ready()) {
                        return;
                    }
                    break;
                case NoLimit: break;
                default: throw std::logic_error("Unimplemented.");
            }
        }

        // eventpp's EventQueue is internally synchronized, so enqueue() and the notifier's own enqueue are
        // each thread-safe on their own. The check-then-act above (ready() -> enqueue) is only consulted for
        // Discard/Block connections, and those are driven by a single producer per connection in practice
        // (on_frame_captured from the recorder thread, the scraper connections from the distributor thread),
        // so the stale-size window never races. NoLimit connections skip the size check entirely.
        connection.enqueue(0, args...);
        if (notifier != nullptr) {
            notifier->send(id);
        }
    }

    void listen(const std::function<void(Args...)> &method) override { connection.appendListener(0, method); }

    void waitFor(int milliseconds) const override { connection.waitFor(std::chrono::milliseconds(milliseconds)); }

    void processIf(const std::function<bool()> &predicate) override { connection.processIf(predicate); }

    void processOne() override {
        // Normally the notifier fires processOne() right after an enqueue, so the first attempt succeeds. Yield
        // on the empty-queue path (e.g. a spurious notify) so this cannot become a tight CPU spin.
        while (!connection.processOne()) {
            std::this_thread::yield();
        }
    }

    void abort() override { aborted_ = true; }

private:
    [[nodiscard]] bool ready() const { return connection.size() < queue_limit_size; }

    void waitUntilReady() {
        while (!ready() && !aborted_.load()) {
            waitFor(10);
        }
    }

    const QueueLimitMode queue_limit_mode;
    const size_t queue_limit_size;

    eventpp::EventQueue<int, void(Args...)> connection;
    const std::shared_ptr<SenderBase<int>> notifier;
    const int id;
    std::atomic<bool> aborted_ = false;
};

class EventRunnerThread : public thread_util::ThreadBase {
public:
    EventRunnerThread(
        const std::shared_ptr<EventProcessorInterface> &processor,
        const std::function<void()> &detach,
        const std::string &name)
        : name(name)
        , processor(processor)
        , detach(detach) {}

    ~EventRunnerThread() override { join(); }

protected:
    void run() override {
        log_debug("start {}", name);

        while (isRunning()) {
            processor->waitFor(loopTimeoutMilliseconds);
            // A listener throwing (e.g. a recognizer failure) must not escape this worker thread, or it
            // would terminate the process. Log the offending event and keep the runner alive.
            try {
                processor->processIf([&]() { return isRunning(); });
            } catch (const std::exception &e) {
                log_error("event runner '{}' listener threw: {}", name, e.what());
            } catch (...) {
                log_error("event runner '{}' listener threw an unknown exception", name);
            }
        }

        if (detach) {
            detach();
        }

        log_debug("finished {}", name);
    }

private:
    const std::string name;
    const std::shared_ptr<EventProcessorInterface> processor;
    const std::function<void(void)> detach;
    const int loopTimeoutMilliseconds = 8;
};

class EventRunnerInterface {
public:
    virtual ~EventRunnerInterface() = default;
    virtual void start() = 0;
    virtual void join() = 0;
    [[nodiscard]] virtual bool isRunning() const = 0;
};

class SingleThreadMultiEventRunnerImpl : public EventRunnerInterface {
public:
    SingleThreadMultiEventRunnerImpl(
        QueueLimitMode queue_limit_mode,
        const std::function<void()> &finalizer,
        const std::string &name,
        size_t queue_limit_size = kDefaultQueueLimitSize)
        : notifier(std::make_shared<QueuedConnectionImpl<int>>(QueueLimitMode::NoLimit))
        , finalizer(finalizer)
        , name(name)
        , queue_limit_mode(queue_limit_mode)
        , queue_limit_size(queue_limit_size) {
        notifier->listen([this](const int &index) {
            assert_(isRunning());
            processors[index]->processOne();
        });
    }

    template<typename... Args>
    std::shared_ptr<ConnectionInterface<Args...>> makeConnection() {
        assert_(!isRunning());
        // Enforced in release too, not just via the assert: the runner thread indexes `processors` by the
        // connection's stored index, so emplacing after start() could reallocate the vector under a concurrent
        // read (UAF). All connections must be created during pipeline construction, before start().
        if (isRunning()) {
            throw std::logic_error("SingleThreadMultiEventRunner::makeConnection called after start()");
        }
        auto connection = std::make_shared<QueuedConnectionImpl<Args...>>(
            queue_limit_mode, queue_limit_size, notifier, static_cast<int>(processors.size()));
        processors.emplace_back(connection);
        return connection;
    }

    void start() override {
        vlog_debug(isRunning());
        assert_(!isRunning());
        runner = std::make_shared<EventRunnerThread>(notifier, finalizer, name);
        // Publish running_ before starting the worker: the notifier listener reads isRunning() from the
        // worker thread, so it must observe true the moment the worker can run.
        running_ = true;
        // If thread creation throws (exhaustion/bad_alloc), roll running_ and runner back so this stays
        // consistent (running_ false, runner null) like ThreadBase::start -- otherwise isRunning() would
        // report true with no worker, and the controller could not tell a half-started runner apart.
        try {
            runner->start();
        } catch (...) {
            running_ = false;
            runner = nullptr;
            throw;
        }
    }

    void join() override {
        vlog_debug(isRunning());
        if (runner == nullptr) {
            return;
        }
        // Release any producer blocked in a Block-mode send() on one of these connections before joining the
        // worker: once the worker stops draining, a full queue would otherwise wedge the producer (and this
        // join) forever. Ordering-independent — each runner frees the producers waiting on its own connections.
        for (const auto &processor : processors) {
            processor->abort();
        }
        runner->join();
        running_ = false;
        runner = nullptr;
    }

    // running_ (atomic) instead of the raw shared_ptr: isRunning() is read on the worker thread (the
    // notifier listener's assert_) while the owner thread mutates `runner`, so reading the pointer here
    // would be a data race. The `runner == nullptr` guard in join() stays as an owner-thread-only read.
    [[nodiscard]] bool isRunning() const override { return running_; }

private:
    const std::shared_ptr<QueuedConnectionImpl<int>> notifier;
    const std::function<void(void)> finalizer;
    const std::string name;
    const QueueLimitMode queue_limit_mode;
    const size_t queue_limit_size;

    std::vector<std::shared_ptr<EventProcessorInterface>> processors;
    std::shared_ptr<EventRunnerThread> runner;
    std::atomic<bool> running_ = false;
};

class EventRunnerControllerImpl : public EventRunnerInterface {
public:
    ~EventRunnerControllerImpl() override { assert_(!is_running); }

    void add(const std::shared_ptr<EventRunnerInterface> &runner) {
        assert_(!isRunning());
        // Enforced in release too: start() iterates `runners`, so adding one after start() would race that
        // read. All runners must be added during pipeline construction, before start().
        if (isRunning()) {
            throw std::logic_error("EventRunnerController::add called after start()");
        }
        runners.emplace_back(runner);
    }

    void start() override {
        vlog_debug(isRunning());
        assert_(!isRunning());
        try {
            for (const auto &r : runners) {
                r->start();
            }
        } catch (...) {
            // Roll back a partial start: join every runner (idempotent -- a not-yet-started runner no-ops
            // on its null thread, an already-started one aborts its Block-mode producers and joins) so no
            // worker leaks before the exception propagates to teardown. is_running stays false, so the
            // controller's own join() correctly treats the pipeline as never started.
            for (const auto &r : runners) {
                r->join();
            }
            throw;
        }
        is_running = true;
    }

    void join() override {
        vlog_debug(isRunning());
        if (!isRunning()) {
            return;
        }
        for (const auto &r : runners) {
            r->join();
        }
        is_running = false;
    }

    [[nodiscard]] bool isRunning() const override { return is_running; }

private:
    std::vector<std::shared_ptr<EventRunnerInterface>> runners;
    // Read from Dart-facing threads (via NativeApi) while start()/join() write it on the owner thread,
    // so it must be atomic like ThreadBase's running flag; a plain bool here is a formal data race.
    std::atomic<bool> is_running = false;
};

template<typename... Args>
struct DirectConnectionBuilder {
    std::shared_ptr<ConnectionInterface<Args...>> build() const {
        return std::make_shared<event_util_impl::DirectConnectionImpl<Args...>>();
    }
};

}  // namespace event_util_impl

template<typename... Args>
using Sender = std::shared_ptr<event_util_impl::SenderBase<Args...>>;

template<typename... Args>
using Listener = std::shared_ptr<event_util_impl::ListenerInterface<Args...>>;

template<typename... Args>
using Connection = std::shared_ptr<event_util_impl::ConnectionInterface<Args...>>;

template<typename... Args>
using QueuedConnection = std::shared_ptr<event_util_impl::QueuedConnectionImpl<Args...>>;

template<typename... Args>
inline Connection<Args...> makeDirectConnection() {
    return std::make_shared<event_util_impl::DirectConnectionImpl<Args...>>();
}

template<typename... Args, typename Listener>
[[maybe_unused]] inline Connection<Args...> makeDirectConnection(Listener listener) {
    const auto connection = makeDirectConnection<Args...>();
    connection->listen(listener);
    return connection;
}

template<typename... Args>
[[maybe_unused]] inline QueuedConnection<Args...> makeQueuedConnection(
    QueueLimitMode queue_limit_mode, size_t queue_limit_size = kDefaultQueueLimitSize) {
    return std::make_shared<event_util_impl::QueuedConnectionImpl<Args...>>(queue_limit_mode, queue_limit_size);
}

using EventProcessor = std::shared_ptr<event_util_impl::EventProcessorInterface>;
using EventRunner = std::shared_ptr<event_util_impl::EventRunnerInterface>;
using SingleThreadMultiEventRunner = std::shared_ptr<event_util_impl::SingleThreadMultiEventRunnerImpl>;
using EventRunnerController = std::shared_ptr<event_util_impl::EventRunnerControllerImpl>;

inline SingleThreadMultiEventRunner makeSingleThreadRunner(
    QueueLimitMode queue_limit_mode,
    const std::function<void()> &finalizer,
    const std::string &name,
    size_t queue_limit_size = kDefaultQueueLimitSize) {
    return std::make_shared<event_util_impl::SingleThreadMultiEventRunnerImpl>(
        queue_limit_mode, finalizer, name, queue_limit_size);
}

inline EventRunnerController makeRunnerController() {
    return std::make_shared<event_util_impl::EventRunnerControllerImpl>();
}

}  // namespace uma::event_util
