#pragma once

#include <utility>

#include <eventpp/eventdispatcher.h>
#include <eventpp/eventqueue.h>

#include "util/logger_util.h"
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

    virtual void processAll() = 0;
    virtual void processOne() = 0;
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

    void processAll() override { connection.process(); }

    void processOne() override {
        while (!connection.processOne()) {
        }
    }

private:
    eventpp::EventQueue<int, void(Args...)> connection;
    const std::shared_ptr<SenderInterface<int>> notifier;
    const int id;
};

class EventRunnerThread : public threading::ThreadBase {
public:
    EventRunnerThread(
        const std::shared_ptr<EventProcessorInterface> &processor,
        const std::function<void()> &finalizer,
        const std::string &name)
        : processor(processor)
        , finalizer(finalizer)
        , name(name) {
        std::cout << __FUNCTION__ << std::endl;
        std::cout << "finalizer: " << finalizer.target_type().name() << " " << bool(finalizer) << " "
                  << "finalizer: " << this->finalizer.target_type().name() << " " << bool(this->finalizer) << " "
                  << std::this_thread::get_id() << name << std::endl;
    }

protected:
    void run() override {
        log_debug("start {}", name);

        while (isRunning()) {
            processor->waitFor(loopTimeoutMilliseconds);
            processor->processAll();
        }

        if (finalizer) {
            finalizer();
        }

        log_debug("finished {}", name);
    }

private:
    const std::string name;
    const std::shared_ptr<EventProcessorInterface> processor;
    const std::function<void(void)> finalizer;
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
    ~SingleThreadMultiEventRunnerImpl() override { assert_(runner == nullptr); }

    SingleThreadMultiEventRunnerImpl(const std::function<void()> &finalizer, const std::string &name)
        : notifier(std::make_shared<QueuedConnectionImpl<int>>())
        , finalizer(finalizer)
        , name(name) {
        notifier->listen([this](int index) {
            assert_(isRunning());
            processors[index]->processOne();
        });
    }

    template<typename... Args>
    std::shared_ptr<ConnectionInterface<Args...>> makeConnection() {
        assert_(!isRunning());
        auto connection =
            std::make_shared<QueuedConnectionImpl<Args...>>(notifier, static_cast<int>(processors.size()));
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
        assert_(isRunning());
        runner->join();
        runner = nullptr;
    }

    [[nodiscard]] bool isRunning() const override { return runner != nullptr; }

private:
    const std::shared_ptr<QueuedConnectionImpl<int>> notifier;
    const std::function<void(void)> finalizer;
    const std::string name;

    std::vector<std::shared_ptr<EventProcessorInterface>> processors;
    std::shared_ptr<EventRunnerThread> runner;
};

class MultiThreadMultiEventRunnerImpl : public EventRunnerInterface {
public:
    ~MultiThreadMultiEventRunnerImpl() override { assert_(!is_running); }

    template<typename... Args>
    std::shared_ptr<ConnectionInterface<Args...>>
    makeConnection(const std::function<void()> &finalizer, const std::string &name) {
        assert_(!isRunning());
        auto connection = std::make_shared<QueuedConnectionImpl<Args...>>();
        runners.push_back(std::make_shared<EventRunnerThread>(connection, finalizer, name));
        return connection;
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
        assert_(isRunning());
        for (const auto &r : runners) {
            r->join();
        }
        is_running = false;
    }

    [[nodiscard]] bool isRunning() const override { return is_running; }

private:
    std::vector<std::unique_ptr<EventRunnerThread>> runners;
    bool is_running = false;
};

class EventRunnerController : public EventRunnerInterface {
public:
    ~EventRunnerController() override { assert_(!is_running); }

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
        assert_(isRunning());
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

}  // namespace

namespace connection {

template<typename... Args>
using Sender = std::shared_ptr<::SenderInterface<Args...>>;

template<typename... Args>
using Listener = std::shared_ptr<::ListenerInterface<Args...>>;

template<typename... Args>
using Connection = std::shared_ptr<::ConnectionInterface<Args...>>;

using EventRunner = std::shared_ptr<::EventRunnerInterface>;

//template<typename... Args>
//using DirectConnection = std::shared_ptr<::DirectConnectionImpl<Args...>>;

//template<typename... Args>
//using QueuedConnection = std::shared_ptr<::QueuedConnectionImpl<Args...>>;

//template<typename SharedPointerType>
//inline SharedPointerType makeConnection() {
//    return std::make_shared<typename SharedPointerType::element_type>();
//}

template<typename... Args>
inline Connection<Args...> makeDirectConnection() {
    return std::make_shared<DirectConnectionImpl<Args...>>();
}

namespace event_runner {

using SingleThreadMultiEventRunner = std::shared_ptr<::SingleThreadMultiEventRunnerImpl>;
using MultiThreadMultiEventRunner = std::shared_ptr<::MultiThreadMultiEventRunnerImpl>;

inline SingleThreadMultiEventRunner
makeSingleThreadRunner(const std::function<void()> &finalizer, const std::string &name) {
    return std::make_shared<SingleThreadMultiEventRunnerImpl>(finalizer, name);
}

inline MultiThreadMultiEventRunner makeMultiThreadRunner() {
    return std::make_shared<MultiThreadMultiEventRunnerImpl>();
}

//inline EventRunner makeRunner(
//    const std::shared_ptr<EventProcessorInterface> &processor,
//    const std::function<void()> &finalizer,
//    const std::string &name) {
//    return std::make_shared<EventRunnerImpl>(processor, finalizer, name);
//}

}  // namespace event_runner

}  // namespace connection
