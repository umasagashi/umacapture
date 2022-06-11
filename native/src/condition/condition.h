#pragma once

#include <string>

#include "util/json_utils.h"

namespace condition {

template<typename InputType>
class Condition {
public:
    using input_type = InputType;

    virtual ~Condition() = default;

    virtual void update(const InputType &input) = 0;

    [[nodiscard]] virtual bool met() const = 0;

    [[nodiscard]] virtual const Condition<InputType> *findByTag(const std::string &tag) const = 0;

    [[nodiscard]] virtual std::string typeName() const = 0;

    // static Condition<InputType> *fromJson(const json_utils::Json &j);
    [[nodiscard]] virtual json_utils::Json toJson() const = 0;
};

}  // namespace condition
