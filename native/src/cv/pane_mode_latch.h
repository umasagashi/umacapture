#pragma once

#include <cstdint>
#include <mutex>
#include <optional>

#include "types/shape.h"

namespace uma {

// Thread-safe handoff of the accepted pane rectangle from the distributor thread to frame producers.
class PaneModeLatch {
public:
    using Generation = std::uint64_t;

    struct Snapshot {
        Size<int> captured_size;
        Generation generation;
        std::optional<Rect<int>> rect;

        [[nodiscard]] bool operator==(const Snapshot &other) const {
            return captured_size == other.captured_size && generation == other.generation && rect == other.rect;
        }
    };

    [[nodiscard]] Generation generation() const {
        const std::lock_guard<std::mutex> lock(mutex_);
        return generation_;
    }

    // Installs only when no release occurred since the caller took `expected_generation`. Validation and
    // installation share this mutex, so a scan that was already in flight when release() ran cannot relatch.
    [[nodiscard]] bool latch(
        const Rect<int> &rect, const Size<int> &captured_size, const Generation expected_generation) {
        const std::lock_guard<std::mutex> lock(mutex_);
        if (generation_ != expected_generation) {
            return false;
        }
        state_ = State{rect, captured_size};
        return true;
    }

    Generation release() {
        const std::lock_guard<std::mutex> lock(mutex_);
        ++generation_;
        state_.reset();
        return generation_;
    }

    [[nodiscard]] std::optional<Rect<int>> rectFor(const Size<int> &captured_size) const {
        const std::lock_guard<std::mutex> lock(mutex_);
        return snapshotForLocked(captured_size).rect;
    }

    // Captures the generation and the size-scoped rectangle under one lock. Producers must carry this exact
    // value across any asynchronous pixel copy, then call isCurrent immediately before handing the frame to
    // the pipeline. Comparing the optional rectangle as well as the generation detects a same-generation
    // replacement; comparing the generation detects release followed by a later relatch of an identical rect.
    [[nodiscard]] Snapshot snapshotFor(const Size<int> &captured_size) const {
        const std::lock_guard<std::mutex> lock(mutex_);
        return snapshotForLocked(captured_size);
    }

    [[nodiscard]] bool isCurrent(const Snapshot &snapshot) const {
        const std::lock_guard<std::mutex> lock(mutex_);
        return snapshotForLocked(snapshot.captured_size) == snapshot;
    }

private:
    struct State {
        Rect<int> rect;
        Size<int> captured_size;
    };

    [[nodiscard]] Snapshot snapshotForLocked(const Size<int> &captured_size) const {
        std::optional<Rect<int>> rect;
        if (state_.has_value() && state_->captured_size == captured_size) {
            rect = state_->rect;
        }
        return {captured_size, generation_, rect};
    }

    mutable std::mutex mutex_;
    Generation generation_ = 0;
    std::optional<State> state_;
};

}  // namespace uma
