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

## Memory ownership audit, 2026-10-20

The findings in this section describe the pre-fix state. Corrections and their
verification are recorded in the later "Memory lifetime fixes" section.

This later audit does not give the app a leak-free certification. It covered
three passes: Swift callbacks, observers and asynchronous work; tab, pane and
window teardown; and native libghostty, renderer and Metal ownership, including
all six maintained patches.

### Recent incident

Commit `5593c61` adds autorelease pools around the libghostty tick, metadata
timer and socket handler. Its incident description reports 40,000 sidebar rows
and 9 GB after two days: continuous main-queue activity delayed the outer
run-loop pool drain. Those incident measurements were not reproduced in this
short audit.

### Confirmed inherited-directory leak, fixed

`SurfaceView.inheritedWorkingDirectory` copied the pointer returned by
`ghostty_surface_inherited_config` without releasing it.
`vendor/ghostty/src/apprt/embedded.zig`, `newSurfaceOptions`, allocates this
NUL-terminated directory with the app allocator. The getter now releases it
through `ghostty_string_free`, with its byte length and sentinel flag, after
copying it into Swift.

In an isolated, allocation-tracked app, 50 split/close cycles originally added
50 leaked 16-byte allocations. Symbolication identified
`ghostty_surface_inherited_config`. The final installed build added no reported
leaks after another 50 split/close cycles and 1,000 notifications: both captures
reported 413 blocks, 26,176 bytes, rooted in Apple's `NSXPCConnection` cycles,
not this native allocation.

### Confirmed AppKit dependency growth, unresolved

The original app returned to one live `Workspace`, `PaneView`, `SurfaceView`
and sidebar `Row` after 50 tab cycles, 50 split cycles and 2,000 changing socket
notifications. Nevertheless, live `NSKeyValueDependency` and related context
and block allocations grew. A standalone AppKit reproducer retained 4,024
dependency records after 2,000 row replacements, versus 44 after 10, despite
an autorelease pool per replacement.

Explicit arranged-subview removal, removing constraints, skipping layout and
the documented observation-tracking opt-out did not eliminate that growth.
Replacing the stack bounded the standalone case but failed in the actual app:
another 2,000 notifications still added 6,000 dependency records and 6,000
contexts. That ineffective workaround was removed. `SidebarView.update` and
`ContainerView.setInfo` remain view-churn sites, not proven retain cycles.
Reachable framework bookkeeping is not detected as a leak by `leaks`.

### Source-backed native ownership risks, not runtime-confirmed

- **Pending clipboard confirmation:** `Ghostty.confirmClipboard` returns when
  a pane closed during its asynchronous alert, without denying the pending
  request. The native wrapper is released only by completion or denial;
  surface destruction does not collect pending requests. Kitty request state
  can also own an arena. Cancellation must happen before surface destruction,
  without allowing a later alert completion to use the old pointer.
- **Rejected or abandoned renderer messages:** the watchdog queue timeout
  returns zero without destroying the submitted payload.
  `Surface.updateConfig` ignores that return after allocating config data;
  `Surface.setFontSize` also ignores it after acquiring a font-grid reference.
  Renderer-thread destruction frees mailbox storage without draining owned
  messages. Cleanup must account for each payload's ownership transfer,
  including old and new font-grid references.
- **Messages for already-closed surfaces:** `App.surfaceMessage` skips handling
  when the surface is gone, without disposing of owned Kitty requests,
  allocated clipboard writes or long cwd messages. Normal-path disposal lives
  in `Surface.handleMessage`, which this path bypasses.
- **Initialization failures:** font-grid references and renderer configuration
  lack complete unwind cleanup during surface initialization. Metal target
  creation can leave an IOSurface allocated if texture creation fails, and
  swap-chain initialization does not unwind earlier completed frames. A
  separate resource-exhaustion hazard starts the renderer before spawning the
  IO thread, without a renderer stop/join unwind if that second spawn fails.
  These paths require targeted failure injection before claiming a fix.

The documented watchdog exception also remains: killing a hung pane retains
its native surface and Swift view until app exit, because freeing it would
join the stuck renderer. Memory therefore grows with abandoned panes by
design. Removing this exception without changing that lifetime contract would
reintroduce whole-app freezes.

No additional production retain cycle or growing Swift history collection was
established. Settings refresh concurrency, whole git-status output buffering
and unpooled asynchronous UI completions are separate conditional risks, not
measured cumulative leaks here.

### Verification limits

Test instances used `open -g -n`, separate state files and sockets, and exact
process IDs. No owner instance was quit or relaunched, no desktop input was
posted, and clipboard permission prompts were not exercised. `swift test`
executed 43 tests with zero failures and one skipped notarized-fixture test.
`scripts/install-local.sh` completed a release build and installed the result.
The final installed-build smoke again ended with one live tab, pane, surface
view and sidebar row, but dependency records grew from 745 to 4,046, so that
remaining retention is explicitly not marked fixed.
The source-backed native failure paths above were inspected, not fault
injected. These short runs do not establish two-day steady-state behavior or
exhaust every libghostty allocation path.

## Memory lifetime fixes

The approved ownership fixes are implemented. The existing coalesced metadata
refresh and per-action autorelease pools remain.

### Implementation

- `SidebarView` retains rows by workspace identity and headers by group ID.
  Title, cwd, ports, selection, labels, accessibility and attention state update
  existing controls. Structural changes reconcile arranged views without
  detaching surviving rows or duplicating their width constraints. Color and
  animation updates are gated by value snapshots, including mutable group
  colors. Appearance and Reduce Motion changes refresh the retained controls.
- `ContainerView` reuses titlebar labels and separators instead of rebuilding
  the hierarchy when branch/status text changes.
- `ClipboardConfirmation` consumes its native completion exactly once.
  `SurfaceView.destroy` denies pending requests before freeing or abandoning
  the surface. Clipboard permission sheets are dismissed by their own window;
  queued presentation and late completions cannot use canceled state.
- `patches/ghostty-resource-lifetime.patch` supplies native ownership fixes.
  Rejected owned sends and stale-surface messages destroy their payloads;
  renderer, search and app teardown drain owned messages. Font-grid rejection
  releases the new reference, while queued-message disposal releases the old
  renderer reference. Configuration and search-arena transfers avoid both
  leaks and double cleanup on subsequent errors.
- Native initialization unwinds acquired fonts/configs, partial swap-chain
  frames and IOSurfaces after texture failure. Started renderer and IO threads
  stop and join before their state is unwound on later initialization errors.
- Blocking queue producers recheck capacity after every wake rather than
  silently losing a final update when another producer takes the slot. Timed
  pushes retain one deadline and the main-thread 250 ms bound.

### Verification

- Targeted native tests passed, 90 tests:
  `zig build test -Dsentry=false -Di18n=false -Dtest-filter=blocking_queue -Dtest-filter=renderer.message -Dtest-filter=renderer.generic -Dtest-filter=apprt.surface`.
  They cover wake-without-capacity concurrency, owned rejection versus retry,
  discarded payload/font ownership, exhaustive configuration-message
  allocation failures and partial-frame rollback on allocation failure.
- `scripts/build-ghostty.sh` reset the pinned checkout, reapplied maintained
  patches, and rebuilt the actual xcframework successfully.
- `swift test` passed 54 tests with zero failures and one skipped notarized
  fixture. New coverage includes retained row/editor state, group/attention
  transitions, visible reorder geometry and drag-appearance restoration,
  closed-workspace release, titlebar updates, exact-once clipboard cancellation
  and reentrancy. A real native
  OSC 52 request is canceled before queued presentation, using synthetic
  clipboard contents and an offscreen view, without accessing the pasteboard.
- `scripts/install-local.sh` built and installed the release app. The bundle
  remains 14M at the precision reported by `du`.
- The installed app ran 11 synthetic agents through warm-up, 16-title bursts
  every 50 ms, normal single-title updates every 50 ms, and a repeated normal
  run. All final titles and cwd updates arrived, no pane was marked hung,
  and all socket probes completed. The largest observed request latency was
  11.32 ms. Actual sidebar captures and offscreen row/group captures were
  inspected.
  After the drag-appearance correction, the final installed release repeated
  the warm-up and burst phases with the same bounded counts and complete
  metadata delivery.

The same 11 panes stayed open across all phases. These live allocation counts
include allocation-stack logging:

| Measurement | Warm-up settled | Burst settled | Normal settled | Repeat settled |
| --- | ---: | ---: | ---: | ---: |
| Sidebar rows | 11 | 11 | 11 | 11 |
| AppKit dependency records | 1,893 | 1,893 | 1,893 | 1,893 |
| AppKit dependency contexts | 586 | 586 | 586 | 586 |

The reported leak baseline remained 415 blocks, 26,320 bytes, rooted in three
Apple `NSXPCConnection` cycles. Another 50 split/close cycles preserved inherited
cwd, returned to one live workspace/pane/surface view/row, and added no reported
leaks. An invalid background-image fixture exercised 50 failed renderer
constructions, leaving no native surface roots or child processes and adding
no reported leaks to that separate process's baseline.

### Remaining limits

The title/metadata allocation-growth path is bounded in these runs, not a proof
of universal leak freedom. Structural churn still grows some reachable AppKit
bookkeeping: the 50 split cycles added 327 dependency records, and the 50 failed
tab constructions added 300. Neither retained closed panes/surfaces nor added
reported native leaks. This is distinct from the eliminated per-title growth.
The deliberate hung-surface retention remains unchanged, because freeing a
stuck renderer would block the app.

GPU texture-allocation failure and OS thread-spawn failure were not directly
injected. Partial-frame and configuration allocation failures were injected
in native tests, and invalid-background renderer failure was exercised in
the installed app. Visible clipboard dialogs were not operated. No owner
instance was quit or relaunched, and no desktop input was posted. All owned
runtime test instances were closed.
