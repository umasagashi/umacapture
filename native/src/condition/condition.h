#ifndef NATIVE_CONDITION_H
#define NATIVE_CONDITION_H

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

    [[nodiscard]] virtual const Condition<InputType> *getByName(const std::string &name) const = 0;

    // static Condition<InputType> *fromJson(const json_utils::Json &j);
    [[nodiscard]] virtual json_utils::Json toJson() const = 0;
};

}  // namespace condition

#endif  //NATIVE_CONDITION_H
