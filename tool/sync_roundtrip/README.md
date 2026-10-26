# Sync round trip tools

Tools that let an agent operate both ends of a record-sync round trip against the staging server: the
Windows app on one side and the web app on the other. Each step of a round trip — list, rate, memo, sync,
archive, merge, export, a screenshot — is one invocation, so a round-trip script is a list of calls.

## Windows

`windows/app.py` operates the Windows app through the driver entry `test_driver/app.dart`;
`windows/relay.mjs` is the HTTPS proxy the app is launched behind.

### Prerequisites

- **A Profile build of the driver entry for the staging origin**, built in the current session (Release
  does not register the driver extension):

  ```sh
  .fvm/flutter_sdk/bin/flutter build windows --profile -t test_driver/app.dart \
    --dart-define=UMACAPTURE_SHARING_ORIGIN=https://umacapture-web-staging.umasagashi.workers.dev
  ```

- `uv` (the script carries its own dependencies) and `node` on `PATH` (for the relay).
- No `umacapture.exe` running: `launch` refuses to start beside another instance.
- Launching shows the app's window, and the window takes the foreground. Tell whoever shares the desktop
  before `launch`.

### What the driver entry adds

`test_driver/app.dart` runs the shipped `main()` unchanged and answers the driver's `request_data`:

| Message | Answer |
|---|---|
| `harness_state` | capture attempt, last capture event, active and archive ids, factor table loaded, merge candidates |
| `sync_state` | logged in, sync on, a round running, last synced, the counts shown, the halt, what the last round told |
| `pick:<json list>` / `save:<path>` / `cancel` | queues the answer of the next file dialog (no native dialog ever opens; an unqueued dialog is dismissed). A save writes the bytes to the path |
| `pointer:{"x","y","buttons","hold_ms"}` | one press inside the app (secondary click, long hold) without the OS cursor |
| `locate_cell:{"record","column","inner"}` | the on-screen rect of a record's grid cell (`column` is the column title, `#check` the row-check column) |

### Running it

Global options go **before** the operation: `--state-dir` (default `.notes/sync-roundtrip/windows`, where
the session, the app's log, the relay's log and the driver logs are kept) and `--shot <png>` (a screenshot
after the operation).

```sh
APP="uv run tool/sync_roundtrip/windows/app.py --state-dir .notes/sync-roundtrip/windows"
$APP prepare --from <data root> --root <new root> [--logged-out]   # a fresh copy; --logged-out drops the session
$APP launch --root <new root> [--relay pass|refuse|drop|none]      # starts the app and leaves it running
$APP --shot list.png list                                          # ... one operation per call ...
$APP stop                                                          # closes the app and the relay
```

Every call prints one JSON object. Exit status 0 means the effect was observed in the app's own state (or
on disk); 1 means it was not, and the object carries `error`. Records are named by `fans:<count>`, by id,
or by an id prefix of 8 or more characters (resolved from `record.json` under the data root).

| Operation | Call | Observed before it returns |
|---|---|---|
| list | `list` | opens the records page; active and archive ids with fan counts, merge candidates |
| a record's notes | `notes <record>` | every rating and memo value of the record, read from disk |
| rate | `rate <record> <0.5..5.0> [--column <title>]` | the value on disk |
| memo | `memo <record> <text> [--column <title>]` | the value on disk |
| archive | `archive <record> --images jpeg\|none` | the id moved to the archive (right-click menu → dialog → hold) |
| delete | `delete <record>` | the id gone from both stores (right-click menu → hold) |
| merge | `merge <a> <b> --keep <record>` | the newer id gone and the pair no longer a candidate (settings → review list → hold) |
| zip export | `export-zip <record>... --to <path>` | the zip written and its record ids |
| zip import | `import-zip <path>` | the toast the import ended with (success, or the refusal reason) |
| capture by video import | `video-import <clip> [--timeout s]` | a new active id |
| turn sync on | `sync-on [--form png\|jpeg\|none]` | sync on |
| sync now | `sync-now [--timeout s]` | the round ended (`sync_state`) |
| image form | `image-form png\|jpeg\|none` | the option tapped (the form is the server's; read it off the screenshot) |
| sync state and counts | `sync-state` | — |
| network | `relay pass\|refuse\|drop` | the relay's mode |
| screenshot | `screenshot <png>` | — |
| recovery | `dismiss` | closes a dialog an operation that failed half way left open |
| anything else | `tap --text\|--key\|--tooltip <v>`, `reveal --text\|--key\|--tooltip <v>` (scroll into view, no press), `press <x> <y> [--button 2] [--hold-ms n]` | — |

The relay: `pass` tunnels the app's HTTPS to the requested host, `refuse` resets every connection (the
network is down), `drop` holds every new connection unanswered (packets are lost). Switching closes the
tunnels already open. `launch --relay refuse` keeps a run entirely off the network.

### Known limits

- **Logging in is the user's.** The app opens Google's login in the default browser. The session is kept
  in the data root (`settings/record_shares.hive`), so one login survives relaunches of the same root.
  A copy of a logged-in root starts syncing on launch (the app runs a round at start); copy it with
  `--logged-out`, or launch it with `--relay refuse`, when it must not.
- **A failed operation can leave a dialog open**, which blocks the next call's navigation (the call times
  out on its first tap). Run `dismiss`, or look at a `screenshot` first.
- **A failed operation can leave a file-dialog answer queued.** The next operation that queues one refuses
  to run instead of letting the stale answer answer its dialog; stop and relaunch the app.
- **Only rows the grid has laid out can be addressed.** A record scrolled out of the grid is not found.
- **A rating cell that already holds a value is set through the rating dialog**; an empty one through a tap
  on its own stars. The two use the same position rule.
- The memo dialog does not open while the side preview panel is open (a click then only moves the focus).
- Adding a column (a rating or memo storage made on the other device, a fan-count column) has no operation;
  the column builder is driven with `tap` / `press`.

## Web

`web/roundtrip_web.mjs` operates the web app in a **headless** Chrome over the DevTools protocol. `start`
launches a background daemon (`web/daemon.mjs`) that owns the browser and one CDP session on its page; every
other call is one request to it. The daemon exists because what an operation leaves behind has to outlive
the call: offline emulation belongs to the CDP session, and the app's page (with semantics on) would
otherwise be reloaded by every call. `web/ops.mjs` holds the operations, `web/cdp.mjs` the protocol client.

### Prerequisites

- Google Chrome at `C:/Program Files/Google/Chrome/Application/chrome.exe` (`--chrome <exe>` on `start`
  otherwise) and Node 22 or later on `PATH` (global `WebSocket`). No npm packages.
- Windows: `start` looks for a Chrome that already holds the profile through PowerShell's
  `Get-CimInstance`, and `stop` falls back to `taskkill /T` on the browser it started.
- **The browser is always headless** (`--headless=new`) and always uses its own profile. On Windows
  `chrome.exe` opens a visible window for almost any other argument list, and a visible window takes the
  foreground from whoever is using the desktop.

### The profile and the one login

The profile is `.notes/sync-roundtrip/chrome-profile/` (gitignored; `--profile <dir>` on every call to use
another). It keeps the login, so it is not disposable. **Never open it in two browsers at once**: a second
Chrome started on a profile that is already open hands its arguments to the running one, so a headless
`start` against the user's open login window would open a tab in front of them. `start` refuses while any
`chrome.exe` has the profile on its command line.

Logging in is the user's, once, in a visible Chrome on the same profile — without a debugging port:

```bat
"C:\Program Files\Google\Chrome\Application\chrome.exe" --user-data-dir="C:\Projects\umacapture\.notes\sync-roundtrip\chrome-profile" --no-first-run https://umacapture-web-staging.umasagashi.workers.dev/
```

In that window: Settings → **Google でログイン**, finish the login in the tab it opens, return to the app's
tab, check that the account section reads 「Google アカウントでログインしています。」, then close **every**
window of that Chrome (the profile stays locked while any is open). Run `stop` first if the daemon is up.

Why the headless browser is still logged in afterwards: the app keeps its server session (token, expiry,
account id) in the `recordShares` storage box (`RecordShareSession` in
`lib/src/chara_detail/record_share_session.dart`, `_box => StorageBox(StorageBoxKey.recordShares)`). The
boxes are opened by `StorageBox.ensureOpened` in `lib/src/preference/storage_box.dart` through
`Hive.initFlutter`, and Hive keeps a box on the web in the origin's IndexedDB. IndexedDB lives in the
profile directory, which the headless browser opens as is. Google's own cookies are not needed after the
login: every later request carries the app's session token. `sync-status` reports `loggedIn`, which is how
the first run after the login confirms the carry-over.

### Running it

```sh
WEB="node tool/sync_roundtrip/web/roundtrip_web.mjs"
$WEB start [--url <app url>] [--idle-minutes 120]   # launches the daemon and a headless Chrome
$WEB open                                           # loads the app (staging by default) and turns semantics on
$WEB sync-status                                    # ... one operation per call ...
$WEB stop                                           # closes the browser and the daemon
```

Every call prints one JSON object (`{"ok": true, "result": …}` or `{"ok": false, "error": …}`) and exits 0 or
1. Calls are served one at a time in arrival order. Screenshots go to `.notes/sync-roundtrip/shots/<name>.png`
unless the name is a path. A daemon left idle for `--idle-minutes` closes its browser. Records are named by
their fan count (`700003` or `700,003`), so the table needs a ファン数 column.

| Sheet step | Call | Checked before it returns | Verified here |
|---|---|---|---|
| open the page | `open [url]` | the navigation rail is in the semantics tree | yes |
| leave the app (the sheet's "close the tab") | `leave-app` | the page is on `/privacy/` and the app's worker has detached | yes |
| turn sync on | `sync-on [--shot-name <n>]` | the turn-on dialog is shot with its counts, then closed by オンにする | no (needs login) |
| sync now | `sync-now [--timeout s]` | 「同期しています…」 is gone and 最終同期 changed, or a halt line appeared | no (needs login) |
| image form | `image-form png\|jpeg\|none` | — (returns `sync-status`) | no (needs login) |
| sync state and counts | `sync-status` | — : `loggedIn`, `syncOn`, `running`, `counts {restored, split_off, added}`, the sync lines | logged-out branch only |
| rate | `rate <fans> <0.5\|1.5\|…\|4.5> [--column <title>]` | the cell no longer reads 「クリックして評価」 | yes (unrated cells) |
| memo | `memo <fans> <text> [--column <title>]`, `memo <fans> --unchanged` | the cell's label is the new memo | yes |
| archive | `archive <fans> --images none\|jpeg` | the archive progress ended and the row left the list | yes |
| merge | `merge-list`, then `merge <index> left\|right [--values older\|newer]` | the merge dialog closed | yes (one pair) |
| capture by video import | `import-video <clip> [--timeout s]` | the cancel button is gone; returns the import lines | button found only |
| offline / back online | `offline`, `online` | a same-origin `fetch` fails / succeeds | yes |
| break a record (column 11) | `corrupt-record <id>` | — (leaves the app first; `open` shows the quarantine notice) | yes |
| drop the sync base (column 12) | `drop-sync-base` | — (leaves the app first) | not-found branch only |
| read the dismissed pairs (column 4) | `read-dismissed` | — | not-found branch only |
| screenshot | `shot <name>` | — | yes |

Primitives, for steps the table does not name (adding a column, a dialog an operation left open):
`nodes [--all] [--file <json>]`, `labels`, `find`/`tap`/`hold [--ms n]`/`rclick`/`wait [--gone]
[--timeout s]` with a selector (`<label>` exact, `--prefix`, `--contains`, `--regex`, `--role`, `--tag`,
`--nth`, `--scroll`), `tap-xy <x> <y> [--button right] [--ms n]`, `fill <selector> --text <t>`, `type <t>`,
`key <name>`, `scroll [dy]`, `tab <name>`, `status`, `net-check`, `eval <js> [--worker]`, and
`opfs-ls [path] [--depth n]`, `opfs-read`, `opfs-write <path> --text <t>|--file <f>`,
`opfs-rm <path> [--recursive]`, `opfs-push <local dir> <opfs dir>`. OPFS writes under `umacapture/` are
refused while the app is running in the page; run `leave-app` first.

### How presses are delivered

Elements are found by their label in Flutter's semantics tree, then pressed with CDP mouse events at their
centre. For the press, the semantics overlay is made transparent to the pointer, so the event reaches the
Flutter view as a pointer event, the way a mouse click does; nothing moves the OS cursor. `--semantic`
delivers the press to the semantics node instead (the engine's screen-reader tap). That path has no
position and no hold, and gestures that expose no tap action ignore it: the table's memo cell does not
open, and a star press there lands at the star's left edge.

### Known limits

- **Logging in, and anything after it, has not been run by this tool**: `sync-on`, `sync-now`,
  `image-form`, and `sync-status` on a logged-in page are written from the app's source and labels only.
  The first logged-in run should check each against a screenshot.
- **Offline is this tab only.** The emulation is set on the page's CDP session; the app's dedicated worker
  refuses the call itself, but its `fetch` fails while the page is offline (measured). It is not a machine
  without a network: other tabs, and anything outside this browser, stay online.
- **A rating is set only on an unrated cell, and only to a half value.** A synthetic press on star k gives
  k − 0.5 wherever it lands on the star. A rated cell opens the rating dialog, but a press on the dialog's
  stars closed it without saving, so `rate` refuses a rated cell.
- **The merge dialog names neither record by fan count**: its cards show evaluation points and capture
  time, and the candidate list shows evaluation points only. Pick the pair with `merge-list`, check the
  shot `merge` takes before it presses 統合する (returned as `shotBefore`), and choose the side by its
  capture time. 統合する is a hold-to-confirm button although its label does not say so.
- **Only rows the table has built can be addressed.** A row is found by scrolling the table; a banner that
  appears late (a quarantine notice) moves the table, and the row is taken only once it stops moving.
- **The video import's end is read from the screen**: the cancel button disappearing and the lines that
  mention the import. A run that imported nothing still returns ok; read `result` and the shot.
- **A failed operation can leave a menu or dialog open**, which blocks the next call. Look with `shot`,
  then close it with `tap` / `key Escape`.
- **An operation that hangs holds the queue.** Calls wait without a time limit; if the daemon stops
  answering, end the processes named in `<profile>.daemon.json` (`pid`, `chromePid`) and delete the file.
- **An Android Chrome is driven by attaching to it.** With USB debugging on, the phone's Chrome serves the
  protocol on its `chrome_devtools_remote` socket, which exists only while Chrome is running: start Chrome
  on the phone, run `adb forward tcp:9333 localabstract:chrome_devtools_remote`, then
  `start --profile <state dir> --attach http://127.0.0.1:9333`. Nothing is launched; the daemon takes the
  tab already on the app's origin (or opens one), and `stop` leaves the phone's browser running. Remove
  the forward afterwards (`adb forward --remove tcp:9333`). On a phone the app has a navigation drawer
  instead of the rail; the operations open it themselves. `import-video <clip> --via-page` sends the
  clip's bytes into the page, because the phone's Chrome cannot read a path of this machine, nor, without
  the media permission, a file pushed onto the phone. Chrome's own download prompt (a ZIP export) is
  outside the page and has to be answered on the phone.
