#pragma once

#include <memory>
#include <vector>

#include "condition/condition.h"
#include "cv/frame.h"
#include "util/json_util.h"

namespace uma::condition::serializer {

using ConditionBase = std::shared_ptr<Condition<Frame>>;

template<typename Base>
class Builder {
public:
    template<typename Impl>
    static Builder<Base> create();

    [[nodiscard]] bool match(const std::string &type) const { return type == target_type; }

    [[nodiscard]] Base build(const json_util::Json &json) const { return func(json); }

    [[nodiscard]] const std::string &typeName() const { return target_type; }

private:
    [[maybe_unused]] Builder(const std::string &type, const std::function<Base(const json_util::Json &)> &func)
        : target_type(type)
        , func(func) {}

    const std::string target_type;
    const std::function<Base(const json_util::Json &)> func;
};

ConditionBase conditionFromJson(const json_util::Json &j);

std::vector<ConditionBase> conditionArrayFromJson(const json_util::Json &j);

json_util::Json conditionArrayToJson(const std::vector<ConditionBase> &conditions);

}  // namespace uma::condition::serializer
