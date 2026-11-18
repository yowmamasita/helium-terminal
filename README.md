<p align="center">
  <img src="docs/logo.png" width="128" height="128" alt="Helium Terminal icon: a periodic-table tile reading He">
</p>

<h1 align="center">Helium Terminal</h1>

<p align="center">A small macOS terminal for running coding agents, built on libghostty. It's native Swift and AppKit, with no Electron.</p>

<p align="center"><a href="https://helium-terminal.bensarmiento.com">helium-terminal.bensarmiento.com</a></p>

- A sidebar of vertical tabs showing the title, cwd and listening ports, with the selected tab's git branch,
  ahead/behind counts and uncommitted changes above the terminal
- A green ring on a pane, and a green edge on its tab, when the pane needs attention (the message is the tab's tooltip);
  a blinking orange edge when an agent is blocked on you, and a pulsing blue edge while Claude Code or Codex is working
- Horizontal and vertical splits inside each tab
- A Unix socket API, plus the `helium` command-line tool
- Rendering by libghostty (Metal), configured by your existing Ghostty config (`~/.config/ghostty/config`)

![Helium Terminal: a sidebar with an auth tab group, a collapsed docs group, colored labels, folders and a listening port. The tab where an agent is working has a pulsing blue edge, the tab waiting on the user blinks orange, and a finished deploy shows a green edge. Next to it, the agent's transcript, a dev server and a shell in split panes](docs/demo.webp)

## Install

Apple Silicon, macOS 13 or later.

```sh
brew install --cask yowmamasita/tap/helium-terminal   # Homebrew: installs to /Applications
zb install yowmamasita/tap/helium-terminal            # zerobrew
```

Both also install the `helium` command. Run `helium` with no arguments to open the app.

## Build from source

Needs Xcode and Zig 0.17.1.

```sh
scripts/build-ghostty.sh   # libghostty -> vendor/ghostty/macos/GhosttyKit.xcframework
scripts/build-app.sh       # -> "build/Helium Terminal.app"
scripts/install-local.sh   # build and copy to /Applications, so Spotlight and Raycast find it
```

To release, bump `VERSION`, add `packaging/notes/<version>.md`, and run `NOTARY_PROFILE=<profile> scripts/release.sh`.
That script builds, signs, notarizes, publishes the GitHub release and updates the tap.
The tap definitions are generated from `packaging/helium-terminal.cask.rb` and
`packaging/helium-terminal.formula.rb`. Change those templates, not just the tap, before publishing.

## Settings

⌘, opens Settings. The Terminal tab covers the common Ghostty options (font, theme, cursor, opacity, padding,
scrollback, Option as Alt, copy on select, trackpad and mouse wheel scroll speed). Changes apply to open terminals right away and are saved to
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

Quit with ⌘Q and Helium reopens the same tabs and splits in the same folders next time. Claude Code, Codex,
omp (the pi harness), Pi, OpenCode (V1 and V2), Kimi Code, MiniMax Code, ZCode, Cline, GitHub Copilot CLI,
Antigravity CLI (`agy`), Grok Build and Hermes Agent (`--tui` only) resume the conversation selected in each pane, including changes
made with their own session pickers. Compatible launch flags and configuration-directory overrides are
preserved; initial prompts and image attachments are not replayed. Other programs start in a fresh shell.
Closing the window instead of quitting starts clean next time.

An agent with no saved conversation reopens fresh. Missing previously saved history is not silently replaced
with a different conversation.

Settings > General > Session restore controls restoring, resuming each agent, and custom resume commands.
Templates take shell-quoted `{command}` (the original executable, including an interpreter when needed),
`{id}`, `{file}` (omp's or Pi's journal), `{flags}`, and `{cwd}`. Defaults:

- Claude Code: `{command} {flags} --resume {id}`
- Codex: `{command} resume {id} {flags}`
- omp: `{command} {flags} --resume {file}`
- Pi: `{command} {flags} --session {file}`
- OpenCode: `{command} {flags} --session {id}`
- Kimi Code: `{command} -S {id}`
- MiniMax Code: `{command} --session {id}`
- ZCode: `{command} --resume {id}`
- Cline: `{command} {flags} --id {id}`
- GitHub Copilot CLI: `{command} {flags} --session-id {id}`
- Antigravity CLI: `{command} {flags} --conversation={id}`
- Grok Build, Hermes Agent: `{command} {flags} --resume {id}`

Custom commands can still use shell functions or aliases, for example `cc --resume {id}`. The default
`{command}` avoids depending on the new shell's `PATH`. Only whitelisted, non-secret environment overrides
for configuration paths and profiles are saved, including `CODEX_HOME` and omp's agent/session directories.

Each pane's conversation comes from evidence that belongs to that pane's process, never from the newest
session in a folder, so two panes running the same agent in one folder keep their own conversations:

- Claude Code: `~/.claude/sessions/<pid>.json`.
- Codex: its title shows a shortened thread ID, which Helium resolves against native session metadata and
  loaded threads, including daemon-backed sessions, resuming only when exactly one full ID matches.
- omp and Pi: an extension reports the exact journal path (omp also has a per-TTY breadcrumb fallback when
  extensions are disabled). Pi writes its journal with the first message; until then it reopens fresh.
- OpenCode: a TUI plugin reports the selected route, rather than guessing from backend activity.
- Kimi Code: a `SessionStart` hook reports the session. Kimi Code, MiniMax Code, ZCode and Pi overwrite their
  own argument list, so their launch flags can't be read or replayed.
- MiniMax Code: its custom status-line command, which it runs at startup and on every session change. MiniMax has
  only one custom status command, so Helium doesn't install it over one of yours (Settings shows why).
- ZCode: a `SessionStart` process hook. ZCode's user hooks are off by default, so installing it turns
  `hooks.enabled` on, which also enables any other hooks in that file. After `/new` the previous session is kept
  until the first prompt creates the new one. Built from ZCode's source; there's no official standalone CLI
  download to try it against.
- Cline: the first pane runs its session in its own process (its `sessions.db` row carries the pid); later panes
  run theirs in Cline's shared hub, whose event log records which pane's process created each session. Both are
  Cline's internal, undocumented databases, read only and off the main thread. Hooks can't be used: in the hub
  they run with the first pane's environment. Resuming a session from Cline's `/history` inside a hub-hosted
  pane isn't recognized until the pane starts a new session.
- GitHub Copilot CLI: the session files the process holds open, and its own process log when `/new` leaves
  several open. A bare supervisor left by `/restart` is followed to the process that owns the session.
- Antigravity CLI: the conversation lock the process holds open, and its own log when several are open.
- Grok Build: `~/.grok/active_sessions.json`, which records the owning pid. After `/new` the most recently
  opened session is taken; a switch in Grok's agent dashboard isn't visible until another session is opened.
  Built from Grok's source; not yet tried against a signed-in Grok.
- Hermes Agent: in `--tui` mode, the session file the TUI keeps for its parent. The default line-mode CLI runs
  its sessions in a shared gateway process and keeps no per-pane record, so it isn't resumed. Built from
  Hermes' source; not yet tried against a running Hermes.

With restore enabled, Helium installs an omp/Pi extension loader, OpenCode TUI plugins (V1 in `tui.json`,
V2 as `plugins/helium-terminal/`), a Kimi Code hook (a `[[hooks]]` table appended to `config.toml`), MiniMax
Code's `tui.customStatusLine` (plus `custom-command` in `tui.statusLine`), and a ZCode hook in
`~/.zcode/cli/config.json`. The hooks run a small script Helium places beside each config. All are inert outside
Helium. It also adds `app-name` and `thread-id` to Codex's
`tui.terminal_title`, preserving other settings and components. Copilot, Antigravity, Grok, Hermes and Cline need
no changes. Codex's executable is not patched. Integration setup errors appear in Settings rather than
overwriting an unrecognized configuration.

## Updates

The app checks GitHub for a new release shortly after launch and then daily. It downloads the new version and
installs it only if it's signed by the same Apple developer and notarized. It replaces itself on disk without
interrupting your terminals, and the sidebar then shows a Relaunch button. Turn this off, or check now, in Settings.
Copies installed with zerobrew (or as a Homebrew formula) and development builds don't update themselves.

## Keys

Keys come from Ghostty's default keybinds (or your own Ghostty config): cmd+t new tab, cmd+d split right,
cmd+shift+d split down, cmd+w close, cmd+1..9 switch tab, cmd+[ / cmd+] previous/next split,
cmd+opt+arrows move between splits, cmd+shift+t reopen the last closed tab or group (resuming its agents).

## Notifications

A pane gets a green ring, and its tab a green right edge and the message as its tooltip, when a program sends a
desktop notification (OSC 9 or OSC 777), rings the bell, or runs `helium notify`. The green ring clears when you
focus the pane.

Claude Code's "Claude is waiting for your input" reminder, sent about a minute after a turn ends, shows as
"Done, waiting for you". When the message means an agent is blocked on you (Claude's "needs your permission",
Codex's "Approval requested" or "wants to edit", "needs input" and similar), the pane gets an orange ring and its tab an orange right edge
instead, and the edge blinks. It stays until you type into that pane. For Claude Code, add a hook:

```json
{ "hooks": { "Notification": [{ "hooks": [{ "type": "command", "command": "helium notify --title Claude \"needs input\"" }] }] } }
```

While Claude Code or Codex is working, its tab gets a pulsing blue right edge. Helium reads this from the spinner
both agents put at the start of the terminal title during a turn (Claude Code ◐◓◑◒, Codex a braille spinner), so
it needs no hook and no polling. The edges stay still when Reduce Motion is on. Settings > General sets all three colors.

## Working, waiting and done for other agents

Besides the title spinners and notifications above, Helium reads the signals each agent already sends:

- OSC 7501 (the Program Status Protocol): Copilot CLI, omp, OpenCode V2, MiniMax Code and Grok Build report
  working, blocked and done on their own; Pi and Antigravity CLI do once the terminal answers their query, which
  Helium does; Kimi Code does because panes set `PI_PROGRAM_STATUS=1`. Working shows the blue edge, blocked the
  orange one until the agent moves on, and done (or idle after working) the green one.
- OSC 9;4 progress (Copilot, Kimi Code, Grok Build): working for 15 s after each report, like Ghostty.
- Titles: Hermes Agent's TUI (⏳ working, ⚠ needs you, ✓ done) and Grok Build's "Action required".
- Helium's own integrations: OpenCode V1's plugin, ZCode's hooks (turn start, approval, stop) and Cline's
  session status.

Hermes Agent's default line-mode CLI sends nothing unless its `display.bell_on_complete` is turned on.

## Queued prompts

Queue a prompt for a coding agent while it's busy, and Helium sends it when the turn ends. Queue several and
they go one per turn. Press ⌘⇧M (Edit > Queue Prompt for Agent), right-click a tab, or run `helium queue`.
The pane shows its queue at the bottom right; click it to edit or cancel prompts. The tab shows the count.

Helium holds the queued prompts itself and pastes one into the agent once it's idle, so nothing depends on the
agent's own queue. A queued prompt is never typed into a shell, into a permission dialog or question, or into a
pane that isn't responding. It waits there, and the queue popover says why. Queues aren't saved across a quit.

| Agent | Sends |
|---|---|
| Claude Code (tested) | when idle (from its session status), at once if it's already idle |
| Codex 0.170 (tested) | when OSC 7501 reports idle, at once if already idle |
| Copilot CLI, omp, OpenCode V2, MiniMax Code, Grok Build, Pi, Antigravity CLI, Kimi Code | the same, from their OSC 7501 reports |
| Hermes Agent (`--tui`) | when its title shows ✓ |
| Older Codex, OpenCode V1, ZCode, Cline | after a turn Helium saw end; a prompt queued while idle waits for the next turn |
| Hermes Agent's line mode | only with Send Now: it reports no working state |
| Anything else (a shell, Maka, dsh, mini-SWE-agent) | not offered: Helium doesn't recognize an agent there |

Only the two rows marked tested were run end to end; the others follow from the signals each agent sends
(see below). An agent started through a wrapper that stays in the foreground (`script`, for example) gets no queue.

Agents that report OSC 9;4 progress (Copilot, Kimi Code, Grok Build) count as working for 15 s after the last
report, so their prompts can go out that much later.

## CLI / socket API

```
helium list                                  tabs, panes and their metadata (JSON)
helium new-tab [--cwd DIR] [--command CMD]
helium select <tab>     helium focus <pane>
helium split [right|down|left|up] [--pane ID] [--cwd DIR] [--command CMD]
helium key [--pane ID] esc down enter ctrl+c shift+tab   press keys by name
helium wait [--pane ID] [--timeout SECONDS]  block until the pane's agent is idle or blocked on you
helium clear [--pane ID]                     clear a pane's ring and waiting state
helium close-tab [--tab ID]
helium rename [--tab ID] ["API work"]        no title goes back to the automatic one
helium label [--tab ID] ["bug,urgent"]       set a tab's labels; none clears them
helium group [--tab ID] ["auth"]             put a tab in a group (made if new); no name removes it
helium send [--pane ID] "make test\n"
helium read [--pane ID] [--scrollback]       print a pane's screen, or its whole history
helium queue [--pane ID] ["run the tests"]    send after the agent's turn; no text opens the queue
helium unqueue [--pane ID] [N]               cancel queued prompt N, or all
helium notify [--pane ID] [--title T] <body>
helium close [--pane ID]
```

`--pane` defaults to `$HELIUM_PANE`, which is set in every pane. The socket is
`~/Library/Application Support/helium-terminal/helium.sock` (mode 0600). It takes one JSON object per line,
e.g. `{"cmd":"notify","pane":"3","arg":"done"}`.

## Performance (vs iTerm2 3.7, Apple Silicon, `bench/vs-iterm2.sh`)

| | Helium | iTerm2 |
|---|---|---|
| App size | 15 MB | 176 MB |
| Launch until the window appears | ~250 ms | ~570 ms |
| Idle memory, one terminal | 62 MB | 203 MB (app and its session server) |
| Idle CPU | 0.1 to 0.3% | 1.9 to 2.4% |

Medians of 5 background launches with fresh state, no keystrokes; CPU over 30 s idle. Idle CPU varies between
runs, so it's a range. When Helium's window is covered or minimized it stops rendering and frees its GPU buffers.

How it stays light:
- libghostty is built ReleaseFast without Sentry or translations, and patched for double buffering
  (`patches/`), so each visible pane holds one fewer full-window GPU surface.
- A surface counts as focused only in the key window, so a background window stops blinking and redrawing.
- Hidden tabs and covered or minimized windows stop rendering, and libghostty frees their GPU buffers.
- Metadata (branch, ports, cwd) comes from file reads and libproc every 3 s. The only subprocess is one
  `git status` (about 10 ms) for the selected tab, and only while the window is visible.

## Not included

Bundled Ghostty themes (put any you use in `~/.config/ghostty/themes`), keeping programs running across a quit, a browser pane, system notification banners, images on the clipboard, and
an Intel build.

## Credits

Keyboard, IME and mouse handling is adapted from Ghostty's macOS app (MIT, Mitchell Hashimoto and Ghostty contributors).
