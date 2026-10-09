#!/bin/bash
# Helium vs iTerm2 without keystrokes: both launched in the background (open -g) with saved
# window state ignored, measured, then killed by exact PID. Don't run while iTerm2 is in use.
cd "$(dirname "$0")"
# Never let a benchmarked Helium restore or overwrite the owner's session or take their socket.
export HELIUM_STATE_FILE="${TMPDIR:-/tmp}/helium-bench-state.json" HELIUM_SOCKET="${TMPDIR:-/tmp}/helium-bench.sock"
rm -f "$HELIUM_STATE_FILE"
/usr/bin/pgrep -f "iTerm.app/Contents/MacOS/iTerm2" >/dev/null && { echo "iTerm2 is running; quit it first" >&2; exit 1; }

LAUNCHED=""
# Whatever happens, close everything this script started (apps, iTerm2 session servers, their shells).
cleanup() {
  for p in $LAUNCHED; do
    for c in $(/usr/bin/pgrep -P $p); do /usr/bin/pkill -HUP -P $c 2>/dev/null; kill $c 2>/dev/null; done
    kill $p 2>/dev/null
  done
  sleep 1
  for p in $LAUNCHED; do /bin/ps -p $p >/dev/null 2>&1 && kill -9 $p; done
  rm -f "${TMPDIR:-/tmp}"/helium-bench*
}
trap cleanup EXIT

fp() { local a=(); for p in "$@"; do a+=(-p "$p"); done; footprint "${a[@]}" 2>/dev/null | awk '/Footprint:/ && !/Summary/{for(i=1;i<=NF;i++) if($i=="Footprint:"){v=$(i+1);u=$(i+2)}; if(u=="KB")v/=1024; s+=v} END{printf "%.0f", s}'; }
cpu() { ps -o time= -p "$1" | awk -F'[:.]' '{print $1*60+$2+$3/100}'; }
med() { tr ' ' '\n' | grep -v '^$' | sort -n | awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}'; }
# Processes matching $1 that weren't in the "before" list $2 (an empty list excludes nothing).
newpids() { local p; for p in $(/usr/bin/pgrep -f "$1"); do case " $2 " in *" $p "*) ;; *) echo $p;; esac; done; }
SERVER="Application Support/iTerm2/iTermServer"

launch() { # app owner pattern -> sets P (app pid) and S (new iTerm2 servers)
  local before=$(/usr/bin/pgrep -f "$3" | tr '\n' ' ') sbefore=$(/usr/bin/pgrep -f "$SERVER" | tr '\n' ' ')
  L="$L $(./winwait "$1" "$2")"
  sleep "$4"
  P=$(newpids "$3" "$before" | head -1)
  S=$(newpids "$SERVER" "$sbefore" | tr '\n' ' ')
  LAUNCHED="$LAUNCHED $P $S"
  [ -n "$P" ] || { echo "could not find the test instance of $1; stopping" >&2; exit 1; }
}
close() { for p in $P $S; do for c in $(/usr/bin/pgrep -P $p); do /usr/bin/pkill -HUP -P $c 2>/dev/null; kill $c 2>/dev/null; done; kill $p 2>/dev/null; done; sleep 2; }

measure() { # name app-path process-pattern window-owner
  local name=$1 app=$2 pat=$3 owner=$4 M="" c0 c1
  L=""
  for i in 1 2 3 4 5; do
    launch "$app" "$owner" "$pat" 6
    M="$M $(fp $P $S)"
    close
  done
  local launches="$L"
  launch "$app" "$owner" "$pat" 10
  c0=$(cpu $P); sleep 30; c1=$(cpu $P)
  echo "$name bundle_mb=$(du -sm "$app" | cut -f1) launch_ms=$(echo $launches | med) [$launches ] idle_mb=$(echo $M | med) [$M ] idle_cpu=$(echo "($c1-$c0)/30*100" | bc -l | xargs printf '%.2f')%"
  close
}
# With arguments: measure those Helium builds instead (e.g. an old build against the current one).
if [ $# -gt 0 ]; then
  for app in "$@"; do measure "$app" "$app" "$app/Contents/MacOS/helium-terminal" "Helium Terminal"; done
  exit 0
fi
measure Helium "/Applications/Helium Terminal.app" "Helium Terminal.app/Contents/MacOS/helium-terminal" "Helium Terminal"
measure iTerm2 /Applications/iTerm.app "iTerm.app/Contents/MacOS/iTerm2" iTerm2
