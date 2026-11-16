#!/usr/bin/env bash
# wov_detect.sh - passively detect PCM output on the SOF WoV capture PCM.
#
# The script never opens or reads the PCM device. SOF / the owning process
# opens and triggers the interface (default hw:0,12). This script only polls
#   /proc/asound/cardC/pcmDc/sub0/status
# and reports when the stream starts delivering PCM data (hw_ptr advancing).
# When the data stops (stream stopped/closed, or hw_ptr idle for
# --idle-timeout seconds) it re-arms and waits for the next keyword, so
# repeated tests are counted as #1, #2, ...
#
# By default (--open) the script starts ./wov_open (alsa-lib based opener,
# see wov_open.c) in the background so the WoV stream is opened/started.
# After each detection it keeps capturing for --capture seconds, counts the
# detection, then restarts wov_open so the DSP is re-armed for the next
# keyword. wov_open is stopped on exit (Ctrl+C, --once, --timeout, error).
# Use --no-open for the old passive behaviour.

set -u

device="hw:0,12"
interval="0.1"
idle_timeout="1.0"
once=0
timeout=0
verbose=0
open_dev=1
save_wav=""      # ""=ask, 0/1
save_log=""      # ""=ask, 0/1
assume_yes=0
outdir=""
session_dir=""
logfile=""
capture="2.0"
cur_save=""
det_t=0
ev_frames=0
opener_pid=""
opener_log=""

usage() {
    cat <<USAGE
Usage: $0 [options]
  -D, --device hw:C,D      capture PCM to watch                  (default: $device)
  -i, --interval SEC       poll interval                         (default: $interval)
  -t, --idle-timeout SEC   hw_ptr idle time that ends a detection (default: $idle_timeout)
      --once               exit 0 after the first detection
      --timeout SEC        with --once: exit 1 after SEC seconds without detection
  -v, --verbose            also print hw_ptr progress
      --open               (default) start ./wov_open in background to open/start
                           the PCM, re-armed after every detection, stopped on exit
                           (env WOV_OPEN overrides path)
      --no-open            passive mode: only watch, never open the device
  -c, --capture SEC        with --open: capture SEC after a detection, then re-arm
                                                                  (default: $capture)
      --wav | --no-wav     save every detection as WAV (default: ask, answer No)
      --log | --no-log     save screen log to a file    (default: ask, answer Yes)
  -o, --outdir DIR         output dir for wav/log  (default: <script dir>/wov_out/<start time>)
  -y, --yes                don't ask, use defaults (no wav, log on) unless set above
  -h, --help
USAGE
}

die() { echo "error: $*" >&2; [[ -n ${logfile:-} ]] && echo "error: $*" >> "$logfile"; exit 2; }

while (( $# )); do
    case $1 in
    -D|--device)       device=${2:?missing value}; shift 2 ;;
    -i|--interval)     interval=${2:?missing value}; shift 2 ;;
    -t|--idle-timeout) idle_timeout=${2:?missing value}; shift 2 ;;
    --once)            once=1; shift ;;
    --timeout)         timeout=${2:?missing value}; shift 2 ;;
    -v|--verbose)      verbose=1; shift ;;
    --open)            open_dev=1; shift ;;
    --no-open)         open_dev=0; shift ;;
    -c|--capture)      capture=${2:?missing value}; shift 2 ;;
    --wav)             save_wav=1; shift ;;
    --no-wav)          save_wav=0; shift ;;
    --log)             save_log=1; shift ;;
    --no-log)          save_log=0; shift ;;
    -o|--outdir)       outdir=${2:?missing value}; shift 2 ;;
    -y|--yes)          assume_yes=1; shift ;;
    -h|--help)         usage; exit 0 ;;
    *)                 usage >&2; exit 2 ;;
    esac
done

[[ $device =~ ^(plug)?hw:([0-9]+),([0-9]+)$ ]] || die "unsupported device: $device (expected hw:C,D)"
card=${BASH_REMATCH[2]}
pcm=${BASH_REMATCH[3]}
pcm_dir=/proc/asound/card$card/pcm${pcm}c
status_file=$pcm_dir/sub0/status
[[ -r $status_file ]] || die "$status_file not found"

to_us() { awk -v s="$1" "BEGIN { printf \"%d\", s * 1000000 }"; }
idle_us=$(to_us "$idle_timeout")
timeout_us=$(to_us "$timeout")
capture_us=$(to_us "$capture")

now_us() {
    if [[ -n ${EPOCHREALTIME:-} ]]; then
        local t=${EPOCHREALTIME/,/.}
        NOW=$(( ${t%.*} * 1000000 + 10#${t#*.} ))
    else
        NOW=$(date +%s%6N)
    fi
}

log() {
    local t=${EPOCHREALTIME/,/.} f line; f=${t#*.}
    printf -v line "[%(%H:%M:%S)T.%s] %s" "${t%.*}" "${f:0:3}" "$*"
    printf '%s\n' "$line"
    [[ -n $logfile ]] && printf '%s\n' "$line" >> "$logfile"
    return 0
}
owner_desc() {
    local comm=""
    [[ -n $owner && -r /proc/$owner/comm ]] && comm=$(< "/proc/$owner/comm")
    echo "owner=${owner:-?}${comm:+($comm)}"
}

# Parse "key   : value" lines of the ALSA status file.
snapshot() {
    local line k v
    state=missing owner="" trig="" hw_ptr=0
    [[ -r $status_file ]] || return
    while IFS= read -r line; do
        if [[ $line == closed ]]; then state=closed; return; fi
        [[ $line == *:* ]] || continue
        k=${line%%:*}; k=${k//[[:space:]]/}
        v=${line#*:};  v=${v//[[:space:]]/}
        case $k in
        state)        state=$v ;;
        owner_pid)    owner=$v ;;
        trigger_time) trig=$v ;;
        hw_ptr)       hw_ptr=$v ;;
        esac
    done < "$status_file"
    [[ $hw_ptr =~ ^[0-9]+$ ]] || hw_ptr=0
}

rate=0
get_rate() {
    local k v
    rate=0
    while IFS=": " read -r k v _; do
        [[ $k == rate ]] && { rate=$v; break; }
    done < "$pcm_dir/sub0/hw_params" 2>/dev/null
    [[ $rate =~ ^[0-9]+$ ]] || rate=0
}

count=0
active=0
stream_id=""
last_ptr=0
last_change=0
ev_ptr0=0
prev_state=""

detect() {   # $1 = hw_ptr before the data started
    count=$((count + 1)); active=1; ev_ptr0=$1; det_t=$NOW
    ev_frames=$(( hw_ptr - $1 ))
    get_rate
    log ">>> WoV PCM detected #$count  $device $(owner_desc) hw_ptr=$hw_ptr rate=$rate  (total: $count)"
    log "    (press Ctrl+C to stop)"
    if (( once )) && [[ -z $opener_pid ]]; then exit 0; fi
}

end_event() {
    local frames=$ev_frames secs=""
    (( rate > 0 )) && secs=$(awk -v f="$frames" -v r="$rate" "BEGIN { printf \" (%.2fs audio)\", f / r }")
    active=0
    if [[ -n $opener_pid ]]; then
        log "<<< PCM #$count ended ($1), frames=$frames$secs"
        if (( once )); then exit 0; fi
        rearm
    else
        log "<<< PCM #$count ended ($1), frames=$frames$secs -> re-armed, waiting for keyword"
    fi
}

summary() { echo; log "stopped, total detections: $count"; exit 0; }
trap summary INT TERM

# ---------- optional opener (wov_open) ----------
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

opener_running() { [[ -n $opener_pid ]] && kill -0 "$opener_pid" 2>/dev/null; }

stop_opener() {   # $1 = quiet
    if opener_running; then
        kill -INT "$opener_pid" 2>/dev/null
        local i
        for (( i = 0; i < 20; i++ )); do opener_running || break; sleep 0.05; done
        opener_running && kill -KILL "$opener_pid" 2>/dev/null
        wait "$opener_pid" 2>/dev/null
        [[ -n ${1:-} ]] || log "wov_open (pid $opener_pid) stopped"
    fi
    opener_pid=""
    [[ -n $opener_log ]] && rm -f "$opener_log"
    opener_log=""
}

le32() { printf '\\x%02x\\x%02x\\x%02x\\x%02x' $(( $1 & 255 )) $(( $1 >> 8 & 255 )) $(( $1 >> 16 & 255 )) $(( $1 >> 24 & 255 )); }
le16() { printf '\\x%02x\\x%02x' $(( $1 & 255 )) $(( $1 >> 8 & 255 )); }

raw_to_wav() {   # $1 raw (S16_LE 16000Hz mono)  $2 wav
    local n rate=16000 ch=1 bits=16
    n=$(stat -c %s "$1") || return 1
    { printf '%b' "RIFF$(le32 $(( 36 + n )))WAVEfmt $(le32 16)$(le16 1)$(le16 $ch)$(le32 $rate)$(le32 $(( rate * ch * bits / 8 )))$(le16 $(( ch * bits / 8 )))$(le16 $bits)data$(le32 "$n")"
      cat "$1"; } > "$2"
}

finalize_save() {   # turn the raw file of the last wov_open run into a wav
    local raw=$cur_save wav
    cur_save=""
    [[ -n $raw && -f $raw ]] || return 0
    if [[ ! -s $raw ]]; then rm -f "$raw"; return 0; fi
    wav=${raw%.raw}.wav
    if raw_to_wav "$raw" "$wav"; then
        rm -f "$raw"
        log "    saved $wav ($(( ($(stat -c %s "$wav") - 44) / 32000 )).$(( ($(stat -c %s "$wav") - 44) % 32000 / 3200 ))s)"
    else
        log "    warning: failed to write $wav, raw kept: $raw"
    fi
}

cleanup() {
    stop_opener
    finalize_save
    [[ -n $logfile ]] && echo "log saved: $logfile"
}
trap cleanup EXIT

opener_fail() {
    log "error: wov_open failed: $1"
    if [[ -s $opener_log ]]; then
        local l; while IFS= read -r l; do log "    [wov_open] $l"; done < "$opener_log"
    fi
    exit 3
}

start_opener() {
    local bin=${WOV_OPEN:-$script_dir/wov_open} src=$script_dir/wov_open.c i
    if [[ -f $src && ( ! -x $bin || $src -nt $bin ) && -z ${WOV_OPEN:-} ]]; then
        log "building $bin from $src"
        gcc -O2 -o "$bin" "$src" /usr/lib/x86_64-linux-gnu/libasound.so.2 || die "failed to build wov_open"
    fi
    [[ -x $bin ]] || die "wov_open not found ($bin); build it from wov_open.c or set WOV_OPEN"

    snapshot
    if [[ $state != closed ]]; then
        log "device already in use ($state, $(owner_desc)), not starting wov_open (passive mode)"
        return
    fi

    cur_save=""
    if (( save_wav )); then
        cur_save=$(printf '%s/wov_%03d.raw' "$session_dir" $(( count + 1 )))
    fi
    opener_log=$(mktemp /tmp/wov_open.XXXXXX.log)
    "$bin" -D "hw:$card,$pcm" ${cur_save:+-o "$cur_save"} >"$opener_log" 2>&1 &
    opener_pid=$!
    for (( i = 0; i < 30; i++ )); do      # wait up to 3s for RUNNING
        sleep 0.1
        opener_running || opener_fail "exited during startup"
        snapshot
        [[ $state == RUNNING && $owner == "$opener_pid" ]] && break
    done
    [[ $state == RUNNING ]] || opener_fail "stream did not reach RUNNING (state=$state)"
    log "wov_open started (pid $opener_pid), $device RUNNING, DSP waiting for keyword"
}

rearm() {   # close the stream and open it again so the DSP waits for the next keyword
    local i
    stop_opener quiet
    finalize_save
    for (( i = 0; i < 40; i++ )); do snapshot; [[ $state == closed ]] && break; sleep 0.05; done
    log "re-arming $device (detections so far: $count)"
    start_opener
    log "    say \"hi intel\" again, or press Ctrl+C to stop (total: $count)"
    prev_state=RUNNING
    stream_id="$owner|$trig"; last_ptr=$hw_ptr; last_change=$NOW
}

# ---------- startup options: wav / log ----------
ask_yn() {   # $1 question  $2 default(0/1) -> echo 0/1
    local a def=$2 hint
    (( def )) && hint="[Y/n]" || hint="[y/N]"
    read -r -p "$1 $hint " a || a=""
    case ${a,,} in y|yes) echo 1 ;; n|no) echo 0 ;; *) echo "$def" ;; esac
}
if (( open_dev )); then
    if [[ -z $save_wav ]]; then
        if (( ! assume_yes )) && [[ -t 0 ]]; then save_wav=$(ask_yn "Save a WAV file for every detection?" 0); else save_wav=0; fi
    fi
else
    save_wav=0
fi
if [[ -z $save_log ]]; then
    if (( ! assume_yes )) && [[ -t 0 ]]; then save_log=$(ask_yn "Save log to a file?" 1); else save_log=1; fi
fi
if (( save_wav || save_log )); then
    session_dir=${outdir:-$script_dir/wov_out/$(date +%Y%m%d_%H%M%S)}
    mkdir -p "$session_dir" || die "cannot create $session_dir"
    (( save_log )) && logfile=$session_dir/wov_detect.log
fi
log "options: wav=$( (( save_wav )) && echo "yes ($session_dir/wov_NNN.wav)" || echo no )  log=$( (( save_log )) && echo "yes ($logfile)" || echo no )"
log "press Ctrl+C at any time to stop"

now_us; t0=$NOW
log "watching $device ($status_file) interval=${interval}s idle-timeout=${idle_timeout}s"
if (( open_dev )); then
    start_opener
    log "waiting for keyword / PCM output"
else
    log "passive mode: waiting for PCM output (script does not open the device)"
fi

while :; do
    if [[ -n $opener_pid ]] && ! opener_running; then
        opener_fail "exited unexpectedly"
    fi
    snapshot
    now_us

    if [[ $state != "$prev_state" ]]; then
        extra=""
        [[ $state == closed || $state == missing ]] || extra=" $(owner_desc)"
        log "pcm state: ${prev_state:-start} -> $state$extra"
        prev_state=$state
    fi

    if [[ $state == RUNNING ]]; then
        id="$owner|$trig"
        if [[ $id != "$stream_id" ]]; then
            # new stream or re-trigger; hw_ptr restarts from 0 after prepare
            (( active )) && end_event "stream_retriggered"
            stream_id=$id; last_ptr=$hw_ptr; last_change=$NOW
            (( verbose )) && log "new stream $(owner_desc) trigger_time=$trig hw_ptr=$hw_ptr"
            (( hw_ptr > 0 )) && detect 0
        elif (( hw_ptr != last_ptr )); then
            (( verbose )) && log "hw_ptr $last_ptr -> $hw_ptr (+$(( hw_ptr - last_ptr )))"
            if (( active )); then
                (( hw_ptr > last_ptr )) && ev_frames=$(( ev_frames + hw_ptr - last_ptr )) \
                                        || ev_frames=$(( ev_frames + hw_ptr ))   # boundary wrap
            else
                detect "$last_ptr"
            fi
            last_ptr=$hw_ptr; last_change=$NOW
            if (( active )) && [[ -n $opener_pid ]] && (( NOW - det_t >= capture_us )); then
                end_event "captured_${capture}s"
            fi
        elif (( active && NOW - last_change >= idle_us )); then
            end_event "no_data_for_${idle_timeout}s"
        fi
    else
        (( active )) && end_event "stream_$state"
        stream_id=""
    fi

    if (( once && timeout_us > 0 && NOW - t0 >= timeout_us )); then
        log "timeout, no PCM detected"; exit 1
    fi
    sleep "$interval"
done
