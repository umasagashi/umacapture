#pragma once

namespace uma {
class Frame;
}  // namespace uma

namespace uma::distributor {

class SceneContext {
public:
    virtual ~SceneContext() = default;
    virtual void update(const Frame &input) = 0;

    // No further frame is coming: an offline producer reached the end of its input (NativeApi::endOfInput) or
    // the live frame stream stalled (FrameStallWatchdog). A frame-timestamp scene-end debounce cannot advance
    // without frames, so this lets a context close an open scene on that signal. Default: no-op.
    virtual void onIdle() {}

    [[nodiscard]] virtual bool met() const = 0;
};

}  // namespace uma::distributor
