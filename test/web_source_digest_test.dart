import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/web_deps_verify.dart';

/// A `build.sources` block over the fixture tree written by [writeSource].
Map<String, dynamic> sourcesBlock({String digest = "unset", List<String> exclude = const []}) {
  return {
    "digest": digest,
    "roots": ["native/src"],
    "extensions": [".cpp", ".h"],
    "exclude": exclude,
  };
}

/// An `origin: in-tree` manifest entry carrying [sources].
Map<String, dynamic> inTreeEntry(Map<String, dynamic>? sources) {
  return {
    "sha256": "unused",
    "bytes": 0,
    "origin": "in-tree",
    "build": {"sources": ?sources},
  };
}

/// Writes [content] to [relative] inside the current directory.
void writeSource(String relative, String content) {
  final file = File(relative);
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(content);
}

void main() {
  // Same contract as the rest of the verification code: every path is resolved against the
  // current directory, so each test runs in its own temp tree and never sees the real native/.
  late Directory previous;
  late Directory sandbox;

  setUp(() {
    previous = Directory.current;
    sandbox = Directory.systemTemp.createTempSync("web_source_digest_");
    Directory.current = sandbox;
    writeSource("native/src/core/api.cpp", "int api();\n");
    writeSource("native/src/core/api.h", "int api();\n");
    writeSource("native/src/cli.cpp", "int main();\n");
    writeSource("native/src/notes.md", "not a source\n");
  });

  tearDown(() {
    Directory.current = previous;
    sandbox.deleteSync(recursive: true);
  });

  group("buildSourceFiles", () {
    test("selects by extension, recursively, sorted", () {
      expect(buildSourceFiles(sourcesBlock()), [
        "native/src/cli.cpp",
        "native/src/core/api.cpp",
        "native/src/core/api.h",
      ]);
    });

    test("drops the deliberately excluded sources", () {
      expect(buildSourceFiles(sourcesBlock(exclude: ["native/src/cli.cpp"])), [
        "native/src/core/api.cpp",
        "native/src/core/api.h",
      ]);
    });
  });

  group("buildSourceDigest", () {
    test("is stable for an unchanged tree", () {
      expect(buildSourceDigest(sourcesBlock()), buildSourceDigest(sourcesBlock()));
    });

    test("changes when a source changes", () {
      final before = buildSourceDigest(sourcesBlock());
      writeSource("native/src/core/api.cpp", "int api(int);\n");
      expect(buildSourceDigest(sourcesBlock()), isNot(before));
    });

    // The digest hashes the path list alongside the contents, so this is not implied by the
    // content case: an added file that duplicates an existing one still moves the digest.
    test("changes when a source is added or removed", () {
      final before = buildSourceDigest(sourcesBlock());
      writeSource("native/src/core/copy.h", "int api();\n");
      final added = buildSourceDigest(sourcesBlock());
      expect(added, isNot(before));
      File("native/src/core/copy.h").deleteSync();
      expect(buildSourceDigest(sourcesBlock()), before);
    });

    test("ignores an excluded source's content", () {
      final before = buildSourceDigest(sourcesBlock(exclude: ["native/src/cli.cpp"]));
      writeSource("native/src/cli.cpp", "int main(int, char**);\n");
      expect(buildSourceDigest(sourcesBlock(exclude: ["native/src/cli.cpp"])), before);
    });

    // core.autocrlf writes this repository's sources CRLF on Windows and LF on a Linux runner.
    // The digest has to describe the sources, not the checkout, or CI would report every pin stale.
    test("is unchanged by CRLF line endings", () {
      final lf = buildSourceDigest(sourcesBlock());
      writeSource("native/src/core/api.cpp", "int api();\r\n");
      expect(buildSourceDigest(sourcesBlock()), lf);
    });
  });

  group("verifyInTreeSourceDigests", () {
    Map<String, dynamic> manifestOf(Map<String, dynamic> files) => {"files": files};

    test("accepts a pin recorded against the current sources", () {
      final digest = buildSourceDigest(sourcesBlock());
      final manifest = manifestOf({"wasm/core.wasm": inTreeEntry(sourcesBlock(digest: digest))});
      expect(verifyInTreeSourceDigests(manifest), isEmpty);
    });

    test("reports a pin whose sources moved on", () {
      final digest = buildSourceDigest(sourcesBlock());
      writeSource("native/src/core/api.cpp", "int api(int);\n");
      final manifest = manifestOf({"wasm/core.wasm": inTreeEntry(sourcesBlock(digest: digest))});
      expect(verifyInTreeSourceDigests(manifest), [contains("older than the code in this tree")]);
    });

    test("reports an in-tree entry that records no sources at all", () {
      expect(verifyInTreeSourceDigests(manifestOf({"wasm/core.wasm": inTreeEntry(null)})), [
        contains("records no build.sources block"),
      ]);
    });

    test("reports a checkout that does not have the sources", () {
      Directory("native").deleteSync(recursive: true);
      final manifest = manifestOf({"wasm/core.wasm": inTreeEntry(sourcesBlock(digest: "any"))});
      expect(verifyInTreeSourceDigests(manifest), [contains("this checkout does not have")]);
    });

    test("ignores upstream entries, which are pinned to bytes rather than to sources", () {
      final manifest = manifestOf({
        "wasm/ort.wasm": {"sha256": "unused", "bytes": 0, "origin": "upstream"},
      });
      expect(verifyInTreeSourceDigests(manifest), isEmpty);
    });
  });

  // The digest gate is fatal for everything that decides what ships (codegen, tool/build_web.sh,
  // CI) and switched off only by `tool/check_web_pins.dart --warn-stale-source-digest`, which
  // tool/hooks/pre-commit passes so a native/ change stays committable without an emsdk. Both
  // halves are asserted here, because a default that silently flipped would disable the gate
  // everywhere at once.
  group("verifyWebTree", () {
    // No web/ tree and no git repository in the sandbox, so the other checks contribute their own
    // problems; only the digest message is asserted on.
    Map<String, dynamic> staleManifest() => {
      "files": {"wasm/core.wasm": inTreeEntry(sourcesBlock(digest: "recorded-before-the-change"))},
      "first_party": {"files": <String>[]},
    };

    test("reports a stale in-tree pin by default", () async {
      expect(await verifyWebTree(staleManifest()), contains(contains("older than the code in this tree")));
    });

    test("omits it when the source-digest gate is switched off", () async {
      final problems = await verifyWebTree(staleManifest(), sourceDigests: false);
      expect(problems, isNot(contains(contains("older than the code in this tree"))));
    });
  });
}
