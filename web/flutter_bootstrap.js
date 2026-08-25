// Flutter bootstrap loader -- committed on purpose, overriding the one the build would generate.
//
// WHY IT IS IN THE REPO. `flutter build web` generates this file when it is absent, and the generated version
// passes `serviceWorkerSettings` whenever the build ran with the default `--pwa-strategy=offline-first`
// (flutter_tools: generateDefaultFlutterBootstrapScript, build_system/targets/web.dart). That registers
// Flutter's offline-first service worker at scope "/". Such a worker replays CACHED responses, which do not
// carry the COOP/COEP headers the coi-serviceworker shim injects, so `crossOriginIsolated` can flip to false on
// a later visit -- and the recognition core is built -pthread and needs SharedArrayBuffer, so the worker then
// refuses the session outright ("crossOriginIsolated is false", web/worker.js handleInit). It is a failure that
// only reproduces on a SECOND load, which is the worst kind to leave to a flag someone has to remember.
//
// Cross-origin isolation is provided solely by coi-serviceworker.js (registered from index.html). A second
// service worker at the same scope would fight it.
//
// WHAT THIS FILE GUARANTEES. flutter_tools prefers an existing web/flutter_bootstrap.js over its generated
// default and only substitutes the tokens below, so `_flutter.loader.load()` with no arguments is what ships --
// registering no service worker -- whatever `--pwa-strategy` the build was given and whoever ran it.
// tool/build_web.sh additionally pins `--pwa-strategy=none` so the now-unreferenced flutter_service_worker.js
// is not even emitted into build/web/.
//
// KEEP BOTH TOKENS BELOW: the first inlines flutter.js, the second defines `_flutter.buildConfig`, which
// `_flutter.loader.load()` throws without. Do not spell either token name in double braces anywhere else in
// this file (or in web/index.html): substitution is a plain text replacement over the whole file, comments
// included, so a token quoted in prose is expanded too -- which silently inlines a second copy of flutter.js.
// This file is hand-written and therefore listed in tool/web_deps.json's `first_party.files`, like every other
// committed file under web/.
{{flutter_js}}
{{flutter_build_config}}
_flutter.loader.load();
