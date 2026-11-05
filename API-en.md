# 🔌 HTML2Video — API

> [Tiếng Việt](API.md) · [README](README-en.md)

This document describes the **full REST API** of HTML2Video: uploading HTML, selecting a project,
render options (new TTS voices, speech rate, aspect, resolution…), polling the queue, and getting the
**final MP4/SRT download link**.

- Base URL: `http://<IP>:5000` (follows `HOST`/`PORT` in `.env`)
- Format: JSON (`Content-Type: application/json`); upload uses `multipart/form-data`
- **No authentication** — trusted LAN only (see *Security* in the README)
- Errors use `{"error": "<message>"}` with the matching HTTP status

## Table of contents

1. [Capabilities](#1-capabilities)
2. [Voice lists](#2-voice-lists)
3. [Projects](#3-projects)
4. [Starting a render](#4-starting-a-render)
5. [Queue monitoring](#5-queue-monitoring)
6. [Getting the download link](#6-getting-the-download-link)
7. [End-to-end examples](#7-end-to-end-examples)
8. [Quick reference](#8-quick-reference)

---

## 1. Capabilities

Call this **first** to learn which encoders and voices are available and which render options are valid.

```
GET /api/capabilities
GET /api/capabilities?refresh=1     # re-detect encoders (after installing FFmpeg/Piper)
```

```bash
curl -s http://localhost:5000/api/capabilities | jq
```

```json
{
  "ffmpeg": true,
  "ffmpeg_bin": "ffmpeg",
  "encoders": {
    "cpu":      { "h264": true,  "hevc": true  },
    "nvidia":   { "h264": false, "hevc": false },
    "rockchip": { "h264": true,  "hevc": true  }
  },
  "piper": true,
  "piper_models": ["vi_VN-vais1000-medium.onnx"],
  "elevenlabs": true,
  "elevenlabs_voice": "21m00Tcm4TlvDq8ikWAM",
  "elevenlabs_model": "eleven_multilingual_v2",
  "vieneu": true,
  "vieneu_voice": "Mai Anh",
  "vieneu_model": "vieneu-v3-nano",
  "cpus": 8,
  "auto_workers": 4
}
```

| Field | Meaning |
|---|---|
| `ffmpeg` | FFmpeg + FFprobe usable (all `encoders` are `false` otherwise) |
| `encoders[<enc>][<codec>]` | Encoder availability — drives `encoder`/`codec` at render time |
| `piper` | Piper usable (warm `piper-tts` in the venv, or `PIPER_BIN`) |
| `piper_models` | `*.onnx` files in `voices/` — valid `piper_model` values |
| `elevenlabs` | `ELEVENLABS_API_KEY` configured → `tts: "elevenlabs"` allowed |
| `vieneu` | `VIENEU_API_KEY` configured → `tts: "vieneu"` allowed |
| `auto_workers` | Chromium workers used when `workers: 0` |

---

## 2. Voice lists

```
GET /api/voices              # Edge TTS (online)
GET /api/elevenlabs/voices   # ElevenLabs (filtered to Vietnamese)
GET /api/vieneu/voices       # VieNeu-TTS presets
```

```bash
curl -s http://localhost:5000/api/voices            | jq '.[0:3]'
curl -s http://localhost:5000/api/elevenlabs/voices | jq
curl -s http://localhost:5000/api/vieneu/voices     | jq
```

**Edge** — returns `id`, `locale`, `gender` (network failure falls back to a built-in list):

```json
[
  { "id": "vi-VN-HoaiMyNeural", "locale": "vi-VN", "gender": "Female" },
  { "id": "vi-VN-NamMinhNeural", "locale": "vi-VN", "gender": "Male" }
]
```

**ElevenLabs** / **VieNeu** — return `id` + `name`; `[]` when no API key is configured:

```json
[{ "id": "21m00Tcm4TlvDq8ikWAM", "name": "Rachel" }]
```

```json
[{ "id": "Mai Anh", "name": "Mai Anh" }]
```

> Pass this `id` as the `voice` field when rendering.
> For VieNeu, `voice` is a **preset name** (e.g. `"Mai Anh"`); for ElevenLabs it is a **Voice ID**.
> Lists are cached in-process — restart the service to refresh them.

---

## 3. Projects

Each upload creates a folder `uploads/<id>/`. `id` = `<filename>-YYYYMMDD-HHMMSS`.

### 3.1 Upload

```
POST /api/upload        # multipart/form-data, field: file (.html | .htm | .zip)
```

```bash
curl -s -F file=@examples/demo.html http://localhost:5000/api/upload | jq
```

```json
{ "id": "demo-20261105-101530", "name": "demo", "entry": "demo.html",
  "uploaded": "2026-11-05 10:15:30" }
```

- ZIP: prefers `index.html`, otherwise the shallowest `.html`; `entry` is the relative path inside the ZIP
- 200 MB limit (`MAX_CONTENT_LENGTH`); wrong type → `400`

### 3.2 List & inspect

```
GET /api/projects             # [{id, name, entry, uploaded}] — newest first
GET /api/projects/<pid>       # meta + scenes + estimated duration
```

```bash
curl -s http://localhost:5000/api/projects | jq '.[].id'
curl -s http://localhost:5000/api/projects/demo-20261105-101530 | jq
```

```json
{
  "id": "demo-20261105-101530", "name": "demo", "entry": "demo.html",
  "uploaded": "2026-11-05 10:15:30", "title": "Demo",
  "scenes": [
    { "say": "Xin chào các bạn.", "t": 5 },
    { "say": "Cảnh hai.", "t": 8 }
  ],
  "chars": 31,
  "est": 13.6
}
```

| Field | Meaning |
|---|---|
| `scenes[i].say` | TTS text (`data-say`) |
| `scenes[i].t` | Minimum duration (`data-t`, seconds) |
| `chars` | Total characters to be sent to TTS — handy for ElevenLabs quota estimates |
| `est` | Estimated video duration (seconds) |

### 3.3 Preview & delete

```
GET    /preview/<pid>/<file-path>    # serves files inside uploads/<pid>/ (used by the preview iframe)
DELETE /api/projects/<pid>           # removes the whole uploads/<pid>/ folder
```

```bash
curl -s -X DELETE http://localhost:5000/api/projects/demo-20261105-101530 | jq
```

> `DELETE /api/projects/<pid>` does **not** delete already-rendered MP4 files in `outputs/`.
> Unknown project → `404`.

---

## 4. Starting a render

```
POST /api/render        # Content-Type: application/json
```

```bash
curl -s -X POST http://localhost:5000/api/render \
  -H 'Content-Type: application/json' \
  -d '{
    "project": "demo-20261105-101530",
    "tts": "edge",
    "voice": "vi-VN-HoaiMyNeural",
    "rate": 5,
    "aspect": "16:9",
    "resolution": "1080p",
    "fps": 30,
    "subtitles": true,
    "encoder": "rockchip",
    "codec": "h264",
    "workers": 0
  }'
```

```json
{ "id": "a1b2c3d4", "output": "demo_16x9_1080p_20261105-101602.mp4" }
```

- `id` = **job id** (used by later steps); `output` = **MP4 filename** written to `outputs/`
- The job is **queued** and returns immediately; rendering runs in the background, **one job at a time**
- Errors: `404` when `project` is unknown; `400` for invalid options or an unavailable encoder

### 4.1 Parameters

| Field | Type | Default | Valid values / notes |
|---|---|---|---|
| `project` | string | — | **Required.** `id` from section 3 |
| `tts` | string | `"edge"` | `edge` · `piper` · `elevenlabs` · `vieneu` |
| `voice` | string | `vi-VN-HoaiMyNeural` | See [4.2](#42-voice-per-tts) |
| `piper_model` | string | `""` | **Required when `tts="piper"`**: file name in `voices/` |
| `rate` | int | `5` | Speech rate %, clamped to **`-50` … `100`** |
| `aspect` | string | `"16:9"` | `16:9` · `9:16` · `4:3` |
| `resolution` | string | `"1080p"` | `720p` · `1080p` · `1440p` · `2160p` |
| `fps` | int | `30` | `24` · `25` · `30` · `60` |
| `subtitles` | bool | `true` | Burned-in captions (a `.srt` is always written) |
| `encoder` | string | `"cpu"` | `cpu` · `nvidia` · `rockchip` |
| `codec` | string | `"h264"` | `h264` · `hevc` |
| `workers` | int | `0` | `0`…`8`; `0` = auto (`auto_workers`) |
| `upscale` | bool | `false` | Capture at 2/3 resolution then upscale (lighter on Chromium) |
| `chromium_gpu` | bool | `false` | Let Chromium use the GPU (experimental) |
| `extra_css` | string | `""` | Extra CSS injected into the page, max 50,000 chars |

Validation order: encoder availability → aspect/resolution/fps → TTS & voice.

### 4.2 Voice per TTS

| `tts` | `voice` | Notes |
|---|---|---|
| `edge` | Edge voice code, e.g. `vi-VN-HoaiMyNeural` | Letters/digits/`-`/`_` only |
| `piper` | *ignored* — use `piper_model` | Model must exist in `voices/` |
| `elevenlabs` | Voice ID, e.g. `21m00Tcm4TlvDq8ikWAM` | Empty → `ELEVENLABS_VOICE_ID`; needs `ELEVENLABS_API_KEY` |
| `vieneu` | Preset name, e.g. `Mai Anh` | Empty → `VIENEU_VOICE`; needs `VIENEU_API_KEY` |

Examples:

```bash
# Edge (online, free)
-d '{"project":"p1","tts":"edge","voice":"vi-VN-NamMinhNeural","rate":10}'

# Piper (offline)
-d '{"project":"p1","tts":"piper","piper_model":"vi_VN-vais1000-medium.onnx"}'

# ElevenLabs (key required in .env)
-d '{"project":"p1","tts":"elevenlabs","voice":"21m00Tcm4TlvDq8ikWAM"}'

# VieNeu-TTS (server + key required in .env)
-d '{"project":"p1","tts":"vieneu","voice":"Mai Anh"}'
```

### 4.3 Aspect & resolution

Output size = the aspect's base size × the resolution factor:

| `aspect` | `720p` | `1080p` | `1440p` | `2160p` |
|---|---|---|---|---|
| `16:9` | 1280×720 | 1920×1080 | 2560×1440 | 3840×2160 |
| `9:16` | 720×1280 | 1080×1920 | 1440×2560 | 2160×3840 |
| `4:3` | 960×720 | 1440×1080 | 1920×1440 | 2880×2160 |

### 4.4 Encoder

```bash
-d '{"project":"p1","encoder":"rockchip","codec":"h264"}'   # recommended on RK3588
-d '{"project":"p1","encoder":"nvidia","codec":"hevc"}'     # NVIDIA GPU hosts
-d '{"project":"p1","encoder":"cpu","codec":"h264"}'        # default
```

Check `capabilities.encoders` first; unavailable encoder → `400`.

---

## 5. Queue monitoring

```
GET    /api/jobs                 # [{id, project, output, status, progress, message, summary, created}]
POST   /api/jobs/<id>/cancel     # request cancellation
DELETE /api/jobs/<id>            # drop the job from the UI + delete MP4/SRT + build/<id>
```

```bash
curl -s http://localhost:5000/api/jobs | jq '.[0]'
```

```json
{
  "id": "a1b2c3d4",
  "project": "demo-20261105-101530",
  "output": "demo_16x9_1080p_20261105-101602.mp4",
  "status": "running",
  "progress": 42.7,
  "message": "TTS 12/29 cảnh…",
  "summary": "VieNeu · Mai Anh · 16:9 1080p 30fps · h264_rkmpp · phụ đề bật · tự động luồng",
  "created": 1762322162.14
}
```

| `status` | Meaning |
|---|---|
| `queued` | Waiting (only one render runs at a time) |
| `running` | Rendering — track `progress` (0–100) and `message` |
| `done` | Finished, `progress: 100` |
| `cancelled` | Cancelled (`cancel` or `DELETE`) |
| `error` | Failed — see `message`; `build/<id>/` is kept for logs |

Cancel / delete:

```bash
curl -s -X POST   http://localhost:5000/api/jobs/a1b2c3d4/cancel | jq
curl -s -X DELETE http://localhost:5000/api/jobs/a1b2c3d4        | jq
```

> The queue is **not** persisted across restarts. Files in `outputs/` remain.

---

## 6. Getting the download link

When `status = "done"`, the file name is in `job.output`. Download it via:

```
GET /outputs/<name>          # serves the file (inline in the browser)
GET /outputs/<name>?dl=1     # Content-Disposition: attachment → download
```

```bash
OUT="demo_16x9_1080p_20261105-101602.mp4"

curl -o "$OUT" "http://localhost:5000/outputs/$OUT?dl=1"
curl -o "${OUT%.mp4}.srt" "http://localhost:5000/outputs/${OUT%.mp4}.srt"
```

List rendered files (jobs still running are skipped):

```
GET /api/outputs                 # [{name, size, time, srt}]
DELETE /api/outputs/<name>       # delete the MP4 + its SRT
```

```bash
curl -s http://localhost:5000/api/outputs | jq
```

```json
[
  { "name": "demo_16x9_1080p_20261105-101602.mp4",
    "size": 8421376, "time": "05/11 10:22", "srt": "demo_16x9_1080p_20261105-101602.srt" }
]
```

---

## 7. End-to-end examples

### 7.1 Bash (upload → render → poll → download)

```bash
#!/usr/bin/env bash
set -e
BASE=http://localhost:5000

# 0) Capabilities
curl -s "$BASE/api/capabilities" | jq '{ffmpeg, encoders, piper, elevenlabs, vieneu}'

# 1) Upload
PID=$(curl -s -F file=@examples/demo.html "$BASE/api/upload" | jq -r .id)
echo "project: $PID"

# 2) (optional) pick a voice
curl -s "$BASE/api/vieneu/voices" | jq

# 3) Render
JID=$(curl -s -X POST "$BASE/api/render" -H 'Content-Type: application/json' -d "{
  \"project\": \"$PID\",
  \"tts\": \"vieneu\",
  \"voice\": \"Mai Anh\",
  \"rate\": 5,
  \"aspect\": \"9:16\",
  \"resolution\": \"1080p\",
  \"fps\": 30,
  \"subtitles\": true,
  \"encoder\": \"rockchip\",
  \"codec\": \"h264\",
  \"workers\": 0
}" | jq -r .id)
echo "job: $JID"

# 4) Wait until done
while :; do
  J=$(curl -s "$BASE/api/jobs" | jq -c ".[] | select(.id==\"$JID\")")
  S=$(jq -r .status <<<"$J"); P=$(jq -r .progress <<<"$J"); M=$(jq -r .message <<<"$J")
  printf '\r%s %5.1f%% %s   ' "$S" "$P" "$M"
  [ "$S" = "done" ] && break
  [ "$S" = "error" ] && { echo; echo "$J" | jq; exit 1; }
  [ "$S" = "cancelled" ] && { echo; exit 1; }
  sleep 3
done
echo

# 5) Download MP4 + SRT
OUT=$(jq -r .output <<<"$J")
curl -s -o "$OUT" "$BASE/outputs/$OUT?dl=1"
curl -s -o "${OUT%.mp4}.srt" "$BASE/outputs/${OUT%.mp4}.srt"
ls -lh "$OUT" "${OUT%.mp4}.srt"
```

### 7.2 Python

```python
import time, requests

BASE = "http://localhost:5000"

pid = requests.post(f"{BASE}/api/upload",
                    files={"file": open("examples/demo.html", "rb")}).json()["id"]

job = requests.post(f"{BASE}/api/render", json={
    "project": pid,
    "tts": "elevenlabs",
    "voice": "21m00Tcm4TlvDq8ikWAM",
    "rate": 0,
    "aspect": "16:9",
    "resolution": "1080p",
    "fps": 30,
    "subtitles": True,
    "encoder": "rockchip",
    "codec": "h264",
    "workers": 0,
}).json()
jid, name = job["id"], job["output"]

while True:
    j = next(x for x in requests.get(f"{BASE}/api/jobs").json() if x["id"] == jid)
    print(f'{j["status"]} {j["progress"]:.1f}% {j["message"]}')
    if j["status"] in ("done", "error", "cancelled"):
        break
    time.sleep(3)

if j["status"] == "done":
    mp4 = requests.get(f"{BASE}/outputs/{name}?dl=1")
    open(name, "wb").write(mp4.content)
    srt = requests.get(f"{BASE}/outputs/{name[:-4]}.srt")
    open(f"{name[:-4]}.srt", "wb").write(srt.content)
```

---

## 8. Quick reference

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/api/capabilities` | Encoders, Piper models, available TTS (`?refresh=1` to re-detect) |
| `GET` | `/api/voices` | Edge voice list |
| `GET` | `/api/elevenlabs/voices` | ElevenLabs voices (Vietnamese filtered) |
| `GET` | `/api/vieneu/voices` | VieNeu voices (presets) |
| `POST` | `/api/upload` | Upload `.html` / `.htm` / `.zip` → project |
| `GET` | `/api/projects` | List projects |
| `GET` | `/api/projects/<pid>` | Project details + scenes + estimated duration |
| `DELETE` | `/api/projects/<pid>` | Delete project (`uploads/<pid>/`) |
| `GET` | `/preview/<pid>/<file>` | Serve project files (preview) |
| `POST` | `/api/render` | Create a render job → `{id, output}` |
| `GET` | `/api/jobs` | Queue status |
| `POST` | `/api/jobs/<id>/cancel` | Cancel a job |
| `DELETE` | `/api/jobs/<id>` | Delete job + MP4/SRT + `build/<id>` |
| `GET` | `/api/outputs` | List rendered files |
| `GET` | `/outputs/<name>?dl=1` | **Download the MP4** (`.srt` shares the name) |
| `DELETE` | `/api/outputs/<name>` | Delete MP4 + SRT |

---

[README](README-en.md) · [Tiếng Việt](API.md)
