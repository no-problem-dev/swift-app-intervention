# Contributing

Thanks for taking the time to look at this package.

## Reporting a problem

Open an issue with the smallest example that reproduces it, the Swift and Xcode
versions you're on, and the platform you're targeting. A failing test is the
clearest possible report.

## Working on a change

```bash
make verify   # swift build, swift test, iOS Simulator build, sample app, intent metadata check
```

Or one step at a time: `make build`, `make test`, `make build-ios`, `make sample`,
`make check-metadata`. The iOS steps need Xcode 26 or later and XcodeGen.

**Verification happens here, not in CI.** The release workflow does not build or
test — it only turns a tag into a GitHub Release. Run `make verify` locally and
make sure it passes before opening a pull request.

Anything that depends on a real device — the automation actually firing, the app
coming to the foreground, lock signals — is listed in `docs/DESIGN.md` §10 and
cannot be verified by these commands.

Documentation lives in the DocC catalog under `Sources/*/*.docc/`. Public
declarations are documented with `///` comments, in English.

## Releasing

Maintainers only. The version is **computed, never chosen**:

```bash
scripts/release.sh --dry-run   # see what version the API diff implies
scripts/release.sh             # stamp CHANGELOG, tag, push
```

Write what changed under `## [Unreleased]` in `CHANGELOG.md` — prose only, no
version number. `scripts/release.sh` compares the public API against the last
release and derives the version from the actual difference: a removed or changed
public symbol means a major, additions mean a minor, and a change in the
generation of a dependency whose types appear in this package's public API also
means a major.
