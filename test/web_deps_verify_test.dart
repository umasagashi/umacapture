import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/web_deps_verify.dart';

/// Bytes used for every fixture file, and the pin that describes them.
const String pinnedContent = "pinned bytes\n";
const String pinnedSha256 = "d21d7ea3ee1a2b0d1b09b0e2b1cae1cc4a5a3c3ad3a9f8f2b48e6d8bb4f37b0f";

/// Builds a manifest around [files], with [firstParty] as the allowlist.
Map<String, dynamic> manifestOf({required Map<String, dynamic> files, List<String> firstParty = const []}) {
  return {
    "manifest_version": 1,
    "provisioned_root": "wasm/",
    "first_party": {"files": firstParty},
    "files": files,
  };
}

/// A pinned entry for content written by [writeWebFile].
Map<String, dynamic> pinnedEntry(String sha256, {String origin = "upstream"}) {
  return {
    "sha256": sha256,
    "bytes": pinnedContent.length,
    "origin": origin,
    "license": {"id": "MIT", "asset": "assets/license/example.txt"},
  };
}

/// Writes [content] to `web/<relative>` inside the current directory.
File writeWebFile(String relative, [String content = pinnedContent]) {
  final file = File("web/$relative");
  file.parent.createSync(recursive: true);
  return file..writeAsStringSync(content);
}

void main() {
  // The verification code addresses `web/` relative to the current directory, exactly as
  // build_runner and the CLI do. Each test therefore runs inside its own temp directory,
  // so a fixture can never touch the real tree.
  late Directory previous;
  late Directory sandbox;

  setUp(() {
    previous = Directory.current;
    sandbox = Directory.systemTemp.createTempSync("web_deps_verify_");
    Directory.current = sandbox;
  });

  tearDown(() {
    Directory.current = previous;
    sandbox.deleteSync(recursive: true);
  });

  /// The digest the fixture content actually has, computed once against the real hasher.
  Future<String> digestOfFixture() async => sha256OfFile(writeWebFile("digest_probe.txt"));

  group("partitionWebFiles", () {
    test("splits pinned entries by whether the file exists", () async {
      writeWebFile("here.js");
      final (present, absent) = partitionWebFiles({
        "here.js": pinnedEntry(pinnedSha256),
        "gone.js": pinnedEntry(pinnedSha256),
      });
      expect(present.keys, ["here.js"]);
      expect(absent, ["gone.js"]);
    });
  });

  group("verifyWebPins", () {
    test("accepts bytes that match the pin", () async {
      final digest = await digestOfFixture();
      writeWebFile("ok.js");
      final (present, _) = partitionWebFiles({"ok.js": pinnedEntry(digest)});
      expect(await verifyWebPins(present), isEmpty);
    });

    test("reports a size mismatch before hashing", () async {
      final digest = await digestOfFixture();
      writeWebFile("drifted.js", "${pinnedContent}extra");
      final (present, _) = partitionWebFiles({"drifted.js": pinnedEntry(digest)});
      expect(await verifyWebPins(present), [contains("bytes pinned")]);
    });

    test("reports a content mismatch of identical length", () async {
      writeWebFile("flipped.js", "pinned bytez\n");
      final (present, _) = partitionWebFiles({"flipped.js": pinnedEntry(await digestOfFixture())});
      expect(await verifyWebPins(present), [contains("sha256")]);
    });
  });

  group("unlistedWebFiles", () {
    test("accepts a tree of exactly the pinned and first-party files", () {
      writeWebFile("pinned.js");
      writeWebFile("index.html");
      expect(
        unlistedWebFiles(
          {"pinned.js"},
          {
            "files": ["index.html"],
          },
        ),
        isEmpty,
      );
    });

    test("reports a stray file at the root and nested", () {
      writeWebFile("stray.js");
      writeWebFile("nested/deep/stray.js");
      final problems = unlistedWebFiles(const {}, {"files": const []});
      expect(problems, hasLength(2));
      expect(problems.first, contains("web/nested/deep/stray.js"));
    });

    test("matches the allowlist exactly, not by directory prefix", () {
      writeWebFile("icons/Icon-192.png");
      writeWebFile("icons/payload.js");
      final problems = unlistedWebFiles(const {}, {
        "files": ["icons/Icon-192.png"],
      });
      expect(problems, [contains("web/icons/payload.js")]);
    });

    test("reports a symbolic link even when its name is allowlisted", () {
      final target = File("${sandbox.path}/outside.js")..writeAsStringSync("payload");
      Directory("web").createSync(recursive: true);
      try {
        Link("web/index.html").createSync(target.path);
      } on FileSystemException {
        // Creating a symlink on Windows needs Developer Mode or elevation. Skip rather than
        // fail on hosts that forbid it; the check itself is exercised wherever it is allowed.
        markTestSkipped("symlink creation is not permitted on this host");
        return;
      }
      expect(
        unlistedWebFiles(const {}, {
          "files": ["index.html"],
        }),
        [contains("symbolic link")],
      );
    });

    test("returns nothing when web/ does not exist at all", () {
      expect(unlistedWebFiles(const {}, {"files": const []}), isEmpty);
    });
  });

  group("verifyWebLicenses", () {
    test("rejects a present file with no license text", () {
      writeWebFile("nolicense.js");
      final manifest = manifestOf(
        files: {
          "nolicense.js": {
            ...pinnedEntry(pinnedSha256),
            "license": {"id": "UNLICENSED", "asset": null},
          },
        },
      );
      expect(verifyWebLicenses(manifest), [contains("nothing to disclose")]);
    });

    test("ignores the same entry while the file is absent", () {
      final manifest = manifestOf(
        files: {
          "nolicense.js": {
            ...pinnedEntry(pinnedSha256),
            "license": {"id": "UNLICENSED", "asset": null},
          },
        },
      );
      expect(verifyWebLicenses(manifest), isEmpty);
    });

    test("rejects a present file marked relocation_required", () {
      writeWebFile("misplaced.mp4");
      final manifest = manifestOf(
        files: {
          "misplaced.mp4": {
            ...pinnedEntry(pinnedSha256, origin: "in-tree"),
            "license": {"id": "MIT", "asset": "LICENSE"},
            "relocation_required": {"reason": "must live outside web/"},
          },
        },
      );
      expect(verifyWebLicenses(manifest), [contains("relocation_required")]);
    });

    test("rejects an upstream file claimed under this repository's own license", () {
      writeWebFile("vendor.mjs");
      final manifest = manifestOf(
        files: {
          "vendor.mjs": {
            ...pinnedEntry(pinnedSha256),
            "license": {"id": "MIT", "asset": "LICENSE"},
          },
        },
      );
      expect(verifyWebLicenses(manifest), [contains("outside assets/license/")]);
    });

    // THE `linked` LIST IS WHERE THE THIRD-PARTY CODE ACTUALLY IS. The check above keys on the
    // top-level `origin`, and a `linked` sub-entry has no `origin` of its own -- so it used to be
    // invisible to that loop, and the claim loop skipped any asset outside assets/license/ without
    // a word. A new library added to the wasm by copying its neighbour's license block (the parent
    // may legitimately say `"asset": "LICENSE"`, being in-tree) therefore shipped undisclosed and
    // the manifest still called itself verified. The two tests below are a pair: the second is what
    // makes the first mean "the relation was checked" rather than "some asset was checked".
    test("rejects a statically linked library claimed under this repository's own license", () {
      writeWebFile("core.wasm");
      final manifest = manifestOf(
        files: {
          "core.wasm": {
            ...pinnedEntry(pinnedSha256, origin: "in-tree"),
            "license": {"id": "MIT", "asset": "LICENSE"},
            "linked": [
              {
                "name": "SomeLib",
                "version": "1.0",
                "license": {"id": "BSD-3-Clause", "asset": "LICENSE"},
              },
            ],
          },
        },
      );
      expect(verifyWebLicenses(manifest), [contains("statically links SomeLib 1.0")]);
    });

    test("accepts the same linked library once its own license text is disclosed", () {
      writeWebFile("core.wasm");
      final text = File("assets/license/somelib.txt");
      text.parent.createSync(recursive: true);
      text.writeAsStringSync("BSD-3-Clause\n");
      final manifest = manifestOf(
        files: {
          "core.wasm": {
            ...pinnedEntry(pinnedSha256, origin: "in-tree"),
            "license": {"id": "MIT", "asset": "LICENSE"},
            "linked": [
              {
                "name": "SomeLib",
                "version": "1.0",
                "license": {"id": "BSD-3-Clause", "asset": "assets/license/somelib.txt"},
              },
            ],
          },
        },
      );
      expect(verifyWebLicenses(manifest), isEmpty);
    });

    test("rejects a referenced license text that is not committed", () {
      writeWebFile("vendor.mjs");
      final manifest = manifestOf(files: {"vendor.mjs": pinnedEntry(pinnedSha256)});
      expect(verifyWebLicenses(manifest), [contains("is not committed")]);
    });
  });

  group("webProvisioningStatus", () {
    // Mirrors the real manifest: an unprovisioned file outside provisioned_root, three
    // upstream files inside it, and the in-tree recognition core that only a local build
    // (or a release machine) can produce.
    final manifest = manifestOf(
      files: {
        "coi-serviceworker.js": pinnedEntry(pinnedSha256),
        "wasm/ort/ort.mjs": pinnedEntry(pinnedSha256),
        "wasm/ort/ort.wasm": pinnedEntry(pinnedSha256),
        "wasm/core.js": pinnedEntry(pinnedSha256, origin: "in-tree"),
        "wasm/core.wasm": pinnedEntry(pinnedSha256, origin: "in-tree"),
      },
    );

    test("is verified only when every provisioned_root entry is present", () {
      expect(webProvisioningStatus(manifest, const []), webStatusVerified);
      // A file outside provisioned_root has no say in the status.
      expect(webProvisioningStatus(manifest, const ["coi-serviceworker.js"]), webStatusVerified);
    });

    test("is not_provisioned when none of them is", () {
      const absent = ["wasm/ort/ort.mjs", "wasm/ort/ort.wasm", "wasm/core.js", "wasm/core.wasm"];
      expect(webProvisioningStatus(manifest, absent), webStatusNotProvisioned);
    });

    test("is partially_provisioned when the recognition core alone is missing", () {
      // This is the shape 'uv run tool/fetch_web_deps.py' leaves behind, and what CI runs in.
      // Reporting it as verified would let tool/build_web.sh --require-verified ship a bundle
      // with no recognition core.
      const absent = ["wasm/core.js", "wasm/core.wasm"];
      expect(webProvisioningStatus(manifest, absent), webStatusPartiallyProvisioned);
      expect(webProvisioningStatus(manifest, const ["wasm/core.wasm"]), webStatusPartiallyProvisioned);
    });
  });
}
