#!/bin/bash
# Quick Helium-only measurement, no keystrokes: size, launch, idle memory, 50 MB cat via the socket API.
cd "$(dirname "$0")"
APP="../build/Helium Terminal.app"; H="$APP/Contents/MacOS/helium-terminal"; BIG=$PWD/results/big.txt
kill_app() { pkill -f "Helium Terminal.app/Contents/MacOS/helium-terminal$"; sleep 1; }
fp() { footprint -p "$1" 2>/dev/null | awk '/Footprint:/ && !/Summary/{for(i=1;i<=NF;i++) if($i=="Footprint:") print $(i+1)}'; }
kill_app
echo "bundle_mb $(du -sm "$APP" | cut -f1)  binary_mb $(du -sm "$H" | cut -f1)"
L=(); M=()
for i in 1 2 3 4 5; do
  L+=($(./winwait "$APP")); sleep 5
  M+=($(fp $(pgrep -f "Helium Terminal.app/Contents/MacOS/helium-terminal$"))); kill_app
done
echo "launch_ms ${L[*]}"; echo "idle_mb ${M[*]}"
./winwait "$APP" >/dev/null; sleep 3
T=()
for r in 1 2 3; do
  rm -f /tmp/hq-$r; "$H" send "/usr/bin/time -p cat $BIG 2> /tmp/hq-$r; clear\n" >/dev/null
  for _ in $(seq 120); do grep -q real /tmp/hq-$r 2>/dev/null && break; sleep 0.25; done
  T+=($(awk '/real/{print $2}' /tmp/hq-$r))
done
echo "cat_50mb_s ${T[*]}"
P=$(pgrep -f "Helium Terminal.app/Contents/MacOS/helium-terminal$"); c0=$(ps -o time= -p $P | awk -F'[:.]' '{print $1*60+$2+$3/100}'); sleep 20; c1=$(ps -o time= -p $P | awk -F'[:.]' '{print $1*60+$2+$3/100}')
echo "idle_cpu_pct $(echo "($c1-$c0)/20*100" | bc -l | xargs printf '%.2f')"
kill_app
