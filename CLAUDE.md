# Helium Terminal

A macOS terminal for running coding agents, built on libghostty. Native Swift and AppKit (SwiftPM, no Xcode
project), Apple Silicon only, macOS 13+.

## Product scope

Only these features, and nothing that makes the app heavier:

- Vertical tabs in a sidebar showing title, git branch, cwd, listening ports and the latest notification
- Notification rings: a pane lights up when a program needs attention
- Horizontal and vertical splits in every tab
- A CLI (`helium`) and a Unix socket API for automation
- GPU rendering through libghostty
- Very lightweight. Size, launch time, idle memory and idle CPU are features; measure before and after changes

Since added at the owner's request: a resizable sidebar, Settings (⌘,), link hover feedback, and auto-update.
Not wanted: Electron or web views, session restore, a browser pane, Sparkle or other heavy frameworks.

## Design decisions (keep these unless the owner changes them)

- **libghostty** comes from `vendor/ghostty` at the commit in `vendor.lock`, with `patches/` applied by
  `scripts/build-ghostty.sh`. It's built ReleaseFast (ReleaseSmall saves 3 MB but parses escape-heavy output about
  40% slower), with `-Dsentry=false -Di18n=false`. The renderer is patched to double buffering.
- **Ghostty themes aren't bundled** (2.6 MB). Users put themes in `~/.config/ghostty/themes`.
- **Config:** the user's Ghostty config loads first, then `~/Library/Application Support/helium-terminal/config`,
  which Settings writes. Never rewrite the user's Ghostty config; it may be shared with Ghostty.app.
- **Focus:** a surface is focused only as first responder of the key window. libghostty starts surfaces focused,
  so `reportedFocus` starts `true`. Getting this wrong keeps the cursor blink and display link running in the
  background.
- **Visibility:** hidden tabs and covered or minimized windows call `ghostty_surface_set_occlusion(false)`, which
  frees GPU buffers. Don't treat a window as occluded before its first show.
- **Content scale:** comes from `window.backingScaleFactor`, never a frame ratio, because the first tab starts at
  zero size.
- **Two kinds of notification:** blue (ring, dot, message text; cleared by focusing the pane) for news, and
  orange (ring plus a "needs input" badge; cleared only by typing in that pane) when an agent is blocked on the
  user. `Workspace.isWaitingForInput` decides by phrase. Sidebar rows size to their content; notification text
  wraps to the real sidebar width.
- **Session restore:** on ⌘Q and every metadata poll, tabs, splits (with ratios), folders and running agents are
  saved to `state.json`; launch rebuilds them and types each agent's resume command via `initial_input`.
  Claude's session ID comes from `~/.claude/sessions/<pid>.json` (undocumented, read defensively), Codex's from
  its open rollout file. Agents are matched by argv[0] (native Claude runs as a versioned file). Programs don't
  survive a quit; that would need a session daemon, which the owner didn't ask for. Tests set
  `HELIUM_STATE_FILE` as well as `HELIUM_SOCKET`.
- **Tab titles and labels:** `Workspace.customTitle` (double-click to edit inline; empty means automatic) and
  `Workspace.labels`, names of shared labels in `LabelStore` (user defaults: name plus a palette color). Both are
  saved in `state.json` as optional fields so older state files still load. The sidebar skips rebuilds while a
  title is being edited.
- **Sidebar metadata** is polled every 3 s from `.git/HEAD` reads and libproc (`ProcessTree`). It never runs a
  subprocess.
- **Socket API:** one JSON object per line, file mode 0600. A second instance must never take over or delete a
  live socket. `$HELIUM_PANE` is set in every pane. `helium +action` passes through to libghostty CLI actions
  (for example `+show-config --docs`).
- **Naming:** the app is `Helium Terminal.app` so it can't overwrite the Helium browser's `Helium.app`. The bundle
  ID is `io.github.yowmamasita.helium-terminal` and the CLI is `helium`. `helium` with no arguments in a terminal
  opens the app.
- **Distribution:** the app is Developer ID signed with the hardened runtime and the entitlements in `packaging/`,
  and notarized. Homebrew gets a cask (`auto_updates true`). zerobrew gets a formula with an `arm64_ventura`
  bottle, because zerobrew can't install `app` casks. Both live in `yowmamasita/homebrew-tap`.
- **Updates:** a built-in updater, not Sparkle. It reads GitHub releases, installs only builds signed by the
  running app's Apple team and notarized, swaps the app on disk, and never relaunches without the user (open
  shells would die). It's disabled for dev builds, formula installs and translocated copies.

## Working rules

- **Never control the Mac while the owner may be using it:** no keystrokes, clicks or stealing focus without
  asking first. Launch test instances in the background (`open -g -n`), with
  `HELIUM_SOCKET=/tmp/helium-test.sock` so they can't touch the owner's instance.
- **The owner's real sessions, including this assistant, may be running inside Helium or iTerm2.** Never `pkill`
  or quit them. Kill test processes by exact PID, excluding the owner's. Use `/usr/bin/pgrep`, because a shell
  wrapper can swallow plain `pgrep` output.
- **After every code change, run `scripts/install-local.sh`** (not just `build-app.sh`) so
  `/Applications/Helium Terminal.app`, the copy the owner launches from Raycast, is always current. Installing
  is safe while Helium runs. Never relaunch it yourself, because that ends the owner's session: tell them to
  relaunch and resume with `claude --resume`.
- **Screenshots and docs are public:** use throwaway demo repos and a minimal prompt, with no usernames,
  hostnames or real paths. Check every capture before committing it.
- **Benchmarks** (`bench/final.sh`): no keystrokes, background launches. Compare against iTerm2, not cmux.
- **Writing:** plain, specific English. Commas rather than em dashes, no emojis.
- **Commits:** author `Ben Adrian Sarmiento <ben+claude@nimbly.email>`, no attribution trailers. Before any public
  push, scan for secrets. Hold pushes the owner hasn't confirmed.
- **New logic with branches, parsing or security** gets a test in `Tests/HeliumTests`. Run `swift test`.

## Commands

```sh
scripts/build-ghostty.sh               # libghostty (needs Zig 0.16.0); forces a SwiftPM relink
scripts/build-app.sh                   # build/Helium Terminal.app (SIGN_IDENTITY=... for Developer ID)
scripts/install-local.sh               # build and copy to /Applications (Spotlight/Raycast find it there)
swift test                             # unit tests
bench/final.sh                         # size, launch, memory, CPU, throughput
NOTARY_PROFILE=helium-notary scripts/release.sh   # test, build, sign, notarize, release, update the tap
```

Releasing: bump `VERSION`, add `packaging/notes/<version>.md`, commit, then run the release script.
