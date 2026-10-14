# Codebase audit and fixes

Status: `accepted`

The audited first party scope is `Sources/Helium`, `Tests/HeliumTests`, all
maintained scripts, `packaging`, `bench`, `site`, and the four maintained
Ghostty patches. The initial `swift test` baseline passed 24 tests. The reviewed
changes are prepared for a local commit. No owner relaunch, updater install,
release, publication, or UI control was performed.

## Findings and fixes

- Socket startup could unlink a regular or replaced path, race another startup,
  leave the listener exposed during setup, emit partial writes, terminate on a
  closed peer, block forever on slow drip input, and race listener shutdown.
  Startup now validates the Unix path and file type/owner, rejects embedded
  NULs, opens an owner checked regular lock with `O_NOFOLLOW`, coordinates
  startup with `flock`, only unlinks an inode it owns, checks `chmod(0600)`,
  verifies accepted peer UID with `getpeereid`, sets `SO_NOSIGPIPE`, uses
  nonblocking descriptors with two second overall read/write deadlines, retries
  transient would block results under those deadlines, bounds
  accepted clients to 32, enforces the request cap even when a read overshoots
  the newline, and shuts down without waiting on client work that can call the
  main queue. Regression cases cover path preservation, NUL and lock symlinks,
  mode, second instance ownership, restart, successful large round trips,
  closed peers, saturation, prompt shutdown, byte at a time timeout, and a
  filled socketpair write deadline.
- CLI argument parsing converted `\\n` in every command and routed `--help`
  into the app. Parsing now decodes it only for `send`, validates socket
  addresses, and uses bounded I/O while `--help`/`-h` print usage. Tests cover
  both forms.
- Agent restore previously retained or replayed single word prompts and could
  drop option values or mistake Codex option values for subcommands. Restore
  now parses current Claude/Codex option/value groups, preserves required,
  optional, variadic, comma, and quoted values, discards `--` and its prompt,
  skips global option values during Codex subcommand detection, and scopes
  rollout lookup to the candidate PID. Tests cover the required value,
  variadic value, separator, single word and multi word prompts, options after
  prompts, and subcommand cases.
- Persisted split ratios were accepted without finite/bounds checks, while an
  arbitrary five percent minimum would change valid one percent and 99 percent
  layouts. Capture and restore now preserve every finite ratio in `[0,1]` and
  replace only invalid persisted input with the neutral ratio. Tests cover
  `0.01`, `0.99`, NaN, and out of range values.
- Tests wrote shared user defaults and required a live Claude process, checkout
  Git metadata, and a third party app path. Production defaults now use an
  overridable store, tests use a per process suite, and session/Git/updater
  tests use synthetic fixtures.
- Updater metadata and asset responses now require actual 2xx statuses before
  parsing or installing; release assets remain HTTPS only. The local signed
  archive fixture verified matching team and bundle ID, rejected mismatches,
  and passed notarization validation. Deterministic missing-app checks and
  an HTTP status matrix cover both metadata and download gates. No update was
  installed.
- Local installation stages with `ditto`, backs up the installed app, and
  restores it after a failed final move. A temporary assert based harness copied
  the staging/promotion block, forced staging copy and final move failures,
  checked the original bundle and backup cleanup, then checked successful
  promotion. Benchmark cleanup removes only its exact state, socket, and lock
  paths.

## DRY and SOLID

Shared Unix address validation and complete writes serve both the server and
CLI. One HTTP status gate serves metadata and archive downloads. Claude and
Codex use the same required/variadic option consumption rules with their own
option tables. The existing handler boundary keeps socket transport separate
from app commands; an overridable platform defaults store isolates persistence
tests. No dependencies, speculative interfaces, or framework layers were added.

## Verification

All commands below ran from the repository root and returned exit status 0
unless stated otherwise.

- `rtk swift test` — 40 XCTest cases passed, plus the package test harness's
  zero test Swift Testing target.
- `rtk swift test --filter SessionTests` and `rtk swift test --filter SocketTests` —
  affected suites passed, including the post-prompt flag and would block
  deadline regressions.
- `rtk scripts/install-local.sh` — release build, strict ad hoc signature
  verification, and local installation passed after the correction batch.
- Temporary `rtk sh -s` installer fixture — staged copy failure, final move
  failure with rollback, and successful promotion assertions passed.
- `rtk git diff --check` — clean.
- Each maintained shell script was checked separately with `/bin/sh -n` or
  `/bin/bash -n`, according to its interpreter, via `rtk proxy python3`.
- `rtk .build/debug/helium-terminal --help` and `... -h` — both printed CLI
  usage without launching the app.
- `rtk codesign --verify --strict 'build/Helium Terminal.app'` — passed.
- Secret scan over `Sources`, `Tests`, `scripts`, `packaging`, `bench`, `site`,
  `README.md`, and `patches` found only expected option/comment names.
- App size was 15 MB in the baseline artifact and 14,444 KB in both the final
  build and installed app. The iTerm2 comparison was skipped because iTerm2 is
  unavailable in this environment; no performance claim is made.

## Review checkpoint

Two post correction review passes inspected the complete tracked diff, both new
test files, all first party Swift callers, scripts, packaging, benchmark
cleanup, site, and maintained patches. A final targeted pass rechecked the
parser and socket changes and found no new actionable issue.
Remaining limits are the environment dependent remote release check and the
iTerm2 comparison; neither was executed. The local signed update fixture did
run successfully, while no actual self update was attempted.

Root acceptance reviewed the complete patch, callers, new files, and regression
evidence. The final DRY consolidation passed all 40 tests with zero failures and
zero skips. Root also repeated the temporary installation failure assertions,
checked each script's syntax, scanned added content for secrets, and completed
`scripts/install-local.sh`. No actionable findings remain in the reviewed scope.
This is not a proof that the app or its upstream dependency has no bugs.
