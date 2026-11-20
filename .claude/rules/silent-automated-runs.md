# Automated runs make no sound

**Do not start a run that can make sound come out of the speakers.** This covers every check, harness,
test or app launch an agent or a script starts on its own. The machine is shared with a person who is
using it at the same time, and the app's capture chimes (`lib/src/core/sound_player.dart`) play at the
volume in the run's settings, so they can come out at full volume while that person is working.
Silence a run by that run's own means, listed below. Never by changing the OS volume or mixer, the
user's own data root and settings, or the user's own browser.

| run | sounds? | how it is silenced |
|---|---|---|
| Headless Chrome (`tool/web_e2e/`, or any Chrome or Chromium an agent starts) | yes: the web app plays its chimes, and headless Chrome still plays audio | start it with `--mute-audio` on a throwaway profile. `chrome_command` in `tool/web_e2e/web_import_e2e.py` already passes it |
| Firefox an agent starts (for example over Marionette) | yes, the same chimes | on a throwaway profile, write `user_pref("media.volume_scale", "0.0");` into its `user.js` before launch |
| The user's own browser (their default browser, the browser extension, the in-app browser pane) | yes | it cannot be silenced without changing the user's settings, so do not run a capture or an import in it |
| Windows app (`tool/live_capture_test/app_drive_run.py`, `flutter run -d windows`, `test_driver/app.dart`) | yes: a capture fires a cue, and an addon task in copied settings can play one as the app starts | launch `test_driver/app.dart`, never plain `lib/main.dart`, on a scratch data root (`UMACAPTURE_DATA_ROOT`). It overrides every sound's volume to 0 in the app's `ProviderScope`, so the app is silent from its first frame and no setting is written. Before the first capture, read `sound_volumes` from the driver's `request_data` `harness_state` and capture only if every volume is 0. `app_drive_run.py` does this itself and fails the run otherwise |
| `integration_test/` on Windows | no today: the one test starts no capture | a new test that starts a capture uses a scratch data root with every sound's volume set to 0 |
| `flutter test` (the VM) | no: no native plugin runs, so the audio player never reaches a device | a test that counts cues uses `NotificationLayer.debugPlaySound` |
| `dart test --platform chrome` (`@TestOn('browser')`) | no: no browser suite reaches the sound player | a new browser suite that does uses the same seam |
| `umacapture_cli`, `umacapture_mimic_player`, the `tool/test_web_*.mjs` scripts | no: none has an audio output path | none needed |

When a run you are adding can make sound and none of these means fits, stop and report rather than
run it.
