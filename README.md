<p align="center">
  <img src="docs/logo.png" width="128" height="128" alt="Helium Terminal icon: a periodic-table tile reading He">
</p>

<h1 align="center">Helium Terminal</h1>

<p align="center">A small macOS terminal for running coding agents, built on libghostty. It's native Swift and AppKit, with no Electron.</p>

- A sidebar of vertical tabs showing the title, git branch, cwd, listening ports and the latest notification
- A blue ring on a pane, and a dot on its tab, when the pane needs attention
- Horizontal and vertical splits inside each tab
- A Unix socket API, plus the `helium` command-line tool
- Rendering by libghostty (Metal), configured by your existing Ghostty config (`~/.config/ghostty/config`)

![Helium Terminal: four tabs in the sidebar showing git branches, folders, listening ports and agent notifications; an agent transcript and a dev server in splits, with a blue notification ring on the dev server pane](docs/screenshot.png)

## Install

Apple Silicon, macOS 13 or later.

```sh
brew install --cask yowmamasita/tap/helium-terminal   # Homebrew: installs to /Applications
zb install yowmamasita/tap/helium-terminal            # zerobrew
```

Both also install the `helium` command. Run `helium` with no arguments to open the app.

## Build from source

Needs Xcode and Zig 0.16.0.

```sh
scripts/build-ghostty.sh   # libghostty -> vendor/ghostty/macos/GhosttyKit.xcframework
scripts/build-app.sh       # -> "build/Helium Terminal.app"
scripts/install-local.sh   # build and copy to /Applications, so Spotlight and Raycast find it
```

To release, bump `VERSION`, add `packaging/notes/<version>.md`, and run `NOTARY_PROFILE=<profile> scripts/release.sh`.
That script builds, signs, notarizes, publishes the GitHub release and updates the tap.

## Settings

⌘, opens Settings. The Terminal tab covers the common Ghostty options (font, theme, cursor, opacity, padding,
scrollback, Option as Alt, copy on select). Changes apply to open terminals right away and are saved to
`~/Library/Application Support/helium-terminal/config`, which loads after your Ghostty config, so Helium never
rewrites a config you share with Ghostty.app. The All Options tab lists every Ghostty option with its current
value and documentation; `helium +show-config --docs` prints the same from the command line.

## Tab titles and labels

Double-click a tab (or right-click > Rename Tab) to give it your own title; an empty title goes back to the automatic
one. Right-click > Labels adds Gmail-style colored labels: tick any number per tab, create one with New Label…
(name and one of 12 colors), or delete one everywhere. Titles and labels are kept across quit and relaunch, and
`helium list` reports each tab's labels.

## Tab groups

Like Chrome's: right-click a tab > Add Tab to New Group, then name it and pick a color. Click a group's header to
collapse or expand it; a collapsed group still shows if one of its tabs needs you. Right-click a header to rename
or recolor it, add a tab to it, ungroup it or close it. Closing the last tab of a group asks whether to delete the
group (with Don't Ask Again). Groups are kept across quit and relaunch.

## Session restore

Quit with ⌘Q and Helium reopens the same tabs and splits in the same folders next time. Panes that were running
Claude Code or Codex resume the same conversation: Helium types `claude --resume <id>` or `codex resume <id>` with
the flags the agent was started with (model, permission mode and so on), minus any initial prompt. Other programs
start fresh, because a process can't outlive the app. Closing the window instead of quitting starts clean next
time.

Settings, Helium tab, Session restore: turn restoring off, turn resuming off for Claude Code or Codex separately,
or change the resume command. Templates take `{id}`, `{flags}` and `{cwd}`; the defaults are
`claude {flags} --resume {id}` and `codex resume {id} {flags}`, so `cc --resume {id}` uses your own alias.

Helium finds Claude Code's session from `~/.claude/sessions/<pid>.json`, and Codex's from the session log the
running process keeps open. It saves the layout every few seconds and on quit to
`~/Library/Application Support/helium-terminal/state.json`.

## Updates

The app checks GitHub for a new release shortly after launch and then daily. It downloads the new version and
installs it only if it's signed by the same Apple developer and notarized. It replaces itself on disk without
interrupting your terminals, and the sidebar then shows a Relaunch button. Turn this off, or check now, in Settings.
Copies installed with zerobrew (or as a Homebrew formula) and development builds don't update themselves.

## Keys

Keys come from Ghostty's default keybinds (or your own Ghostty config): cmd+t new tab, cmd+d split right,
cmd+shift+d split down, cmd+w close, cmd+1..9 switch tab, cmd+[ / cmd+] previous/next split,
cmd+opt+arrows move between splits.

## Notifications

A pane gets a blue ring, and its tab a blue dot and the message, when a program sends a desktop notification
(OSC 9 or OSC 777), rings the bell, or runs `helium notify`. The blue ring clears when you focus the pane.

Claude Code's "Claude is waiting for your input" reminder, sent about a minute after a turn ends, shows as
"Done, waiting for you". When the message means an agent is blocked on you (Claude's "needs your permission",
Codex's "Approval requested" or "wants to edit", "needs input" and similar), the pane gets an orange ring and its tab an orange **needs input** badge
instead. It stays until you type into that pane. For Claude Code, add a hook:

```json
{ "hooks": { "Notification": [{ "hooks": [{ "type": "command", "command": "helium notify --title Claude \"needs input\"" }] }] } }
```

## CLI / socket API

```
helium list                                  tabs, panes and their metadata (JSON)
helium new-tab [--cwd DIR] [--command CMD]
helium select <tab>     helium focus <pane>
helium split [right|down] [--pane ID]
helium send [--pane ID] "make test\n"
helium notify [--pane ID] [--title T] <body>
helium close [--pane ID]
```

`--pane` defaults to `$HELIUM_PANE`, which is set in every pane. The socket is
`~/Library/Application Support/helium-terminal/helium.sock` (mode 0600). It takes one JSON object per line,
e.g. `{"cmd":"notify","pane":"3","arg":"done"}`.

## Performance (vs cmux 0.65.0, Apple Silicon, `bench/final.sh`)

| | Helium | cmux |
|---|---|---|
| App size | 12 MB | 745 MB |
| Launch until the window appears | ~290 ms | ~1,080 ms |
| Memory, focused window | 152 MB | 323 MB |
| Memory, background window | 58 MB | 319 MB |
| Idle CPU, focused (cursor blinking) | 0.5% | 3.3% |
| Idle CPU, background | 0.1% | 3.1% |

Output speed is the same, because both use libghostty: 50 MB of plain text takes 0.16 s, and 50 MB of
color-heavy output takes 0.43 s.

How it stays light:
- libghostty is built ReleaseFast without Sentry or translations, and patched for double buffering
  (`patches/`), so each visible pane holds one fewer full-window GPU surface.
- A surface counts as focused only in the key window, so a background window stops blinking and redrawing.
- Hidden tabs and covered or minimized windows stop rendering, and libghostty frees their GPU buffers.
- Metadata (branch, ports, cwd) comes from file reads and libproc every 3 s, with no subprocesses.

## Not included

Bundled Ghostty themes (put any you use in `~/.config/ghostty/themes`), keeping programs running across a quit, a browser pane, system notification banners, images on the clipboard, and
an Intel build.

## Credits

Keyboard, IME and mouse handling is adapted from Ghostty's macOS app (MIT, Mitchell Hashimoto and Ghostty contributors).
