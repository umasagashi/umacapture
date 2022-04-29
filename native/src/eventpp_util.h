#ifndef NATIVE_EVENTPP_UTIL_H
#define NATIVE_EVENTPP_UTIL_H

#include <utility>

#include "eventpp/eventdispatcher.h"
#include "eventpp/eventqueue.h"

#include "thread_util.h"

namespace {

template<typename T>
class SenderImpl {
public:
    virtual ~SenderImpl() = default;

    virtual void send(T value) = 0;
};

template<typename T>
class ListenerImpl {
public:
    virtual ~ListenerImpl() = default;

    virtual void listen(const std::function<void(T)> &method) = 0;
};

class EventProcessorImpl {
public:
    virtual ~EventProcessorImpl() = default;

    virtual void waitFor(int milliseconds) const = 0;

    virtual bool process() = 0;
};

template<typename T>
class DirectConnectionImpl : public SenderImpl<T>, public ListenerImpl<T> {
public:
    ~DirectConnectionImpl() override = default;

    void send(T value) override { connection.dispatch(0, value); }

    void listen(const std::function<void(T)> &method) override { connection.appendListener(0, method); }

private:
    eventpp::EventDispatcher<int, void(T)> connection;
};

template<typename T>
class QueuedConnectionImpl : public SenderImpl<T>, public ListenerImpl<T>, public EventProcessorImpl {
public:
    ~QueuedConnectionImpl() override = default;

    void send(T value) override { connection.enqueue(0, value); }

    void listen(const std::function<void(T)> &method) override { connection.appendListener(0, method); }

    void waitFor(int milliseconds) const override { connection.waitFor(std::chrono::milliseconds(milliseconds)); }

    bool process() override { return connection.process(); }

private:
    eventpp::EventQueue<int, void(T)> connection;
};

class EventLoopRunnerImpl : public threading::ThreadBase {
public:
    EventLoopRunnerImpl(std::shared_ptr<EventProcessorImpl> processor, std::function<void()> finalizer)
            : processor(std::move(processor)), finalizer(std::move(finalizer)) {}

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

template<typename T>
using Sender = std::shared_ptr<::SenderImpl<T>>;

template<typename T>
using Listener = std::shared_ptr<::ListenerImpl<T>>;

template<typename T>
using DirectConnection = std::shared_ptr<::DirectConnectionImpl<T>>;

template<typename T>
using QueuedConnection = std::shared_ptr<::QueuedConnectionImpl<T>>;

using EventLoopRunner = std::shared_ptr<::EventLoopRunnerImpl>;

template<typename SharedPointerType>
inline SharedPointerType make_connection() {
    return std::make_shared<typename SharedPointerType::element_type>();
}

inline std::shared_ptr<::EventLoopRunnerImpl> make_runner(const std::shared_ptr<EventProcessorImpl> &processor,
                                                          const std::function<void()> &finalizer = nullptr) {
    return std::make_shared<EventLoopRunnerImpl>(processor, finalizer);
}

}  // namespace connection

#endif  //NATIVE_EVENTPP_UTIL_H
