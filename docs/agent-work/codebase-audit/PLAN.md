# Codebase audit and fixes

## Objective

Review Helium's first-party code for reproducible bugs, unsafe failure paths,
and duplication that causes inconsistent behavior. Fix confirmed findings with
the smallest complete change, then repeat the review until no actionable
findings remain in the reviewed scope. This is not a guarantee of no bugs.

## Scope and contracts

- Audit `Sources/Helium`, `Tests/HeliumTests`, scripts, packaging, benchmarks,
  the static site, and the four maintained Ghostty patches. The pinned upstream
  Ghostty source is a dependency, not a rewrite target.
- Preserve existing features, public CLI/socket behavior, saved-state backward
  compatibility, user configuration, and the lightweight native architecture.
- Apply DRY and SOLID where a concrete duplication or responsibility problem
  causes inconsistent behavior or makes risky logic untestable. Do not add
  protocols, frameworks, dependencies, or speculative layers to satisfy a label.
- Socket ownership must survive a second instance, disconnects, partial I/O,
  malformed requests, and startup/shutdown races. Never unlink a live socket or
  an unrelated file, expose the socket beyond its owner, or let SIGPIPE kill
  the app. Keep request processing bounded and preserve explicit pane targeting.
- Agent restore must not replay an initial prompt, mistake a command-line
  option's value for a subcommand, or resume another process's session.
  Preserve supported agent flags and quote substituted shell values.
- State writes must remain atomic, compatible with older files, and isolated in
  tests. Failed operations must not destroy the user's installed app or state.
- Updates must still require the same Apple team, the Helium bundle identifier,
  notarization, and the advertised version before replacement. Do not exercise
  actual updates, publication, or releases during verification.
- Preserve focus/occlusion behavior and existing rendering/scrolling decisions.
  No UI control, foreground launches, owner-session termination, or paid tests.

## Execution

Baseline: clean `main`, commit
`e7f8f1cda24eecc3b0226fbc430ec33f5177fade`.
Working branch: `fix/codebase-audit`.

1. One native `luna_builder` owns repository discovery, audit, minimal fixes,
   regression tests, internal review/fix cycles, and local installation.
2. The root reviews the actual patch using specification and quality/security
   lenses together. Return concrete corrections in one batch if needed.
3. Accept only with regression evidence and no unresolved actionable findings;
   commit locally with the repository's author identity. Hold public pushes
   pending the owner's confirmation, as required by `CLAUDE.md`.

The selected root remains the planner and reviewer. Host metadata currently
reports `gpt-6.1-sol`; it is not changed mid-task. The named worker role pins
`gpt-5.6-luna`. Host thread metadata verified child
`01a13b3b-e7e3-7890-bef1-cfab1f483a2a` on `gpt-5.6-luna`, effort `max`,
role `luna_builder`.

## Acceptance

- Each fix has a concrete failure case and a meaningful regression check.
- `swift test` passes. Changed shell scripts pass syntax checks and synthetic
  self-checks where needed. No weakened tests or hidden test failures.
- Run `scripts/install-local.sh` after each completed code-change batch. Do not
  relaunch the owner's app.
- Record before/after release app size. Measure launch/memory/CPU only through
  isolated background instances with dedicated state/socket paths and exact-PID
  cleanup. Do not run the iTerm2 comparison if it is open.
- Record the final repeated-review result, tested behavior, and unverified
  limits. Do not claim a bug-free codebase or a formal SOLID proof.
- Review all changed/untracked files, run `git diff --check`, and scan additions
  for secrets before preparing anything for public publication.

## Out of scope

New features, dependency upgrades, broad style rewrites, vendor-wide audit,
UI-driving tests, paid agent invocations, releasing, pushing, and deployment.

## Acceptance checkpoint

The first implementation returned 31 passing tests and a successful local
install. Root review requested one consolidated correction pass for confirmed
agent option/delimiter parsing defects, bounded socket concurrency and I/O,
preserved team/identifier security coverage and HTTP failure tests, valid split
ratio preservation, and installation rollback evidence. These are parsing,
security, and data-preservation findings, not an architectural rewrite.

Current state: corrected implementation accepted after root review and the final
DRY consolidation. All 40 tests passed, including local notarized signature
checks, and local installation succeeded. Root independently repeated the
installer rollback assertions and shell syntax/secret checks. The local commit
is the final integration step. Public push requires the owner's confirmation
under `CLAUDE.md`; release and deployment remain outside scope.
