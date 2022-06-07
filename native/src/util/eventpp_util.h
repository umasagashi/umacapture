#pragma once

#include <utility>

#include <eventpp/eventdispatcher.h>
#include <eventpp/eventqueue.h>

#include "util/thread_util.h"

namespace {

template<typename... Args>
class SenderInterface {
public:
    virtual ~SenderInterface() = default;

    virtual void send(Args... args) = 0;
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

    virtual bool process() = 0;
    virtual bool processOne() = 0;
};

template<typename... Args>
class ConnectionInterface : public SenderInterface<Args...>, public ListenerInterface<Args...> {};

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
    QueuedConnectionImpl()
        : notifier(nullptr)
        , id(0) {}

    QueuedConnectionImpl(const std::shared_ptr<SenderInterface<int>> &notifier, int id)
        : notifier(notifier)
        , id(id) {}

    ~QueuedConnectionImpl() override = default;

    void send(Args... args) override {
        // TODO: This should be synchronized.
        connection.enqueue(0, args...);
        if (notifier != nullptr) {
            notifier->send(id);
        }
    }

    void listen(const std::function<void(Args...)> &method) override { connection.appendListener(0, method); }

    void waitFor(int milliseconds) const override { connection.waitFor(std::chrono::milliseconds(milliseconds)); }

    bool process() override { return connection.process(); }
    bool processOne() override { return connection.processOne(); }

private:
    eventpp::EventQueue<int, void(Args...)> connection;
    const std::shared_ptr<SenderInterface<int>> notifier;
    const int id;
};

class QueuedConnectionManagerImpl {
public:
    QueuedConnectionManagerImpl()
        : notifier(std::make_shared<QueuedConnectionImpl<int>>()) {
        notifier->listen([this](int index) {
            auto p = processors[index];
            while (!p->processOne()) {
            }
        });
    }

    template<typename... Args>
    std::shared_ptr<ConnectionInterface<Args...>> makeConnection() {
        auto connection =
            std::make_shared<QueuedConnectionImpl<Args...>>(notifier, static_cast<int>(processors.size()));
        processors.push_back(connection);
        return connection;
    }

    [[nodiscard]] std::shared_ptr<EventProcessorInterface> processor() const { return notifier; }

private:
    const std::shared_ptr<QueuedConnectionImpl<int>> notifier;
    std::vector<std::shared_ptr<EventProcessorInterface>> processors;
};

class EventLoopRunnerImpl : public threading::ThreadBase {
public:
    EventLoopRunnerImpl(
        const std::shared_ptr<EventProcessorInterface> &processor, const std::function<void()> &finalizer)
        : processor(processor)
        , finalizer(finalizer) {}

protected:
    void run() override {
        std::cout << __FUNCTION__ << " started" << std::endl;
        while (isRunning()) {
            processor->waitFor(loopTimeoutMilliseconds);
            processor->process();
        }
        if (finalizer) {
            finalizer();
        }
        std::cout << __FUNCTION__ << " finished" << std::endl;
    }

private:
    const std::shared_ptr<EventProcessorInterface> processor;
    const std::function<void(void)> finalizer;
    const int loopTimeoutMilliseconds = 8;
};

}  // namespace

namespace connection {

template<typename... Args>
using Sender = std::shared_ptr<::SenderInterface<Args...>>;

template<typename... Args>
using Listener = std::shared_ptr<::ListenerInterface<Args...>>;

template<typename... Args>
using Connection = std::shared_ptr<::ConnectionInterface<Args...>>;

template<typename... Args>
using DirectConnection = std::shared_ptr<::DirectConnectionImpl<Args...>>;

template<typename... Args>
using QueuedConnection = std::shared_ptr<::QueuedConnectionImpl<Args...>>;

using EventLoopRunner = std::shared_ptr<::EventLoopRunnerImpl>;

using QueuedConnectionManager = std::shared_ptr<::QueuedConnectionManagerImpl>;

template<typename SharedPointerType>
inline SharedPointerType makeConnection() {
    return std::make_shared<typename SharedPointerType::element_type>();
}

inline QueuedConnectionManager makeConnectionManager() {
    return std::make_shared<QueuedConnectionManagerImpl>();
}

inline EventLoopRunner
makeRunner(const std::shared_ptr<EventProcessorInterface> &processor, const std::function<void()> &finalizer) {
    return std::make_shared<EventLoopRunnerImpl>(processor, finalizer);
}

}  // namespace connection
