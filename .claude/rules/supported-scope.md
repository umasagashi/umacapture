# Supported scope

What the product promises, so that a finding's reachability can be rated. The rating rule itself lives
outside the repository (the user-level rule on proportionate defence); this file only states the facts
that rule consults. "Normal" below means an input or operation the product promises to handle. Anything
listed as "not promised" is outside the supported scope, and behaviour there is not a defect unless it
destroys data the product does promise to keep.

## Platforms and clients

- **Windows desktop app**, x86-64, one instance per session (the single-instance mutex).
- **Web app**: one tab per origin (a page-lifetime Web Lock; a second tab waits and continues when the
  first closes). Requires WebAssembly SIMD, `SharedArrayBuffer` and cross-origin isolation; the worker
  refuses the session otherwise. Normal browsers are desktop Chromium-based browsers and Firefox.
  Android Chrome is normal for **video import only**. iOS is not promised (never measured). The embedded
  browser pane of desktop chat clients is not promised (it cannot nest workers).
  Accepted limits: without `navigator.locks` two tabs are not excluded and settings are last-write-wins;
  a tab of a build older than the single-tab lock is not excluded across an update.
- **Game clients**: the DMM and Steam Windows clients.
- **CLI** (`umacapture_cli`): a developer tool. Its user is the developer; its output and the golden
  suite are promises to that user, not to the app's users.

## Capture

- The four capture forms are all promised and none may regress: portrait window, landscape window,
  full screen, and web screen share.
- Frames narrower than 540 px are not promised; the upscale arm is a best-effort rescue, not a
  verification target.

## Video import

- H.264 in MP4 is promised. Other codecs and containers are refused with a stated reason, which is the
  promised behaviour for them. A clip whose every frame reports zero is unsupported.
- Sources: desktop browsers and Android Chrome on the web, and the Windows app.

## Records and the data directory

- The app is the only writer of the data directory. **External reads are normal**: add-on tasks hand
  record ids and paths to external programs by design. **External writes are not promised**, nor are
  synced folders (OneDrive and the like), other volumes, UNC paths, OS file locks, or one data directory
  shared between accounts.
- A record the app cannot decode is moved to quarantine, never deleted. That is the promised response to
  an unreadable or half-written record.
- **After a crash or power loss**: the record in flight may be lost; records already listed survive; a
  damaged record is quarantined. Nothing more is promised.
- **A write that fails because the disk is full or the browser storage quota (OPFS, IndexedDB) is exhausted**
  is not promised. Behaviour there is not a defect unless it destroys records already listed or the ratings and
  memos already saved for them.
- Records captured before the recognizer module's minimum date are unsupported for recognition: viewing,
  export, delete and merge are normal; re-recognition is a warned, long-press rescue and is not a
  verification target.
- Operations started from the UI may overlap (an export running while a delete is pressed, and so on);
  that is normal, and the promised response is to refuse while busy. A window a person cannot aim for is
  coincidental reachability, not normal.

## User-authored content

- Add-on tasks (external programs, webhooks) and script columns are user-authored. The runtime semantics
  the manuals describe, and the app staying responsive and showing the error, are normal. The correctness
  of the user's script or task, and the behaviour of a launched external program, are not promised.
