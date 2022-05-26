#pragma once

#include <utility>

#include <eventpp/eventdispatcher.h>
#include <eventpp/eventqueue.h>

#include "util/thread_util.h"

namespace {

template<typename... Args>
class SenderImpl {
public:
    virtual ~SenderImpl() = default;

    virtual void send(Args... args) = 0;
};

template<typename... Args>
class ListenerImpl {
public:
    virtual ~ListenerImpl() = default;

    virtual void listen(const std::function<void(Args...)> &method) = 0;
};

class EventProcessorImpl {
public:
    virtual ~EventProcessorImpl() = default;

    virtual void waitFor(int milliseconds) const = 0;

    virtual bool process() = 0;
};

template<typename... Args>
class DirectConnectionImpl : public SenderImpl<Args...>, public ListenerImpl<Args...> {
public:
    ~DirectConnectionImpl() override = default;

    void send(Args... args) override { connection.dispatch(0, args...); }

    void listen(const std::function<void(Args...)> &method) override { connection.appendListener(0, method); }

private:
    eventpp::EventDispatcher<int, void(Args...)> connection;
};

template<typename... Args>
class QueuedConnectionImpl : public SenderImpl<Args...>, public ListenerImpl<Args...>, public EventProcessorImpl {
public:
    ~QueuedConnectionImpl() override = default;

    void send(Args... args) override { connection.enqueue(0, args...); }

    void listen(const std::function<void(Args...)> &method) override { connection.appendListener(0, method); }

    void waitFor(int milliseconds) const override { connection.waitFor(std::chrono::milliseconds(milliseconds)); }

    bool process() override { return connection.process(); }

private:
    eventpp::EventQueue<int, void(Args...)> connection;
};

class EventLoopRunnerImpl : public threading::ThreadBase {
public:
    EventLoopRunnerImpl(std::shared_ptr<EventProcessorImpl> processor, std::function<void()> finalizer)
        : processor(std::move(processor))
        , finalizer(std::move(finalizer)) {}

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
    std::shared_ptr<EventProcessorImpl> processor;
    std::function<void(void)> finalizer;
    const int loopTimeoutMilliseconds = 8;
};

}  // namespace

namespace connection {

template<typename... Args>
using Sender = std::shared_ptr<::SenderImpl<Args...>>;

template<typename... Args>
using Listener = std::shared_ptr<::ListenerImpl<Args...>>;

template<typename... Args>
using DirectConnection = std::shared_ptr<::DirectConnectionImpl<Args...>>;

template<typename... Args>
using QueuedConnection = std::shared_ptr<::QueuedConnectionImpl<Args...>>;

using EventLoopRunner = std::shared_ptr<::EventLoopRunnerImpl>;

template<typename SharedPointerType>
inline SharedPointerType make_connection() {
    return std::make_shared<typename SharedPointerType::element_type>();
}

inline std::shared_ptr<::EventLoopRunnerImpl>
make_runner(const std::shared_ptr<EventProcessorImpl> &processor, const std::function<void()> &finalizer = nullptr) {
    return std::make_shared<EventLoopRunnerImpl>(processor, finalizer);
}

}  // namespace connection
