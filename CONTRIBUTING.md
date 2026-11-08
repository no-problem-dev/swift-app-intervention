# Contributing

Thanks for taking the time to look at this package.

## Reporting a problem

Open an issue with the smallest example that reproduces it, the Swift and Xcode
versions you're on, and the platform you're targeting. A failing test is the
clearest possible report.

## Working on a change

```bash
make verify   # build, test, iOS Simulator build, intent metadata check, DocC (no warnings)
make qa       # scripted simulator pass of the sample app, screenshots in .build/qa-shots
make mutants  # mutation run in a git worktree of HEAD (commit first)
```

Every target prints its time against a budget (`make help`); going over the budget is a bug.
The iOS steps need Xcode 26 or later, XcodeGen and jq.

Tests never wait unbounded: iterate async sequences only through `collect` / `firstValue` in
`Tests/*/Bounded.swift`, and give every `@Suite` a `.timeLimit`. `make test` enforces both
(`scripts/check-bounded-awaits.sh`). When you change code covered by `scripts/mutants.py`,
update the snippets there; a stale mutant fails the run.

**There is no CI.** Run `make verify` locally and make sure it passes before
opening a pull request.

Anything that depends on a real device — the automation actually firing, the app
coming to the foreground, lock signals — is listed in `docs/DESIGN.md` §10 and
cannot be verified by these commands.

Documentation lives in the DocC catalog under `Sources/*/*.docc/`. Public
declarations are documented with `///` comments, in English.

## Releasing

Maintainers only.

1. In `CHANGELOG.md`, turn `## [Unreleased]` into `## [x.y.z] - YYYY-MM-DD` and
   merge that to `main`.
2. Tag the merge and push the tag:

   ```bash
   git tag x.y.z && git push origin x.y.z
   ```

Versions follow [SemVer](https://semver.org) with bare tags (`1.2.3`, no `v`).
While the major version is 0, a breaking change bumps the minor version.
