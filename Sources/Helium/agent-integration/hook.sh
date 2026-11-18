#!/bin/sh
# Helium Terminal agent integration. Inert outside Helium.
# Usage: hook.sh <kind> [working|blocked|idle], as an agent hook's only command, with the hook's JSON (holding
# "session_id") on stdin.
# The hook command must exec this script directly so that the agent is $PPID.
[ -n "$HELIUM_PANE" ] && [ -n "$HELIUM_PANE_TOKEN" ] && [ -d "$HELIUM_AGENT_STATE_DIR" ] || exit 0
case "$1$2$HELIUM_PANE_TOKEN" in "" | *[!A-Za-z0-9-]*) exit 0 ;; esac
state=
[ -n "$2" ] && state=",\"state\":\"$2\""
id=$(sed -n 's/.*"session_id" *: *"\([A-Za-z0-9_-]*\)".*/\1/p' | head -n 1)
# No session_id (MiniMax's status line after /new, before the first prompt) means nothing to resume yet.
sid=null
[ -n "$id" ] && sid="\"$id\""
f="$HELIUM_AGENT_STATE_DIR/$PPID.json"
printf '{"kind":"%s","sessionID":%s%s,"pid":%d,"token":"%s"}' "$1" "$sid" "$state" "$PPID" "$HELIUM_PANE_TOKEN" >"$f.$$" &&
  mv -f "$f.$$" "$f" || rm -f "$f.$$"
exit 0
