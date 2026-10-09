#!/bin/bash
# Helium vs cmux without keystrokes: both launched in the background (open -g).
# Measures bundle size, launch-to-window, idle memory and idle CPU for both;
# throughput and 11-terminal memory for Helium via its socket API.
cd "$(dirname "$0")"
fp() { footprint -p "$1" 2>/dev/null | awk '/Footprint:/ && !/Summary/{for(i=1;i<=NF;i++) if($i=="Footprint:") print $(i+1)}'; }
cpu() { ps -o time= -p "$1" | awk -F'[:.]' '{print $1*60+$2+$3/100}'; }
med() { tr ' ' '\n' | grep -v '^$' | sort -n | awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}'; }
measure() { # name app-path process-pattern
  local name=$1 app=$2 pat=$3 L="" M="" p c0 c1
  pkill -f "$pat"; sleep 1
  for i in 1 2 3 4 5; do
    L="$L $(./winwait "$app")"; sleep 6; p=$(pgrep -f "$pat"); M="$M $(fp $p)"; pkill -f "$pat"; sleep 1.5
  done
  ./winwait "$app" >/dev/null; sleep 8; p=$(pgrep -f "$pat"); c0=$(cpu $p); sleep 30; c1=$(cpu $p)
  echo "$name bundle_mb=$(du -sm "$app" | cut -f1) launch_ms=$(echo $L | med) [$L ] idle_mb=$(echo $M | med) idle_cpu=$(echo "($c1-$c0)/30*100" | bc -l | xargs printf '%.2f')%"
  pkill -f "$pat"; sleep 1
}
measure Helium "../build/Helium Terminal.app" "Helium Terminal.app/Contents/MacOS/helium-terminal$"
measure cmux /Applications/cmux.app "cmux.app/Contents/MacOS/cmux$"

H="../build/Helium Terminal.app/Contents/MacOS/helium-terminal"
./winwait "../build/Helium Terminal.app" >/dev/null; sleep 3
for f in big ansi; do T=""; for r in 1 2 3; do
  rm -f /tmp/hq; "$H" send "/usr/bin/time -p cat $PWD/results/$f.txt 2> /tmp/hq; clear\n" >/dev/null
  for _ in $(seq 240); do grep -q real /tmp/hq 2>/dev/null && break; sleep 0.25; done
  T="$T $(awk '/real/{print $2}' /tmp/hq)"; done; echo "Helium cat_50mb_$f s=$(echo $T | med) [$T ]"; done
for i in $(seq 10); do "$H" new-tab >/dev/null; sleep 0.3; done; sleep 8
echo "Helium mb_11_terminals=$(fp $(pgrep -f 'Helium Terminal.app/Contents/MacOS/helium-terminal$'))"
pkill -f "Helium Terminal.app/Contents/MacOS/helium-terminal$"
