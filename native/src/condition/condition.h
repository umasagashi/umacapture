#pragma once

#include <string>

#include "util/json_util.h"

namespace uma::condition {

template<typename InputType>
class Condition {
public:
    using input_type = InputType;

    virtual ~Condition() = default;

    virtual void update(const InputType &input) = 0;

    [[nodiscard]] virtual bool met() const = 0;

    [[nodiscard]] virtual const Condition<InputType> *findByTag(const std::string &tag) const = 0;

    [[maybe_unused]] [[nodiscard]] virtual std::string typeName() const = 0;

    // static Condition<InputType> *fromJson(const json_util::Json &j);
    [[nodiscard]] virtual json_util::Json toJson() const = 0;
};

}  // namespace uma::condition
