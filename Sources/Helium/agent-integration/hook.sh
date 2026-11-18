#!/bin/sh
# Helium Terminal agent integration. Inert outside Helium.
# Usage: hook.sh <kind>, as an agent hook's only command, with the hook's JSON (holding "session_id") on stdin.
# The hook command must exec this script directly so that the agent is $PPID.
[ -n "$HELIUM_PANE" ] && [ -n "$HELIUM_PANE_TOKEN" ] && [ -d "$HELIUM_AGENT_STATE_DIR" ] || exit 0
case "$1$HELIUM_PANE_TOKEN" in "" | *[!A-Za-z0-9-]*) exit 0 ;; esac
id=$(sed -n 's/.*"session_id" *: *"\([A-Za-z0-9_-]*\)".*/\1/p' | head -n 1)
[ -n "$id" ] || exit 0
f="$HELIUM_AGENT_STATE_DIR/$PPID.json"
printf '{"kind":"%s","sessionID":"%s","pid":%d,"token":"%s"}' "$1" "$id" "$PPID" "$HELIUM_PANE_TOKEN" >"$f.$$" &&
  mv -f "$f.$$" "$f" || rm -f "$f.$$"
exit 0
