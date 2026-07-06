# Vendored: eventpp

Snapshot of **eventpp**, a header-only C++ event/callback library.

- Upstream: <https://github.com/wqking/eventpp>
- Version: **v0.1.3** (2023-09-21)
- License: Apache-2.0 (see [`license`](license))

Vendored as the header subtree `include/eventpp` (header-only).

## Local patches

**`eventqueue.h` — `EventQueue::size()` added** (search for
`added for umacapture`). Upstream exposes only `emptyQueue()` (a bool), but
`uma::event_util`'s bounded queues need the actual pending-event count for their
backpressure check (`ready()` in `native/src/util/event_util.h`). The method
reads the live `queueList` under `queueListMutex` (which is `mutable`), so it is
a const query like `emptyQueue()`, race-free, and — because it reads ground truth
rather than a shadow counter — exception-safe across the runner's
throwing-listener path. **This patch must be re-applied whenever eventpp is
updated.**

## Updating

Replace the whole `include/eventpp` tree and `license` from the new tag, then
re-apply the `size()` patch above to `eventqueue.h` (insert it right after
`emptyQueue()`).
