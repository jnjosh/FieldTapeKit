# Releasing FieldTapeKit

What to check before tagging a release, from ADR 0002, section 11. The owner tags every release. Stop at the first check that fails and fix it before going on.

Run everything from the repository root, with Xcode 27.2:

```bash
export DEVELOPER_DIR=/Applications/Xcode-27.2.0.app/Contents/Developer
```

## Before tagging

1. **The working tree is clean,** on `main`, and every change for the release is committed.

2. **No unexpected API breaks,** compared with the previous release's tag:

   ```bash
   xcrun swift package diagnose-api-breaking-changes <previous tag> --products FieldTapeKit
   ```

   Pre-releases make no promises about compatibility, but the release notes list every break this finds. From `1.0.0` on, any break needs a new major version.

3. **The archive fixtures still open.** `Tests/FieldTapeKitTests/Fixtures` holds one `.reelarchive` for every format version, and the tests open each one:

   ```bash
   xcrun swift test --filter ReelArchiveTests
   ```

   A new format version gets a new fixture, made once with `FIELDTAPEKIT_WRITE_FIXTURE=1 swift test`. A fixture is never replaced.

4. **The safety suite passes,** one group per rule in ADR 0002, section 6, on the simulator:

   ```bash
   xcrun swift test --filter SafetyRules
   ```

   With more than one tested firmware, it has to pass on the simulator for every one.

5. **Every test passes,** on the Mac and on the iOS simulator:

   ```bash
   xcrun swift test
   ```

   ```bash
   xcodebuild -scheme FieldTapeKit-Package -destination 'id=0F76E627-D8A1-46BA-A245-C9C5DDE71C80' test
   ```

6. **The documentation builds with no DocC warnings** ([DOCUMENTATION_GUIDE.md](DOCUMENTATION_GUIDE.md)):

   ```bash
   ./scripts/build-docs.sh
   ```

   It also compiles every snippet. Every public declaration has a doc comment, and every method documents its parameters, what it returns and what it throws.

7. **FieldCheck builds for iOS** (run these from `FieldCheck/`):

   ```bash
   xcodegen generate
   ```

   ```bash
   xcodebuild -project FieldCheck.xcodeproj -scheme FieldCheck -destination 'generic/platform=iOS' -allowProvisioningUpdates build
   ```

8. **The OP-1 run the plan asks for has passed,** if the step has one, and its log is in `firmware/<version>/runs/`. Use the iPhone for now (STATUS.md).

## The version

FieldTapeKit follows Semantic Versioning 2.0.0 (ADR 0002, section 11):

- **Pre-releases** go `1.0.0-alpha.N`, then `1.0.0-beta.N`, then `1.0.0`.
- **From `1.0.0`, a major version** for anything that breaks source compatibility, writes an archive format earlier 1.x versions can't open, drops a firmware, or loosens a safety rule or a default that protects music.
- **A minor version** for new API, a new firmware, reading a new archive format, or tightening a safety rule.
- **A patch** for bug fixes that change none of those.

## Tagging

The release notes go in [CHANGELOG.md](../CHANGELOG.md): move everything under **Unreleased** into a section for the new version, with today's date. Say what was added and what changed, mark everything that broke since the last tag **Breaking**, say what a tightened safety rule newly refuses, and list the known limits. Add the version's compare link at the bottom. Commit that, with a message that names the version and points to the CHANGELOG, then:

```bash
git tag <version>
```

Record the tag in STATUS.md, under the step it finishes.
