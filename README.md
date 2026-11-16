# wov_detect

Detects whether the SOF WoV (Wake-on-Voice) capture PCM (default `hw:0,12`) delivers audio data. Use it to test keyword wake-up (e.g. "hi intel"). It supports repeated tests, counted as #1, #2, ..., and can optionally save the audio of every detection as a WAV file.

## Files

| File | Description |
|---|---|
| `wov_detect.sh` | Main script. Polls `/proc/asound/cardC/pcmDc/sub0/status` and treats an advancing `hw_ptr` as PCM data |
| `wov_open.c` | Small alsa-lib based program that opens and starts the WoV PCM so the DSP waits for the keyword. Can also dump the captured data to a raw file |
| `wov_open` | Binary built from `wov_open.c`. The script rebuilds it automatically if it is missing or older than the source |
| `wov_out/` | Default output directory. Each run creates a `<YYYYmmdd_HHMMSS>/` subdirectory |

## Requirements

- bash 5.x or newer (uses `EPOCHREALTIME`)
- `gcc` and `/usr/lib/x86_64-linux-gnu/libasound.so.2`, only needed to build `wov_open` (no alsa headers required)
- Access to `/dev/snd/*` (usually membership in the `audio` group)

## Quick start

```bash
cd ~/zpf/wov_detect
./wov_detect.sh            # interactive: asks whether to save WAV (default N) and log (default Y)
```

Say **"hi intel"** to the microphone. A detection looks like this:

```
[14:50:01.123] wov_open started (pid 12345), hw:0,12 RUNNING, DSP waiting for keyword
[14:50:05.456] >>> WoV PCM detected #1  hw:0,12 owner=12345(wov_open) hw_ptr=1600 rate=16000  (total: 1)
[14:50:07.500] <<< PCM #1 ended (captured_2.0s), frames=32000 (2.00s)
[14:50:07.700] re-arming hw:0,12 (detections so far: 1)
[14:50:07.900]     say "hi intel" again, or press Ctrl+C to stop (total: 1)
```

Press **Ctrl+C** to stop. The script prints the total count: `stopped, total detections: N`.

## Modes

### 1. Active mode `--open` (default)
1. The script starts `./wov_open` in the background. It opens and starts the PCM (state RUNNING), and the DSP waits for the keyword.
2. When the keyword is spoken, the DSP starts sending data and `hw_ptr` advances. This counts as one detection.
3. The script keeps capturing for `--capture` seconds (default 2s), ends the detection, then closes and reopens `wov_open` (re-arm) to wait for the next keyword.
4. `wov_open` is stopped automatically when the script exits (Ctrl+C, `--once`, `--timeout`, or an error).

> If the device is already in use by another process at startup (state is not closed), the script does not start `wov_open` and only watches passively.

### 2. Passive mode `--no-open`
The script never opens the device. It only reads the status file under `/proc`, and another program (e.g. arecord or an upper-layer application) opens the PCM. A detection ends when `hw_ptr` stops advancing for `--idle-timeout` seconds, or when the stream is stopped or closed. WAV saving is not available in this mode.

## Options

| Option | Default | Description |
|---|---|---|
| `-D, --device hw:C,D` | `hw:0,12` | Capture PCM to watch (`plughw:C,D` is also accepted) |
| `-i, --interval SEC` | `0.1` | Poll interval |
| `-t, --idle-timeout SEC` | `1.0` | A detection ends when `hw_ptr` does not advance for this long |
| `--once` | off | Exit after the first detection (exit code 0) |
| `--timeout SEC` | `0` (none) | With `--once`: exit with code 1 if nothing is detected within SEC seconds |
| `-v, --verbose` | off | Also print `hw_ptr` progress |
| `--open` / `--no-open` | `--open` | Active / passive mode |
| `-c, --capture SEC` | `2.0` | Active mode: keep capturing SEC seconds after a detection, then re-arm |
| `--wav` / `--no-wav` | ask, default No | Save every detection as a WAV file (active mode only) |
| `--log` / `--no-log` | ask, default Yes | Save the screen log to a file |
| `-o, --outdir DIR` | `wov_out/<start time>` | Output directory for WAV and log files |
| `-y, --yes` | off | Do not ask; use the defaults (no WAV, log on) unless set on the command line |
| `-h, --help` | | Show help |

Set the environment variable `WOV_OPEN=/path/to/bin` to use a different opener binary. When it is set, the script does not build `wov_open`.

## Output

```
wov_out/20251116_145000/
├── wov_detect.log     # screen log (--log)
├── wov_001.wav        # audio of detection #1 (--wav)
├── wov_002.wav
└── ...
```

WAV files are always written as **S16_LE, 16000 Hz, mono**, matching the `wov_open` defaults.

## Examples

```bash
# Repeated tests without prompts, save WAV and log
./wov_detect.sh -y --wav

# Automated test: wait up to 30s, exit 0 on detection, 1 on timeout
./wov_detect.sh -y --no-log --once --timeout 30; echo "rc=$?"

# Capture more audio after each wake-up (5 seconds)
./wov_detect.sh -y --wav -c 5

# Passive mode: another program opens the device, the script only watches
./wov_detect.sh -y --no-open -v

# Different device and output directory
./wov_detect.sh -D hw:0,13 -o /tmp/wov_test -y --wav
```

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Normal exit (Ctrl+C, or `--once` with a detection) |
| 1 | `--once --timeout` timed out with no detection |
| 2 | Bad arguments, missing device status file, failed to build `wov_open`, etc. |
| 3 | `wov_open` failed to start or exited unexpectedly (its output is logged with a `[wov_open]` prefix) |

## Using wov_open on its own

```bash
# Build (the script also does this automatically)
gcc -O2 -o wov_open wov_open.c /usr/lib/x86_64-linux-gnu/libasound.so.2

# Show the hardware parameters the device supports
./wov_open -D hw:0,12 -d

# Open the PCM, wait for the keyword, write the data to a raw file; Ctrl+C to stop
./wov_open -D hw:0,12 -r 16000 -c 1 -f S16_LE -o out.raw
```

Options: `-D` device, `-r` sample rate, `-c` channels, `-f` format (`S16_LE|S24_LE|S32_LE`), `-o` raw output file, `-d` print supported parameters and exit.

## Notes

- Each `wov_open` run writes a temporary log to `/tmp/wov_open.XXXXXX.log`, which is deleted on normal exit. It is only left behind if the script is killed abnormally (e.g. `kill -9`); you can delete it by hand.
- With `-D` pointing to another device, the WAV header is still written as 16 kHz, S16_LE, mono. If the device uses a different format, also update `raw_to_wav` in the script.
