#pragma once

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
    explicit QueuedConnectionImpl(QueueLimitMode queue_limit_mode)
        : queue_limit_mode(queue_limit_mode)
        , notifier(nullptr)
        , id(0) {}

    QueuedConnectionImpl(QueueLimitMode queue_limit_mode, const std::shared_ptr<SenderBase<int>> &notifier, int id)
        : queue_limit_mode(queue_limit_mode)
        , notifier(notifier)
        , id(id) {}

    ~QueuedConnectionImpl() override = default;

    void send(Args... args) override {
        if (!ready()) {
            switch (queue_limit_mode) {
                case Discard: return;
                case Block: waitUntilReady(); break;
                case NoLimit: break;
                default: throw std::logic_error("Unimplemented.");
            }
        }

        // TODO: This should be synchronized.
        connection.enqueue(0, args...);
        if (notifier != nullptr) {
            notifier->send(id);
        }
    }

    void listen(const std::function<void(Args...)> &method) override { connection.appendListener(0, method); }

    void waitFor(int milliseconds) const override { connection.waitFor(std::chrono::milliseconds(milliseconds)); }

    void processIf(const std::function<bool()> &predicate) override { connection.processIf(predicate); }

    void processOne() override {
        while (!connection.processOne()) {
        }
    }

private:
    [[nodiscard]] bool ready() const { return connection.size() < queue_limit_size; }

    void waitUntilReady() {
        while (!ready()) {
            waitFor(10);
        }
    }

    const QueueLimitMode queue_limit_mode;
    const size_t queue_limit_size = 3;

    eventpp::EventQueue<int, void(Args...)> connection;
    const std::shared_ptr<SenderBase<int>> notifier;
    const int id;
};

class EventRunnerThread : public thread_util::ThreadBase {
public:
    EventRunnerThread(
        const std::shared_ptr<EventProcessorInterface> &processor,
        const std::function<void()> &detach,
        const std::string &name)
        : processor(processor)
        , detach(detach)
        , name(name) {}

protected:
    void run() override {
        log_debug("start {}", name);

        while (isRunning()) {
            processor->waitFor(loopTimeoutMilliseconds);
            processor->processIf([&]() { return isRunning(); });
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
        QueueLimitMode queue_limit_mode, const std::function<void()> &finalizer, const std::string &name)
        : queue_limit_mode(queue_limit_mode)
        , notifier(std::make_shared<QueuedConnectionImpl<int>>(QueueLimitMode::NoLimit))
        , finalizer(finalizer)
        , name(name) {
        notifier->listen([this](const int &index) {
            assert_(isRunning());
            processors[index]->processOne();
        });
    }

    template<typename... Args>
    std::shared_ptr<ConnectionInterface<Args...>> makeConnection() {
        assert_(!isRunning());
        auto connection = std::make_shared<QueuedConnectionImpl<Args...>>(
            queue_limit_mode, notifier, static_cast<int>(processors.size()));
        processors.emplace_back(connection);
        return connection;
    }

    void start() override {
        vlog_debug(isRunning());
        assert_(!isRunning());
        runner = std::make_shared<EventRunnerThread>(notifier, finalizer, name);
        runner->start();
    }

    void join() override {
        vlog_debug(isRunning());
        if (runner == nullptr) {
            return;
        }
        runner->join();
        runner = nullptr;
    }

    [[nodiscard]] bool isRunning() const override { return runner != nullptr; }

private:
    const std::shared_ptr<QueuedConnectionImpl<int>> notifier;
    const std::function<void(void)> finalizer;
    const std::string name;
    const QueueLimitMode queue_limit_mode;

    std::vector<std::shared_ptr<EventProcessorInterface>> processors;
    std::shared_ptr<EventRunnerThread> runner;
};

class EventRunnerControllerImpl : public EventRunnerInterface {
public:
    ~EventRunnerControllerImpl() override { assert_(!is_running); }

    void add(const std::shared_ptr<EventRunnerInterface> &runner) {
        assert_(!isRunning());
        runners.emplace_back(runner);
    }

    void start() override {
        vlog_debug(isRunning());
        assert_(!isRunning());
        for (const auto &r : runners) {
            r->start();
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
    bool is_running = false;
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
[[maybe_unused]] inline QueuedConnection<Args...> makeQueuedConnection(QueueLimitMode queue_limit_mode) {
    return std::make_shared<event_util_impl::QueuedConnectionImpl<Args...>>(queue_limit_mode);
}

using EventProcessor = std::shared_ptr<event_util_impl::EventProcessorInterface>;
using EventRunner = std::shared_ptr<event_util_impl::EventRunnerInterface>;
using SingleThreadMultiEventRunner = std::shared_ptr<event_util_impl::SingleThreadMultiEventRunnerImpl>;
using EventRunnerController = std::shared_ptr<event_util_impl::EventRunnerControllerImpl>;

inline SingleThreadMultiEventRunner makeSingleThreadRunner(
    QueueLimitMode queue_limit_mode, const std::function<void()> &finalizer, const std::string &name) {
    return std::make_shared<event_util_impl::SingleThreadMultiEventRunnerImpl>(queue_limit_mode, finalizer, name);
}

inline EventRunnerController makeRunnerController() {
    return std::make_shared<event_util_impl::EventRunnerControllerImpl>();
}

}  // namespace uma::event_util
