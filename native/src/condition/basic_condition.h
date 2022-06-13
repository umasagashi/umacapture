#pragma once

#include <memory>
#include <optional>
#include <vector>

#include <nameof/nameof.hpp>

#include "condition/condition.h"
#include "condition/serializer.h"
#include "util/stds.h"

namespace uma {

namespace condition {

template<typename Base, typename InputType, typename RuleType, typename StateType>
[[nodiscard]] std::string typeNameOf() {
    std::ostringstream stream;
    stream << nameof::nameof_short_type<Base>() << '<' << nameof::nameof_short_type<InputType>() << ','
           << nameof::nameof_short_type<RuleType>() << ',' << nameof::nameof_short_type<StateType>() << '>';
    return stream.str();
}

template<typename InputType, typename RuleType, typename StateType = typename RuleType::state_type>
class PlainCondition : public Condition<InputType> {
public:
    using rule_type = RuleType;
    using state_type = StateType;

    PlainCondition(const RuleType &rule, const std::optional<std::string> &name)
        : rule(rule)
        , condition_name(name) {}

    explicit PlainCondition(const RuleType &rule)
        : rule(rule) {}

    void update(const InputType &input) override { met_ = rule.met(input, state); }

    [[nodiscard]] bool met() const override { return met_; }

    [[nodiscard]] const Condition<InputType> *findByTag(const std::string &tag) const override {
        return (tag == condition_name) ? this : nullptr;
    }

    [[nodiscard]] std::string typeName() const { return typeNameOf<decltype(*this), InputType, RuleType, StateType>(); }

    static Condition<InputType> *fromJson(const json_utils::Json &json) {
        return new PlainCondition<InputType, RuleType, StateType>{
            json_utils::extended_from_json(json, "rule", json_utils::AsType<decltype(rule)>()),
            json_utils::extended_from_json(json, "name", json_utils::AsType<decltype(condition_name)>()),
        };
    }

    [[nodiscard]] json_utils::Json toJson() const {
        json_utils::Json json;
        json_utils::extended_to_json(json, "name", condition_name);
        json_utils::extended_to_json(json, "type", typeName());
        json_utils::extended_to_json(json, "rule", rule);
        return json;
    }

private:
    const std::optional<std::string> condition_name;
    const RuleType rule;

    StateType state;
    bool met_ = false;
};

template<typename InputType, typename RuleType, typename StateType = typename RuleType::state_type>
class NestedCondition : public Condition<InputType> {
public:
    //    using input_type = InputType;
    using rule_type = RuleType;
    using state_type = StateType;

    NestedCondition(
        const RuleType &rule,
        const std::shared_ptr<Condition<InputType>> &child,
        const std::optional<std::string> &name)
        : rule(rule)
        , child(child)
        , condition_name(name) {}

    NestedCondition(const RuleType &rule, const std::shared_ptr<Condition<InputType>> &child)
        : rule(rule)
        , child(child) {}

    void update(const InputType &input) override {
        child->update(input);
        met_ = rule.met(child->met(), state);
    }

    [[nodiscard]] bool met() const override { return met_; }

    [[nodiscard]] const Condition<InputType> *findByTag(const std::string &name) const override {
        return (name == condition_name) ? this : child->findByTag(name);
    }

    [[nodiscard]] std::string typeName() const { return typeNameOf<decltype(*this), InputType, RuleType, StateType>(); }

    static Condition<InputType> *fromJson(const json_utils::Json &json) {
        return new NestedCondition<InputType, RuleType, StateType>{
            json_utils::extended_from_json(json, "rule", json_utils::AsType<decltype(rule)>()),
            serializer::conditionFromJson(json.at("child")),
            json_utils::extended_from_json(json, "name", json_utils::AsType<decltype(condition_name)>()),
        };
    }

    [[nodiscard]] json_utils::Json toJson() const {
        json_utils::Json json;
        json_utils::extended_to_json(json, "name", condition_name);
        json_utils::extended_to_json(json, "type", typeName());
        json_utils::extended_to_json(json, "rule", rule);
        json_utils::extended_to_json(json, "child", child->toJson());
        return json;
    }

private:
    const std::optional<std::string> condition_name;
    const RuleType rule;
    const std::shared_ptr<Condition<InputType>> child;

    StateType state;
    bool met_ = false;
};

template<typename InputType, typename RuleType, typename StateType = typename RuleType::state_type>
class ParallelCondition : public Condition<InputType> {
public:
    using rule_type = RuleType;
    using state_type = StateType;

    ParallelCondition(
        const RuleType &rule,
        const std::vector<std::shared_ptr<Condition<InputType>>> &children,
        const std::optional<std::string> &name)
        : rule(rule)
        , children(children)
        , condition_name(name) {}

    ParallelCondition(const RuleType &rule, const std::vector<std::shared_ptr<Condition<InputType>>> &children)
        : rule(rule)
        , children(children)
        , condition_name(std::nullopt) {}

    void update(const InputType &input) override {
        stds::for_each(children, [&](const auto &item) { item->update(input); });
        met_ = rule.met(metDetail(), state);
    }

    [[nodiscard]] bool met() const override { return met_; }

    [[nodiscard]] std::vector<bool> metDetail() const {
        return stds::transformed<std::vector<bool>>(children, [](const auto &item) { return item->met(); });
    }

    [[nodiscard]] const Condition<InputType> *findByTag(const std::string &name) const override {
        if (name == condition_name) {
            return this;
        }
        return stds::find_transformed_if(
                   children,
                   [&](const auto &child) { return child->findByTag(name); },
                   [](const auto &ptr) { return ptr != nullptr; })
            .value_or(nullptr);
    }

    [[nodiscard]] std::string typeName() const { return typeNameOf<decltype(*this), InputType, RuleType, StateType>(); }

    static Condition<InputType> *fromJson(const json_utils::Json &json) {
        return new ParallelCondition<InputType, RuleType, StateType>{
            json_utils::extended_from_json(json, "rule", json_utils::AsType<decltype(rule)>()),
            serializer::conditionArrayFromJson(json.at("children")),
            json_utils::extended_from_json(json, "name", json_utils::AsType<decltype(condition_name)>()),
        };
    }

    [[nodiscard]] json_utils::Json toJson() const {
        json_utils::Json json;
        json_utils::extended_to_json(json, "name", condition_name);
        json_utils::extended_to_json(json, "type", typeName());
        json_utils::extended_to_json(json, "rule", rule);
        json_utils::extended_to_json(json, "children", serializer::conditionArrayToJson(children));
        return json;
    }

private:
    const std::optional<std::string> condition_name;
    const RuleType rule;
    const std::vector<std::shared_ptr<Condition<InputType>>> children;

    StateType state;
    bool met_ = false;
};

}  // namespace condition

}
