#!/bin/bash
# Helium vs iTerm2 without keystrokes: both launched in the background (open -g) with saved
# window state ignored, measured, then killed by exact PID. Don't run while iTerm2 is in use.
cd "$(dirname "$0")"
# Never let a benchmarked Helium restore or overwrite the owner's session or take their socket.
export HELIUM_STATE_FILE="${TMPDIR:-/tmp}/helium-bench-state.json" HELIUM_SOCKET="${TMPDIR:-/tmp}/helium-bench.sock"
rm -f "$HELIUM_STATE_FILE"
/usr/bin/pgrep -x iTerm2 >/dev/null && { echo "iTerm2 is running; quit it first" >&2; exit 1; }
fp() { footprint -p "$1" 2>/dev/null | awk '/Footprint:/ && !/Summary/{for(i=1;i<=NF;i++) if($i=="Footprint:") print $(i+1)}'; }
cpu() { ps -o time= -p "$1" | awk -F'[:.]' '{print $1*60+$2+$3/100}'; }
med() { tr ' ' '\n' | grep -v '^$' | sort -n | awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}'; }
# The process that wasn't in the "before" list (an empty list excludes nothing).
newpid() { local p; for p in $(/usr/bin/pgrep -f "$1"); do case " $2 " in *" $p "*) ;; *) echo $p; return;; esac; done; }
measure() { # name app-path process-pattern window-owner
  local name=$1 app=$2 pat=$3 owner=$4 L="" M="" p before c0 c1
  for i in 1 2 3 4 5; do
    before=$(/usr/bin/pgrep -f "$pat" | tr '\n' ' ')
    L="$L $(./winwait "$app" "$owner")"; sleep 6
    p=$(newpid "$pat" "$before")
    [ -n "$p" ] || { echo "could not find the $name test instance; stopping" >&2; exit 1; }
    M="$M $(fp $p)"; kill $p; sleep 2
  done
  before=$(/usr/bin/pgrep -f "$pat" | tr '\n' ' ')
  ./winwait "$app" "$owner" >/dev/null; sleep 10; p=$(newpid "$pat" "$before")
  [ -n "$p" ] || { echo "could not find the $name test instance; stopping" >&2; exit 1; }
  c0=$(cpu $p); sleep 30; c1=$(cpu $p)
  echo "$name bundle_mb=$(du -sm "$app" | cut -f1) launch_ms=$(echo $L | med) [$L ] idle_mb=$(echo $M | med) [$M ] idle_cpu=$(echo "($c1-$c0)/30*100" | bc -l | xargs printf '%.2f')%"
  kill $p; sleep 1
}
measure Helium "/Applications/Helium Terminal.app" "Helium Terminal.app/Contents/MacOS/helium-terminal$" "Helium Terminal"
measure iTerm2 /Applications/iTerm.app "iTerm.app/Contents/MacOS/iTerm2$" iTerm2
