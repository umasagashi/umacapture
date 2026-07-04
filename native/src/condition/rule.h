#pragma once

#include "util/json_util.h"
#include "util/misc.h"
#include "util/stds.h"

namespace uma::state {

struct Empty {};

struct TimestampState {
    uint64_t since = 0;  // Video time when the parent first became continuously true (debounce start).
    uint64_t now = 0;  // Current frame's video time, written by the owning condition each update.
    bool started = false;
};

// Records the current frame's video time into rule state that tracks time; a no-op for rules whose
// state does not. The owning condition calls this each update so time-based rules (rule::Stable)
// debounce on video time instead of the wall clock. In live capture the frame timestamp already
// tracks wall time, so live behavior is unchanged.
template<typename StateType>
inline void setFrameTimestamp(StateType &, uint64_t) {}

inline void setFrameTimestamp(TimestampState &state, uint64_t now) {
    state.now = now;
}

}  // namespace uma::state

namespace uma::input {

struct None {};

}  // namespace uma::input

namespace uma::rule {
#pragma clang diagnostic push
#pragma ide diagnostic ignored "readability-convert-member-functions-to-static"

template<typename InputType, typename StateType>
class Rule {
public:
    using input_type = InputType;
    using state_type = StateType;

    virtual ~Rule() = default;

    [[nodiscard]] virtual bool met(const InputType &input, StateType &state) const = 0;
};

class Stable : public Rule<bool, state::TimestampState> {
public:
    explicit Stable(int threshold)
        : threshold(threshold) {
        // Deserialized via EXTENDED_JSON_TYPE_NDC, which constructs through this ctor, so this also rejects
        // a negative threshold from JSON. A negative value would wrap in the static_cast<uint64_t> compare
        // below and never fire, silently preventing scene detection.
        if (threshold < 0) {
            throw std::invalid_argument("Stable threshold must be non-negative");
        }
    }

    [[nodiscard]] bool met(const bool &parent, state::TimestampState &state) const override {
        // Debounce in video time: state.now is the current frame's timestamp, written by the owning
        // condition each update (see state::setFrameTimestamp). This keeps detection deterministic and
        // independent of how fast frames are fed during offline video replay; in live capture the frame
        // timestamp tracks wall time, so behavior is unchanged. A `started` flag rather than a zero
        // sentinel is used because a video's first frame has timestamp 0.
        if (parent) {
            if (!state.started) {
                state.started = true;
                state.since = state.now;
            } else if (chrono_util::monotonicElapsed(state.now, state.since) > static_cast<uint64_t>(threshold)) {
                // monotonicElapsed restarts the window if the clock stepped backward (system_clock is not
                // monotonic in live capture), so a backward jump cannot wrap the subtraction and fire instantly.
                return true;
            }
        } else {
            state.started = false;
            state.since = 0;
        }
        return false;
    }

    EXTENDED_JSON_TYPE_NDC(Stable, threshold);

private:
    const int threshold;
};

class LogicalAnd : public Rule<std::vector<bool>, state::Empty> {
public:
    LogicalAnd() = default;

    [[nodiscard]] bool met(const std::vector<bool> &operands, state::Empty &) const override {
        return stds::all_of(operands);
    }

    EXTENDED_JSON_TYPE_NO_ARGS_DC(LogicalAnd);
};

class LogicalOr : public Rule<std::vector<bool>, state::Empty> {
public:
    LogicalOr() = default;

    [[nodiscard]] bool met(const std::vector<bool> &operands, state::Empty &) const override {
        return stds::any_of(operands);
    }

    EXTENDED_JSON_TYPE_NO_ARGS_DC(LogicalOr);
};

class LogicalNot : public Rule<bool, state::Empty> {
public:
    LogicalNot() = default;

    [[nodiscard]] bool met(const bool &operand, state::Empty &) const override {
        return !operand;
    }

    EXTENDED_JSON_TYPE_NO_ARGS_DC(LogicalNot);
};

class AlwaysTrue : public Rule<input::None, state::Empty> {
public:
    AlwaysTrue() = default;

    [[nodiscard]] bool met(const input::None &, state::Empty &) const override {
        return true;
    }

    EXTENDED_JSON_TYPE_NO_ARGS_DC(AlwaysTrue);
};

class AlwaysFalse : public Rule<input::None, state::Empty> {
public:
    AlwaysFalse() = default;

    [[nodiscard]] bool met(const input::None &, state::Empty &) const override {
        return false;
    }

    EXTENDED_JSON_TYPE_NO_ARGS_DC(AlwaysFalse);
};

#pragma clang diagnostic pop
}  // namespace uma::rule
