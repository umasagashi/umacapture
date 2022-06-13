#pragma once

namespace uma::distributor {

class SceneContext {
public:
    virtual ~SceneContext() = default;
    virtual void update(const Frame &input) = 0;
    [[nodiscard]] virtual bool met() const = 0;
};

}  // namespace uma::distributor
