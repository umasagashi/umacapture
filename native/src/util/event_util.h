#pragma once

#include <atomic>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <stdexcept>
#include <string>
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

    // Returns whether the event was accepted. `false` means it was DROPPED and no listener will ever see it
    // (only a full Discard-mode queue, or a Block-mode send released by abort() during teardown, can do that;
    // direct and NoLimit connections always return true). Producers that keep their own accounting of
    // in-flight events MUST consult this -- counting a dropped send leaves a drift nothing downstream can
    // ever settle. Every other caller may ignore it, which is why this is deliberately not [[nodiscard]].
    virtual bool send(Args... args) = 0;

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

    bool send(Args... args) override {
        connection.dispatch(0, args...);
        return true;  // A direct connection has no queue, so it can never drop.
    }

    void listen(const std::function<void(Args...)> &method) override { connection.appendListener(0, method); }

private:
    eventpp::EventDispatcher<int, void(Args...)> connection;
};

template<typename... Args>
class QueuedConnectionImpl : public ConnectionInterface<Args...>, public EventProcessorInterface {
public:
    explicit QueuedConnectionImpl(
        QueueLimitMode queue_limit_mode, size_t queue_limit_size = kDefaultQueueLimitSize, std::string name = {})
        : queue_limit_mode(queue_limit_mode)
        , queue_limit_size(queue_limit_size)
        , name(std::move(name))
        , notifier(nullptr)
        , id(0)
        , pending(nullptr) {}

    QueuedConnectionImpl(
        QueueLimitMode queue_limit_mode,
        size_t queue_limit_size,
        const std::shared_ptr<SenderBase<int>> &notifier,
        int id,
        std::atomic<int32_t> *pending,
        std::string name = {})
        : queue_limit_mode(queue_limit_mode)
        , queue_limit_size(queue_limit_size)
        , name(std::move(name))
        , notifier(notifier)
        , id(id)
        , pending(pending) {}

    ~QueuedConnectionImpl() override = default;

    bool send(Args... args) override {
        if (!ready()) {
            switch (queue_limit_mode) {
                case Discard: noteDropped(); return false;
                case Block:
                    waitUntilReady();
                    // waitUntilReady() also returns when abort() was requested during teardown; the queue is
                    // still full then, so drop this frame instead of enqueueing onto a stopped consumer.
                    if (!ready()) {
                        noteDropped();
                        return false;
                    }
                    break;
                case NoLimit: break;
                default: throw std::logic_error("Unimplemented.");
            }
        }

        // COUNTED BEFORE THE ENQUEUE, and that order is the whole point (see SingleThreadMultiEventRunnerImpl's
        // `pending_events`). An event that is already on the queue but not yet counted would make this runner
        // read as idle while it holds work, which is exactly the observation the drain barrier must never make.
        // Only an ACCEPTED send reaches here -- a Discard/Block refusal returned above -- so the paired
        // decrement, which runs after the listener, cannot go missing.
        if (pending != nullptr) {
            pending->fetch_add(1, std::memory_order_release);
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
        return true;
    }

    // Number of events this connection has dropped for a full queue since it was created. Zero for NoLimit
    // connections by construction. Exposed for tests and for the periodic drop report below.
    [[nodiscard]] uint64_t droppedCount() const { return dropped_count.load(std::memory_order_relaxed); }

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

    // Records one dropped event and reports the running total, at most once per kDropReportInterval per
    // connection. Dropping is BY DESIGN in Discard mode (live capture sheds load instead of stalling the
    // producer), which is exactly why it needs a trace: without one, "the queue mode is working" and "the
    // frame source died" look identical from the outside. That matters most on the browser build, where the
    // queue is the only load-shedding stage and nothing else observes it.
    // Only the total is atomic. The throttle state is touched from the producer thread alone, which is
    // sound because every Discard/Block connection has exactly one producer (see the enqueue note above);
    // NoLimit connections never reach here at all.
    void noteDropped() {
        const auto total = dropped_count.fetch_add(1, std::memory_order_relaxed) + 1;
        const auto now = std::chrono::steady_clock::now();
        if (last_drop_report != std::chrono::steady_clock::time_point{}
            && (now - last_drop_report) < kDropReportInterval) {
            return;
        }
        last_drop_report = now;
        log_debug("queued connection '{}' was full: {} event(s) dropped so far", name, total);
    }

    static constexpr std::chrono::seconds kDropReportInterval{5};

    const QueueLimitMode queue_limit_mode;
    const size_t queue_limit_size;
    // Identifies this connection in the drop report; "<runner>/<connection>" when built through a runner.
    const std::string name;

    eventpp::EventQueue<int, void(Args...)> connection;
    const std::shared_ptr<SenderBase<int>> notifier;
    const int id;
    // The owning runner's in-flight counter, or null for a connection nobody runs (the free
    // makeQueuedConnection, and a runner's own notifier queue -- counting the notifier would double every event).
    std::atomic<int32_t> *const pending;
    std::atomic<bool> aborted_ = false;
    std::atomic<uint64_t> dropped_count = 0;
    std::chrono::steady_clock::time_point last_drop_report = {};
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
            // BACKSTOP ONLY. A listener throwing (e.g. a recognizer failure) is caught around the single event
            // that threw, inside SingleThreadMultiEventRunnerImpl's notifier listener -- catching it here
            // instead would let the throw unwind out of eventpp's dispatch loop and silently discard the events
            // queued behind it (see that comment). What is left for this catch is a throw from anywhere else in
            // the dispatch machinery, which still must not escape the worker thread and terminate the process.
            try {
                processor->processIf([&]() { return isRunning(); });
            } catch (const std::exception &e) {
                // this->name, not the constructor's `name` parameter it shadows here (that reference does not
                // outlive the constructor).
                log_error("event runner '{}' listener threw: {}", this->name, e.what());
            } catch (...) {
                log_error("event runner '{}' listener threw an unknown exception", this->name);
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

    // Events this runner has ACCEPTED but not yet finished processing: the depth of every queue it owns, plus
    // the one event its worker is inside right now. Zero means the runner holds no work and, crucially, is not
    // about to hand any to a downstream stage.
    //
    // Deliberately pure rather than defaulted to 0. A stand-in that forgot to implement it would not fail to
    // compile, it would report "idle" forever -- and the barrier built on this (NativeApi::isPipelineDrained)
    // would then declare a working pipeline drained and join it mid-record. Every implementor must state its
    // answer.
    [[nodiscard]] virtual int32_t pendingEvents() const = 0;
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
            // DECREMENTED AFTER THE LISTENER HAS RUN, never before it. The listener is where this stage hands its
            // result to the NEXT one (the distributor forwards to the scraper, the scraper sends stitch_ready,
            // the stitcher sends recognize_ready), and that hand-off increments the downstream runner while this
            // one is still counted. So at no instant is a unit of work invisible to every runner at once, which
            // is what makes a zero total mean "nothing left" rather than "nothing right this microsecond".
            // In a scope guard because a listener may throw; a decrement skipped by a throw would strand this
            // runner as permanently busy.
            const PendingGuard guard{pending_events};
            // A THROWING LISTENER IS CONTAINED HERE, PER EVENT, and it has to be here rather than one level up
            // in EventRunnerThread. eventpp's EventQueue::processIf swaps the WHOLE queue into a local list and
            // dispatches it in a loop (vendor/eventpp/eventqueue.h): an exception that escapes this listener
            // unwinds out of that loop, and every entry still behind it in the local list is destroyed
            // UNDISPATCHED -- their listeners never run, and the `pending` increment each of them took at send
            // time is released by nobody. One bad record would then leave this runner permanently non-zero, so
            // no later drain could ever complete and every teardown would run to the watchdog. Catching around
            // the single event keeps the dispatch loop intact, so a failure costs exactly its own event.
            try {
                processors[index]->processOne();
            } catch (const std::exception &e) {
                // this->name, not the constructor's `name` parameter it shadows here (that reference does not
                // outlive the constructor).
                log_error("event runner '{}' listener threw: {}", this->name, e.what());
            } catch (...) {
                log_error("event runner '{}' listener threw an unknown exception", this->name);
            }
        });
    }

    // [connection_name] labels this connection in the queue's drop report (it is otherwise unused); it
    // defaults to the connection's index within this runner when the caller does not care.
    template<typename... Args>
    std::shared_ptr<ConnectionInterface<Args...>> makeConnection(const std::string &connection_name = {}) {
        assert_(!isRunning());
        // Enforced in release too, not just via the assert: the runner thread indexes `processors` by the
        // connection's stored index, so emplacing after start() could reallocate the vector under a concurrent
        // read (UAF). All connections must be created during pipeline construction, before start().
        if (isRunning()) {
            throw std::logic_error("SingleThreadMultiEventRunner::makeConnection called after start()");
        }
        const auto index = processors.size();
        auto connection = std::make_shared<QueuedConnectionImpl<Args...>>(
            queue_limit_mode,
            queue_limit_size,
            notifier,
            static_cast<int>(index),
            &pending_events,
            name + "/" + (connection_name.empty() ? std::to_string(index) : connection_name));
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

    [[nodiscard]] int32_t pendingEvents() const override { return pending_events.load(std::memory_order_acquire); }

private:
    // Incremented by every accepted send on a connection this runner owns, decremented once the worker has
    // finished the listener for it. NOT reset by join(): a runner that stops with events still queued really is
    // holding them, and the runners are rebuilt per pipeline anyway, so there is nothing to carry over.
    struct PendingGuard {
        std::atomic<int32_t> &counter;
        ~PendingGuard() { counter.fetch_sub(1, std::memory_order_release); }
    };
    std::atomic<int32_t> pending_events{0};

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

    // The TOTAL outstanding work of the runners in this controller, summed in the order they were added.
    //
    // WHAT MAKES A ZERO TOTAL TRUSTWORTHY IS THE HAND-OFF OVERLAP, NOT THE ORDER. Each runner decrements only
    // after its listener has returned, and that listener is where the stage hands its result to the next one
    // (SingleThreadMultiEventRunnerImpl's notifier listener), so the downstream increment lands while the
    // upstream count is still held. No unit of work is ever uncounted by every runner at once, which is why a
    // plain sum works at all and why this needs no "were they all zero at one instant" snapshot.
    //
    // WHAT THE ORDER BUYS, and it is exactly one thing: it closes the reverse-scan hole. Work only moves
    // downstream, so reading upstream first (add(distributor), add(scraper), add(stitcher), add(recognizer) --
    // see NativeApi::startPipeline) means a stage read early cannot be refilled from behind by a stage read
    // later. Summing recognizer-first would answer for a moment that has passed.
    //
    // WHAT THE ORDER DOES NOT BUY: any protection against a stage that is not in `runners` at all. The sum is
    // only ever as complete as the add() calls, and a pipeline whose producer feeds it through a runner some
    // other owner holds needs that runner asked too -- see core/pipeline_drain.h, where the CLI's own "recorder"
    // runner is a stage of the barrier for precisely this reason.
    [[nodiscard]] int32_t pendingEvents() const override {
        int32_t total = 0;
        for (const auto &r : runners) {
            total += r->pendingEvents();
        }
        return total;
    }

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
    QueueLimitMode queue_limit_mode, size_t queue_limit_size = kDefaultQueueLimitSize, const std::string &name = {}) {
    return std::make_shared<event_util_impl::QueuedConnectionImpl<Args...>>(queue_limit_mode, queue_limit_size, name);
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
