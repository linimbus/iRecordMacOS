---
name: irecord-headless
description: Record the macOS screen, a single window, or a region with the irecord CLI. Use for screen capture tasks from an LLM agent, including permission checks, target discovery, synchronous or background recordings, pause/resume/stop, JSON output parsing, and error recovery.
---

# iRecord Headless Mode Skill

Use this skill when a task requires capturing macOS screen content as a video or GIF and you can run shell commands on the Mac. `irecord` is a fully headless CLI: it does not need the iRecord GUI to be running.

## Golden rules

1. **Always pass `--json`.** stdout then contains exactly one JSON object and nothing else. Progress and diagnostics go to stderr.
2. **Start with `irecord doctor --json`.** Check `ready`, `screenPermission`, `microphonePermission`, `outputWritable`, and `activeSession`.
3. **Never invent a window id.** Run `irecord targets --json` immediately before a window recording, or use `--app` / `--title`.
4. **Know how the recording ends.** Use `--duration N` for unattended work. Use `start` + `stop` only when the duration is genuinely unknown.
5. **Keep recordings short** unless the user asked for a long capture. A 5–15 second clip is usually enough to demonstrate a UI flow.
6. **Never record without consent.** Screen content may contain private information. Follow the user's requested scope and save location.
7. **Check the result.** Treat the command as successful only when `ok == true` and the `output` file exists.

## Preflight

```bash
irecord doctor --json
```

Key fields:

```json
{
  "ok": true,
  "ready": true,
  "version": "1.0.0",
  "screenPermission": true,
  "microphonePermission": "authorized",
  "outputDirectory": "/Users/me/Movies/iRecord",
  "outputWritable": true,
  "issues": [],
  "activeSession": null,
  "formats": ["mp4-h264", "mp4-hevc", "mov-h264", "mov-hevc", "mov-prores", "gif"]
}
```

If `ready` is false, fix `issues` first. Missing permissions require the human to enable the **process that runs `irecord`** (Terminal, iTerm, IDE, or automation host) in System Settings → Privacy & Security → Screen Recording. Do not loop on retries.

## Discover targets

```bash
irecord targets --json
```

```json
{
  "ok": true,
  "displays": [
    {"id": 1, "width": 3024, "height": 1964, "point_width": 1512, "point_height": 982, "scale": 2, "main": true}
  ],
  "windows": [
    {"id": 12345, "app": "Safari", "title": "Example", "bundle_id": "com.apple.Safari", "width": 1200, "height": 800, "on_screen": true}
  ],
  "region_coordinates": "display-local points, top-left origin: x,y,width,height"
}
```

- Displays are numbered by `id`. Full-screen and region capture use `--display <id>` (or `main`).
- Window ids are ephemeral. Either resolve and record quickly, or use `--app` and `--title` so `irecord` resolves the window itself.
- Region coordinates are **display-local logical points**, not global screen coordinates and not pixels, with a **top-left origin**.

## Record synchronously (preferred)

```bash
irecord record --mode screen --duration 8 --output demo.mp4 --json
```

```json
{
  "ok": true,
  "output": "/Users/me/demo.mp4",
  "format": "mp4-h264",
  "duration": 8.02,
  "width": 3024,
  "height": 1964,
  "fileSize": 5242880,
  "audio": true
}
```

Examples:

```bash
# Window by application and title
irecord record --mode window --app "Safari" --title "Example" \
  --duration 6 --audio system --json

# Window by id, with microphone and click highlights
irecord record --mode window --window 12345 --duration 5 \
  --audio both --mouse-clicks --json

# Region on display 1 (top-left points)
irecord record --mode region --display 1 --region 100,200,800,600 \
  --duration 6 --json

# High frame rate HEVC
irecord record --mode screen --duration 10 --format mp4-hevc --fps 60 --json

# Silent GIF, 720 px wide, 12 fps
irecord record --mode screen --duration 4 --format gif \
  --gif-width 720 --gif-fps 12 --json

# Explicit output folder
irecord record --mode screen --duration 5 --output ~/Desktop/captures/ --json
```

### Options

| Option | Values / default | Notes |
| --- | --- | --- |
| `--mode` | `screen` (default), `window`, `region` | Inferred when `--window`/`--app`/`--title` or `--region` is present |
| `--display` | `main` or numeric id | Screen and region captures |
| `--window`, `--window-id` | numeric id | From `targets` |
| `--app` | name or bundle id | Case-insensitive match |
| `--title` | substring | Combined with `--app` |
| `--region` | `x,y,w,h` | Display-local points, top-left |
| `--format` | `mp4-h264` (default), `mp4-hevc`, `mov-h264`, `mov-hevc`, `mov-prores`, `gif` | GIF is silent |
| `--fps` | 5–120, default 30 | |
| `--quality` | `low`, `medium`, `high` | Default follows shared settings |
| `--scale` | 0.25–1.0, default 1.0 | Output downscale |
| `--audio` | `none`, `system`, `microphone`, `both` | `--no-audio` also works. Window capture only records the captured app's audio; screen/region records all system audio. Microphone is captured with AVAudioEngine; with `both` the file has a mic track followed by a system-audio track. |
| `--cursor` / `--no-cursor` | cursor shown by default | |
| `--mouse-clicks` / `--no-mouse-clicks` | highlights on by default | System-drawn click rings |
| `--gif-width`, `--gif-fps` | 720, 12 | GIF only |
| `--output` | file or folder | Extension must match the format when present |
| `--overwrite` | flag | Required when the file exists |
| `--duration` | seconds | 0 or omitted means until `Ctrl+C` |
| `--json` | flag | Single JSON object on stdout |
| `--quiet`, `--verbose` | flags | stderr verbosity |

## Background sessions

Use when the end time is not known in advance.

```bash
irecord start --mode screen --output session.mp4 --json
```

```json
{
  "ok": true,
  "session": "a1b2c3d4e5",
  "pid": 4242,
  "state": "recording",
  "outputPath": "/Users/me/session.mp4",
  "controls": ["pause", "resume", "stop", "status", "cancel"],
  "hint": "Use `irecord stop --session a1b2c3d4e5 --json` to finish."
}
```

Then:

```bash
irecord status --session <id> --json
irecord pause  --session <id> --json
irecord resume --session <id> --json
irecord stop   --session <id> --json
```

- If `--session` is omitted, the most recent active session is used.
- `stop` sends the stop request and polls the session file until it reaches `completed`, `failed`, or `cancelled`.
- The default stop timeout is 300 seconds. Pass `--timeout 600` for long GIF conversions.
- `pause`/`resume` are best-effort: the command returns the intended state immediately; the daemon applies it to the capture stream.
- Sessions are stored as JSON in `~/Library/Application Support/iRecord/sessions/`.
- Only one background session can run at a time.

A background session may finish on its own: `start --duration 30` auto-stops after 30 seconds. Afterwards `status` works on the persisted record.

## JSON contract

Success (`record`):

```json
{"ok": true, "output": "<absolute path>", "format": "<format id>", "duration": 8.0, "width": 1920, "height": 1080, "fileSize": 1234567, "audio": true}
```

Failure:

```json
{"ok": false, "error": "<human message>", "code": "<machine code>", "hint": "<optional next step>"}
```

Status / stop:

```json
{
  "ok": true,
  "session": "a1b2c3d4e5",
  "state": "completed",
  "mode": "window",
  "target": "Safari — Example",
  "outputPath": "/Users/me/session.mp4",
  "elapsed": 12.4,
  "result": {"output": "...", "format": "mp4-h264", "duration": 12.4, "width": 1920, "height": 1080, "fileSize": 1234567, "audio": true}
}
```

## Exit codes

| Code | Meaning | Typical action |
| --- | --- | --- |
| 0 | Success | Verify `output` exists |
| 1 | General failure | Read `error`, inspect log |
| 2 | Invalid arguments | Fix flags; `irecord help` |
| 3 | Permission missing | Ask the human to grant Screen Recording / Microphone |
| 4 | Target not found | Re-run `targets`; use `--app`/`--title` |
| 5 | Output problem | Choose another path or use `--overwrite` |
| 6 | Timeout | Poll `status` later or increase `--timeout` |
| 130 | Cancelled | Do not retry automatically |

## Error recovery

| `code` | Recovery |
| --- | --- |
| `screen_permission_denied` | Human must enable the invoking process in System Settings → Privacy & Security → Screen Recording. Restart the host if needed. |
| `microphone_permission_denied` | Use the bundled CLI, or enable the host under Privacy & Security → Microphone. Alternatively drop `--audio microphone/both`. |
| `no_window` | Run `irecord targets --json`; the window may have closed. Prefer `--app` + `--title`. |
| `no_display` | Display id changed (monitor unplugged). Re-run `targets`; use `main`. |
| `invalid_region` | Use four positive numbers in display-local points; minimum ~8×8. |
| `output_exists` | Pass `--overwrite` or a new filename. |
| `output_not_writable` | Use `~/Movies/iRecord` or another writable folder. |
| `output_extension_mismatch` | Match the extension to `--format` or omit the extension. |
| `session_active` | Stop the existing session (`status`, then `stop`) before starting another. |
| `timeout` | Recording may still be finishing/converting. Poll `status --session <id> --json`. |
| `no_frames` | The capture produced no frames (e.g. target closed immediately). Retry with a longer duration. |

## Practical recipes

### Record a short UI demo of a specific app

```bash
irecord targets --json | jq '.windows[] | select(.app=="Notes")'
irecord record --mode window --app "Notes" --duration 6 \
  --audio none --mouse-clicks --output ~/Desktop/notes-demo.mp4 --json
```

### Capture a region as a compact GIF

```bash
irecord record --mode region --display main --region 200,150,960,600 \
  --duration 4 --format gif --gif-width 640 --gif-fps 10 --json
```

### Record a longer workflow with manual stop

```bash
ID=$(irecord start --mode screen --output ~/Desktop/workflow.mp4 --json | jq -r .session)
# ... perform the workflow ...
irecord stop --session "$ID" --json
```

### Verify the artifact

```bash
test -s "$(jq -r .output result.json)" && echo "ok"
```

## Troubleshooting

- **`ok:true` but the video is black**: the selected window may be protected, minimized, or on another Space. Capture that Space/display or use full-screen on the active display.
- **No audio**: check `audio: true` in the result; system audio must actually be playing, and microphone permission must be granted. Window capture records only the captured application's audio; use screen/region mode for all system audio. GIF never has audio.
- **GIF stop takes long**: conversion is CPU-bound and capped at ~1200 frames. Reduce duration, `--gif-fps`, or `--gif-width`.
- **`start` fails but `record` works**: detached processes may not receive a TCC prompt. Use `record --duration N` in that environment.
- **Window id invalid after a few seconds**: resolve the window via `--app`/`--title`, or perform `targets` and `record` atomically in one script.
- **Everything looks fine but another session is active**: run `irecord status --json`; stop it before starting a new background capture.

## Do not

- Do not use raw FFMpeg/AVFoundation alternatives when `irecord` can do the job; no extra tools are required.
- Do not guess display/window ids.
- Do not record for minutes when a few seconds demonstrate the task.
- Do not ignore `exitCode` and parse only stderr.
- Do not upload or share the recording without the user's consent.
