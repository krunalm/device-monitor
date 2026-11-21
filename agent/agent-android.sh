#!/usr/bin/env bash
# Device Monitor Android collector, for Termux without root. A standalone enrollment supplies
# config beside this script.
# Built for low-end tablets: the loop reads /proc and /sys with bash builtins only, so a report
# costs one curl and one sleep process and the collector itself stays in a few MB of memory.
DIR="$(cd "$(dirname "$0")" && pwd)"
[ "$DM_REPORT_PIPE" != 1 ] && [ -f "$DIR/config" ] && . "$DIR/config"
[ -f "$DIR/settings" ] && . "$DIR/settings"   # INTERVAL and KEEP_AWAKE; kept across re-enrollment
case "$INTERVAL" in ''|*[!0-9]*) INTERVAL=5 ;; esac
INTERVAL=$((10#$INTERVAL)); [ "$INTERVAL" -lt 2 ] && INTERVAL=2; [ "$INTERVAL" -gt 20 ] && INTERVAL=20   # the hub marks a device offline after 30 s
if [ "$DM_REPORT_PIPE" != 1 ]; then
  [[ "$HUB" == https://* && -n "$DEVICE_ID" && "$TOKEN" =~ ^[A-Za-z0-9_-]{43}$ ]] || { echo 'Re-enroll with an HTTPS agent invitation' >&2; exit 1; }
fi
HUB="${HUB%/}"
R="${DM_SYSROOT:-}"   # tests point this at a fake /proc and /sys

# rd FILE: first line of FILE into $V without starting a process. Fails when the file is missing,
# empty or blocked (Android hides more of /proc and /sys from apps with every release).
rd() { V=; IFS= read -r V 2>/dev/null < "$1"; [ -n "$V" ]; }
esc() { V="${1//[\"\\]/}"; V="${V//[[:cntrl:]]/}"; }   # strip chars that would break JSON
dec() { D="$(($1 / 10)).$(($1 % 10))"; }               # tenths -> "12.3"
prop() { V=; command -v getprop >/dev/null 2>&1 && V="$(getprop "$1" 2>/dev/null)"; [ -n "$V" ]; }

# Only one collector per install: a boot script and a manual start must not double-report.
if [ "$DM_REPORT_PIPE" != 1 ]; then
  if rd "$DIR/agent.pid" && [ "$V" != "$$" ] && [[ "$V" =~ ^[0-9]+$ ]] && rd "/proc/$V/cmdline"; then
    case "$V" in *agent-android.sh*) exit 0 ;; esac
  fi
  echo "$$" > "$DIR/agent.pid"
  [ "$KEEP_AWAKE" = 1 ] && command -v termux-wake-lock >/dev/null 2>&1 && termux-wake-lock
fi

# ---- what this device is (read once) ----
MAKER=; MODEL=
prop ro.product.manufacturer && MAKER="$V"
prop ro.product.model && MODEL="$V"
case "${MODEL,,}" in "${MAKER,,}"*) HOST="$MODEL" ;; *) HOST="${MAKER^}${MAKER:+ }$MODEL" ;; esac
[ -z "$HOST" ] && HOST="Android device"
OS=Android; prop ro.build.version.release && OS="Android $V"
CPU_NAME=
if prop ro.soc.model; then CPU_NAME="$V"; prop ro.soc.manufacturer && CPU_NAME="$V $CPU_NAME"; fi
[ -z "$CPU_NAME" ] && while IFS=: read -r k v; do
  case "$k" in Hardware*) CPU_NAME="${v# }"; break ;; esac
done 2>/dev/null < "$R/proc/cpuinfo"
[ -z "$CPU_NAME" ] && prop ro.board.platform && CPU_NAME="$V"
[ -z "$CPU_NAME" ] && prop ro.hardware && CPU_NAME="$V"
[ -z "$CPU_NAME" ] && CPU_NAME="ARM processor"
esc "$HOST"; HOST="$V"; esc "$OS"; OS="$V"; esc "$CPU_NAME"; CPU_NAME="$V"

# Cores, with the clock range of each (for the load estimate below). Counted from sysfs, which
# also lists cores the kernel has switched off to save power.
THREADS=0; FMIN=(); FMAX=()
for c in "$R"/sys/devices/system/cpu/cpu[0-9]*; do
  [ -d "$c" ] || continue
  i="${c##*/cpu}"; case "$i" in *[!0-9]*) continue ;; esac
  rd "$c/cpufreq/cpuinfo_min_freq" && FMIN[i]="$V"
  rd "$c/cpufreq/cpuinfo_max_freq" && FMAX[i]="$V"
  [ "$i" -ge "$THREADS" ] && THREADS=$((i + 1))
done
[ "$THREADS" -eq 0 ] && while read -r k v; do [ "$k" = processor ] && THREADS=$((THREADS + 1)); done 2>/dev/null < "$R/proc/cpuinfo"
[ "$THREADS" -eq 0 ] && THREADS=1

# CPU temperature: the hottest CPU-like thermal zone. Zone names differ per chipset, and vendors
# report millidegrees, tenths or whole degrees. Sets T10 (tenths of a degree C).
norm_temp() {
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  if [ "$1" -gt 2000 ]; then T10=$(($1 / 100)); elif [ "$1" -gt 200 ]; then T10=$1; else T10=$(($1 * 10)); fi
  [ "$T10" -ge 50 ] && [ "$T10" -le 1300 ]
}
ZONES=()
for z in "$R"/sys/class/thermal/thermal_zone*; do
  rd "$z/type" || continue
  case "${V,,}" in *batt*|*charg*|*usb*|*skin*|*pa[-_]*|*xo*) continue ;; esac
  case "${V,,}" in *cpu*|*soc*|*tsens*|*apss*|*cluster*|*core*|exynos*)
    rd "$z/temp" && norm_temp "$V" && ZONES+=("$z/temp") ;;
  esac
  [ "${#ZONES[@]}" -ge 8 ] && break
done

# Battery (sysfs where Android still allows it, otherwise Termux:API about once a minute).
BAT=
for b in "$R"/sys/class/power_supply/battery "$R"/sys/class/power_supply/Battery "$R"/sys/class/power_supply/bms "$R"/sys/class/power_supply/*; do
  rd "$b/capacity" && { BAT="$b"; break; }
done
BAT_API=0; [ -z "$BAT" ] && command -v termux-battery-status >/dev/null 2>&1 && BAT_API=1
BAT_JSON=; BAT_T10=

GPU_FILE=; GPU_NAME=
for g in "kgsl/kgsl-3d0/gpu_busy_percentage Adreno" "misc/mali0/device/utilization Mali"; do
  rd "$R/sys/class/${g% *}" && { GPU_FILE="$R/sys/class/${g% *}"; GPU_NAME="${g#* }"; break; }
done

# ---- readers (all set globals; none starts a process) ----
declare -A PT PI CT CI   # /proc/stat totals and idle time per cpu line, previous and current
read_cpu() {   # fails on Android 8+, where /proc/stat is closed to apps
  local name a b c d e f g h rest n=0
  CT=(); CI=()
  while read -r name a b c d e f g h rest; do
    case "$name" in cpu*) ;; *) break ;; esac
    CI[$name]=$((d + e)); CT[$name]=$((a + b + c + d + e + f + g + h)); n=$((n + 1))
  done 2>/dev/null < "$R/proc/stat"
  [ "$n" -gt 0 ]
}
keep_cpu() { local k; PT=(); PI=(); for k in "${!CT[@]}"; do PT[$k]=${CT[$k]}; PI[$k]=${CI[$k]}; done; }
# u10 KEY: load of one /proc/stat line since the previous sample, in tenths of a percent.
u10() {
  U=0
  [ -n "${CT[$1]}" ] && [ -n "${PT[$1]}" ] || return 0
  local dt=$((${CT[$1]} - ${PT[$1]})) di=$((${CI[$1]} - ${PI[$1]}))
  [ "$dt" -gt 0 ] && U=$((1000 * (dt - di) / dt))
  [ "$U" -lt 0 ] && U=0
  [ "$U" -gt 1000 ] && U=1000
  return 0
}
# Clock speed per core. Also the fallback load figure: where /proc/stat is closed, how far each
# running core sits between its lowest and highest clock is the closest thing an app can read.
read_freq() {
  local i c cur sum=0 on=0 est=0 known=0
  MHZ=null; FREQ_CORES=; FREQ_U=
  for ((i = 0; i < THREADS; i++)); do
    c="$R/sys/devices/system/cpu/cpu$i"; cur=
    if rd "$c/online" && [ "$V" = 0 ]; then cur=off
    elif rd "$c/cpufreq/scaling_cur_freq"; then cur="$V"; fi
    U=0
    case "$cur" in
      off) known=$((known + 1)) ;;
      ''|*[!0-9]*) ;;
      *) sum=$((sum + cur)); on=$((on + 1))
         [ -z "${FMIN[i]}" ] && rd "$c/cpufreq/cpuinfo_min_freq" && FMIN[i]="$V"   # a core that was off at startup
         [ -z "${FMAX[i]}" ] && rd "$c/cpufreq/cpuinfo_max_freq" && FMAX[i]="$V"
         if [ -n "${FMIN[i]}" ] && [ -n "${FMAX[i]}" ] && [ "${FMAX[i]}" -gt "${FMIN[i]}" ]; then
           U=$((1000 * (cur - FMIN[i]) / (FMAX[i] - FMIN[i]))); [ "$U" -lt 0 ] && U=0; [ "$U" -gt 1000 ] && U=1000
           known=$((known + 1))
         fi ;;
    esac
    est=$((est + U)); dec "$U"; FREQ_CORES="$FREQ_CORES${FREQ_CORES:+,}$D"
  done
  [ "$on" -gt 0 ] && MHZ=$((sum / on / 1000))
  [ "$on" -gt 0 ] && [ "$known" -eq "$THREADS" ] && FREQ_U=$((est / THREADS))
}
read_mem() {
  local k v total= avail= free=0 buf=0 cached=0
  MEM=
  while read -r k v _; do
    case "$k" in MemTotal:) total=$v ;; MemAvailable:) avail=$v ;; MemFree:) free=$v ;; Buffers:) buf=$v ;; Cached:) cached=$v ;; SwapCached:) break ;; esac
  done 2>/dev/null < "$R/proc/meminfo"
  [ -n "$total" ] || return 1
  [ -n "$avail" ] || avail=$((free + buf + cached))   # kernels before 3.14
  MEM="\"total\":$((total * 1024)),\"used\":$(((total - avail) * 1024))"
}
read_net() {   # closed to apps on Android 10+
  local ifc rx tx d n=0
  RX=0; TX=0
  while IFS=' :' read -r ifc rx _ _ _ _ _ _ _ tx _; do
    case "$ifc" in ''|Inter-*|face|lo|dummy*|tun*|ifb*|sit*|ip6*|ip_vti*|bond*|p2p*) continue ;; esac
    case "$rx$tx" in ''|*[!0-9]*) continue ;; esac
    RX=$((RX + rx)); TX=$((TX + tx)); n=$((n + 1))
  done 2>/dev/null < "$R/proc/net/dev"
  [ "$n" -gt 0 ] && return 0
  for d in "$R"/sys/class/net/*; do
    case "${d##*/}" in lo|dummy*|tun*|ifb*|sit*|ip6*|ip_vti*|bond*|p2p*) continue ;; esac
    rd "$d/statistics/rx_bytes" || continue; rx="$V"
    rd "$d/statistics/tx_bytes" || continue
    RX=$((RX + rx)); TX=$((TX + V)); n=$((n + 1))
  done
  [ "$n" -gt 0 ]
}
read_disk() {   # whole flash devices only, not their partitions
  local name rd_s wr_s n=0
  DR=0; DW=0
  while read -r _ _ name _ _ rd_s _ _ _ wr_s _; do
    case "$name" in mmcblk[0-9]|mmcblk[0-9][0-9]|sd[a-z]|vd[a-z]) DR=$((DR + rd_s * 512)); DW=$((DW + wr_s * 512)); n=$((n + 1)) ;; esac
  done 2>/dev/null < "$R/proc/diskstats"
  [ "$n" -gt 0 ]
}
read_uptime() {
  local up s
  if IFS='. ' read -r up _ 2>/dev/null < "$R/proc/uptime" && [ -n "$up" ]; then UPTIME=$up; return; fi
  # No /proc/uptime: this shell's start time (clock ticks since boot) plus how long it has run.
  if [ -z "$BOOT_OFFSET" ]; then
    BOOT_OFFSET=0
    if rd /proc/self/stat; then s="${V##*) }"; set -- $s; [[ "${20}" =~ ^[0-9]+$ ]] && BOOT_OFFSET=$((${20} / 100)); fi
  fi
  UPTIME=$((BOOT_OFFSET + SECONDS)); [ "$UPTIME" -lt 0 ] && UPTIME=0
}
read_temp() {
  local z max=
  TEMP=null
  for z in "${ZONES[@]}"; do
    rd "$z" && norm_temp "$V" && { [ -z "$max" ] || [ "$T10" -gt "$max" ]; } && max=$T10
  done
  [ -n "$max" ] && { dec "$max"; TEMP=$D; }
}
read_battery() {
  local pct= state= temp= out
  BAT_T10=
  if [ -n "$BAT" ]; then
    rd "$BAT/capacity" && pct="$V"
    rd "$BAT/status" && state="${V,,}"
    rd "$BAT/temp" && temp="$V"
  elif [ "$BAT_API" = 1 ]; then
    # Termux:API answers slowly and hangs without its companion app, so: rarely, and with a timeout.
    out="$(timeout 6 termux-battery-status 2>/dev/null)" || { BAT_API=0; return; }
    [[ "$out" =~ \"percentage\":\ *([0-9]+) ]] && pct="${BASH_REMATCH[1]}"
    [[ "$out" =~ \"status\":\ *\"([A-Za-z_]+)\" ]] && state="${BASH_REMATCH[1],,}"
    [[ "$out" =~ \"temperature\":\ *([0-9]+)(\.([0-9]))? ]] && temp="${BASH_REMATCH[1]}${BASH_REMATCH[3]:-0}"
  fi
  case "$pct" in ''|*[!0-9]*) BAT_JSON=; return ;; esac
  [ "$pct" -gt 100 ] && pct=100
  case "$state" in charging|full) state=true ;; discharging|not\ charging|not_charging) state=false ;; *) state=null ;; esac
  BAT_JSON="\"battery\":{\"percent\":$pct,\"charging\":$state},"
  case "$temp" in ''|*[!0-9]*) ;; *) [ "$temp" -ge 50 ] && [ "$temp" -le 900 ] && BAT_T10=$temp ;; esac   # sysfs and the API both give tenths here
}
read_disks() {   # one df per mount, so only every 12th report
  local m name total used line
  DISKS=
  for m in "$HOME" /storage/[0-9A-F][0-9A-F][0-9A-F][0-9A-F]-[0-9A-F][0-9A-F][0-9A-F][0-9A-F]; do
    [ -d "$m" ] || continue
    total=; { read -r line; read -r _ total used _; } < <(df -kP "$m" 2>/dev/null)
    case "$total$used" in ''|*[!0-9]*) continue ;; esac
    [ "$total" -gt 0 ] || continue
    [ "$m" = "$HOME" ] && name=/data || name="SD card"
    DISKS="$DISKS${DISKS:+,}{\"name\":\"$name\",\"total\":$((total * 1024)),\"used\":$((used * 1024))}"
  done
}
now_ms() {
  if [ -n "$EPOCHREALTIME" ]; then local t="${EPOCHREALTIME/[.,]/}"; NOW=$((${t%???})); else NOW=$((SECONDS * 1000)); fi
}

HAVE_STAT=0; read_cpu && { HAVE_STAT=1; keep_cpu; }
HAVE_NET=0; read_net && { HAVE_NET=1; PRX=$RX; PTX=$TX; }
HAVE_IO=0; read_disk && { HAVE_IO=1; PDR=$DR; PDW=$DW; }
now_ms; PREV_MS=$NOW
N=0; FAILS=0
sleep "$INTERVAL"
while true; do
  # Exit with the app that started us (if any).
  if [ -n "$PARENT_PID" ] && ! kill -0 "$PARENT_PID" 2>/dev/null; then exit 0; fi
  now_ms; MS=$((NOW - PREV_MS)); PREV_MS=$NOW
  # After the tablet slept (or the clock jumped) the counters span the gap: report no rates for this sample.
  FRESH=1; { [ "$MS" -le 0 ] || [ "$MS" -gt $((INTERVAL * 3000 + 5000)) ]; } && FRESH=0

  read_freq
  USAGE=null; CORES=; SOURCE=
  if [ "$HAVE_STAT" = 1 ] && read_cpu; then
    if [ "$FRESH" = 1 ]; then
      u10 cpu; dec "$U"; USAGE=$D
      for ((i = 0; i < THREADS; i++)); do u10 "cpu$i"; dec "$U"; CORES="$CORES${CORES:+,}$D"; done
    fi
    keep_cpu
  elif [ -n "$FREQ_U" ]; then
    dec "$FREQ_U"; USAGE=$D; CORES=$FREQ_CORES; SOURCE=',"usageSource":"freq"'
  fi

  RATES=
  if [ "$HAVE_NET" = 1 ] && read_net; then
    [ "$FRESH" = 1 ] && [ "$RX" -ge "$PRX" ] && [ "$TX" -ge "$PTX" ] && RATES="\"net\":{\"rx\":$(((RX - PRX) * 1000 / MS)),\"tx\":$(((TX - PTX) * 1000 / MS))},"
    PRX=$RX; PTX=$TX
  fi
  if [ "$HAVE_IO" = 1 ] && read_disk; then
    [ "$FRESH" = 1 ] && [ "$DR" -ge "$PDR" ] && [ "$DW" -ge "$PDW" ] && RATES="$RATES\"diskIO\":{\"read\":$(((DR - PDR) * 1000 / MS)),\"write\":$(((DW - PDW) * 1000 / MS))},"
    PDR=$DR; PDW=$DW
  fi

  read_mem; read_uptime; read_temp
  if [ $((N % 12)) -eq 0 ]; then read_disks; fi
  if [ -n "$BAT" ] || { [ "$BAT_API" = 1 ] && [ $((N % 12)) -eq 0 ]; }; then read_battery; fi
  TEMPS=; [ -n "$BAT_JSON" ] && [ -n "$BAT_T10" ] && { dec "$BAT_T10"; TEMPS="{\"name\":\"Battery\",\"value\":$D}"; }
  GPUS=
  if [ -n "$GPU_FILE" ] && rd "$GPU_FILE"; then
    V="${V%%[!0-9]*}"; [ -n "$V" ] && [ "$V" -le 100 ] && GPUS="{\"name\":\"$GPU_NAME\",\"vendor\":\"${GPU_NAME,,}\",\"usage\":$V}"
  fi
  N=$((N + 1))

  BODY="{\"id\":\"${DEVICE_ID:-android}\",\"hostname\":\"$HOST\",\"platform\":\"android\",\"os\":\"$OS\",\"formFactor\":\"mobile\",\"uptime\":$UPTIME,\"cpu\":{\"name\":\"$CPU_NAME\",\"threads\":$THREADS,\"clockMHz\":$MHZ,\"temp\":$TEMP,\"usage\":$USAGE$SOURCE,\"cores\":[$CORES]},\"memory\":{$MEM},\"gpus\":[$GPUS],\"disks\":[$DISKS],$RATES$BAT_JSON\"temps\":[$TEMPS],\"ai\":null}"
  if [ "$DM_REPORT_PIPE" = 1 ]; then
    printf '%s\n' "$BODY"
  else
    printf '%s' "$BODY" | curl -q --proto '=https' -fsS -m 8 -H @/dev/fd/3 -H 'Content-Type: application/json' --data-binary @- "$HUB/api/report" 3<<<"Authorization: Bearer $TOKEN" >/dev/null 2>&1
  fi
  # While the hub can't be reached (out of Wi-Fi range, hub off) try every 30 s instead, to spare the battery.
  if [ $? -eq 0 ]; then FAILS=0; else FAILS=$((FAILS + 1)); fi
  [ "$FAILS" -ge 3 ] && sleep 25
  sleep "$INTERVAL"
done
