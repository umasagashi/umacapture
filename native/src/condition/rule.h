#pragma once

#include "util/json_util.h"
#include "util/misc.h"
#include "util/stds.h"

namespace uma::state {

struct Empty {};

struct TimestampState {
    uint64_t timestamp = 0;
};

}  // namespace uma::state

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
        : threshold(threshold) {}

    [[nodiscard]] bool met(const bool &parent, state::TimestampState &state) const override {
        if (parent) {
            if (state.timestamp == 0) {
                state.timestamp = chrono_util::timestamp();
            } else if (chrono_util::timestamp() - state.timestamp > threshold) {
                return true;
            }
        } else {
            state.timestamp = 0;
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

#pragma clang diagnostic pop
}  // namespace uma::rule
