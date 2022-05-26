#pragma once

#include <memory>
#include <optional>
#include <vector>

#include "condition/condition.h"
#include "condition/serializer.h"
#include "util/stds.h"

namespace condition {

template<typename InputType, typename RuleType, typename StateType = typename RuleType::state_type>
class PlainCondition : public Condition<InputType> {
public:
    PlainCondition(const RuleType &rule, std::optional<std::string> name)
        : rule(rule)
        , name(std::move(name)) {}

    explicit PlainCondition(const RuleType &rule)
        : rule(rule) {}

    void update(const InputType &input) override { met_ = rule.met(input, state); }

    [[nodiscard]] bool met() const override { return met_; }

    [[nodiscard]] const Condition<InputType> *getByName(const std::string &name) const override {
        return (name == this->name) ? this : nullptr;
    }

    static Condition<InputType> *fromJson(const json_utils::Json &json) {
        return new PlainCondition<InputType, RuleType, StateType>{
            json_utils::extended_from_json(json, "rule", json_utils::AsType<decltype(rule)>()),
            json_utils::extended_from_json(json, "name", json_utils::AsType<decltype(name)>()),
        };
    }

    [[nodiscard]] json_utils::Json toJson() const {
        json_utils::Json json;
        json_utils::extended_to_json(json, "name", name);
        json_utils::extended_to_json(json, "type", type);
        json_utils::extended_to_json(json, "rule", rule);
        return json;
    }

private:
    const std::string type = typeid(*this).name();

    const std::optional<std::string> name;
    const RuleType rule;

    StateType state;
    bool met_ = false;
};

template<typename InputType, typename RuleType, typename StateType = typename RuleType::state_type>
class NestedCondition : public Condition<InputType> {
public:
    NestedCondition(const RuleType &rule, std::shared_ptr<Condition<InputType>> child, std::optional<std::string> name)
        : rule(rule)
        , child(std::move(child))
        , name(std::move(name)) {}

    NestedCondition(const RuleType &rule, std::shared_ptr<Condition<InputType>> child)
        : rule(rule)
        , child(std::move(child)) {}

    void update(const InputType &input) override {
        child->update(input);
        met_ = rule.met(child->met(), state);
    }

    [[nodiscard]] bool met() const override { return met_; }

    [[nodiscard]] const Condition<InputType> *getByName(const std::string &name) const override {
        return (name == this->name) ? this : child->getByName(name);
    }

    static Condition<InputType> *fromJson(const json_utils::Json &json) {
        return new NestedCondition<InputType, RuleType, StateType>{
            json_utils::extended_from_json(json, "rule", json_utils::AsType<decltype(rule)>()),
            serializer::conditionFromJson(json.at("child")),
            json_utils::extended_from_json(json, "name", json_utils::AsType<decltype(name)>()),
        };
    }

    [[nodiscard]] json_utils::Json toJson() const {
        json_utils::Json json;
        json_utils::extended_to_json(json, "name", name);
        json_utils::extended_to_json(json, "type", type);
        json_utils::extended_to_json(json, "rule", rule);
        json_utils::extended_to_json(json, "child", child->toJson());
        return json;
    }

private:
    const std::string type = typeid(*this).name();

    const std::optional<std::string> name;
    const RuleType rule;
    const std::shared_ptr<Condition<InputType>> child;

    StateType state;
    bool met_ = false;
};

template<typename InputType, typename RuleType, typename StateType = typename RuleType::state_type>
class ParallelCondition : public Condition<InputType> {
public:
    ParallelCondition(
        const RuleType &rule,
        std::vector<std::shared_ptr<Condition<InputType>>> children,
        std::optional<std::string> name)
        : rule(rule)
        , children(std::move(children))
        , name(std::move(name)) {}

    ParallelCondition(const RuleType &rule, std::vector<std::shared_ptr<Condition<InputType>>> children)
        : rule(rule)
        , children(std::move(children))
        , name(std::nullopt) {}

    void update(const InputType &input) override {
        stds::for_each(children, [&](const auto &item) { item->update(input); });
        met_ = rule.met(metDetail(), state);
    }

    [[nodiscard]] bool met() const override { return met_; }

    [[nodiscard]] std::vector<bool> metDetail() const {
        return stds::transformed(children, [](const auto &item) { return item->met(); });
    }

    [[nodiscard]] const Condition<InputType> *getByName(const std::string &target) const override {
        if (target == name) {
            return this;
        }
        for (const auto &item : children) {
            const auto &p = item->getByName(target);
            if (p != nullptr) {
                return p;
            }
        }
        return nullptr;
    }

    static Condition<InputType> *fromJson(const json_utils::Json &json) {
        return new ParallelCondition<InputType, RuleType, StateType>{
            json_utils::extended_from_json(json, "rule", json_utils::AsType<decltype(rule)>()),
            serializer::conditionArrayFromJson(json.at("children")),
            json_utils::extended_from_json(json, "name", json_utils::AsType<decltype(name)>()),
        };
    }

    [[nodiscard]] json_utils::Json toJson() const {
        json_utils::Json json;
        json_utils::extended_to_json(json, "name", name);
        json_utils::extended_to_json(json, "type", type);
        json_utils::extended_to_json(json, "rule", rule);
        json_utils::extended_to_json(json, "children", serializer::conditionArrayToJson(children));
        return json;
    }

private:
    const std::string type = typeid(*this).name();

    const std::optional<std::string> name;
    const RuleType rule;
    const std::vector<std::shared_ptr<Condition<InputType>>> children;

    StateType state;
    bool met_ = false;
};

}  // namespace condition
