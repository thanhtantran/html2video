# 🔌 HTML2Video — API

> [English](API-en.md) · [README](README.md)

Tài liệu này mô tả **toàn bộ REST API** của HTML2Video: từ upload HTML, chọn dự án, các tùy chọn
render (TTS/giọng mới, tốc độ đọc, khung hình, độ phân giải…), theo dõi hàng đợi, cho tới **lấy link
tải MP4/SRT** về máy.

- Base URL: `http://<IP>:5000` (đổi theo `HOST`/`PORT` trong `.env`)
- Định dạng: JSON (`Content-Type: application/json`), riêng upload dùng `multipart/form-data`
- **Không có xác thực** — chỉ dùng trong LAN tin cậy (xem mục *Bảo mật* trong README)
- Mọi route trả lỗi dạng `{"error": "<thông báo>"}` kèm HTTP status tương ứng

## Mục lục

1. [Kiểm tra năng lực hệ thống](#1-kiểm-tra-năng-lực-hệ-thống)
2. [Danh sách giọng đọc](#2-danh-sách-giọng-đọc)
3. [Dự án (project)](#3-dự-án-project)
4. [Bắt đầu render](#4-bắt-đầu-render)
5. [Theo dõi hàng đợi](#5-theo-dõi-hàng-đợi)
6. [Lấy link tải kết quả](#6-lấy-link-tải-kết-quả)
7. [Ví dụ end-to-end](#7-ví-dụ-end-to-end)
8. [Bảng tra nhanh](#8-bảng-tra-nhanh)

---

## 1. Kiểm tra năng lực hệ thống

Gọi **đầu tiên** để biết máy đang bật encoder nào, giọng nào, và những tùy chọn render nào hợp lệ.

```
GET /api/capabilities
GET /api/capabilities?refresh=1     # dò lại encoder (sau khi cài FFmpeg/Piper mới)
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

| Trường | Ý nghĩa |
|---|---|
| `ffmpeg` | FFmpeg + FFprobe có chạy được không (`encoders` đều `false` nếu không) |
| `encoders[<enc>][<codec>]` | Encoder khả dụng — dùng để chọn `encoder`/`codec` khi render |
| `piper` | Piper chạy được (warm `piper-tts` trong venv, hoặc `PIPER_BIN`) |
| `piper_models` | Danh sách `*.onnx` trong `voices/` — giá trị hợp lệ của `piper_model` |
| `elevenlabs` | Đã cấu hình `ELEVENLABS_API_KEY` → chọn được `tts: "elevenlabs"` |
| `vieneu` | Đã cấu hình `VIENEU_API_KEY` → chọn được `tts: "vieneu"` |
| `auto_workers` | Số luồng Chromium khi `workers: 0` |

---

## 2. Danh sách giọng đọc

```
GET /api/voices              # Edge TTS (online)
GET /api/elevenlabs/voices   # ElevenLabs (đã lọc giọng tiếng Việt)
GET /api/vieneu/voices       # VieNeu-TTS presets
```

```bash
curl -s http://localhost:5000/api/voices            | jq '.[0:3]'
curl -s http://localhost:5000/api/elevenlabs/voices | jq
curl -s http://localhost:5000/api/vieneu/voices     | jq
```

**Edge** — trả về `id`, `locale`, `gender` (lỗi mạng thì trả danh sách fallback):

```json
[
  { "id": "vi-VN-HoaiMyNeural", "locale": "vi-VN", "gender": "Female" },
  { "id": "vi-VN-NamMinhNeural", "locale": "vi-VN", "gender": "Male" }
]
```

**ElevenLabs** / **VieNeu** — trả về `id` + `name`, chưa cấu hình key thì trả `[]`:

```json
[{ "id": "21m00Tcm4TlvDq8ikWAM", "name": "Rachel" }]
```

```json
[{ "id": "Mai Anh", "name": "Mai Anh" }]
```

> Giá trị `id` này chính là giá trị truyền vào trường `voice` khi render.
> Với VieNeu, `voice` là **tên preset** (vd `"Mai Anh"`); với ElevenLabs là **Voice ID**.
> Danh sách được cache trong process — khởi động lại service để làm mới.

---

## 3. Dự án (project)

Mỗi lần upload tạo một thư mục `uploads/<id>/`. `id` = `<tên-file>-YYYYMMDD-HHMMSS`.

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

- ZIP: ưu tiên `index.html` (nếu có), ngược lại chọn `.html` nông nhất; `entry` là đường dẫn tương đối bên trong ZIP
- Giới hạn 200 MB (`MAX_CONTENT_LENGTH`); sai định dạng → `400`

### 3.2 Liệt kê & xem chi tiết

```
GET /api/projects             # [{id, name, entry, uploaded}] — mới nhất trước
GET /api/projects/<pid>       # meta + cảnh + thời lượng ước tính
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

| Trường | Ý nghĩa |
|---|---|
| `scenes[i].say` | Lời TTS (`data-say`) |
| `scenes[i].t` | Thời lượng tối thiểu (`data-t`, giây) |
| `chars` | Tổng số ký tự sẽ gửi TTS — dùng để ước lượng hạn mức ElevenLabs |
| `est` | Thời lượng video ước tính (giây) |

### 3.3 Xem trước & xóa

```
GET    /preview/<pid>/<đường-dẫn-file>    # phục vụ file trong uploads/<pid>/ (dùng cho iframe preview)
DELETE /api/projects/<pid>                # xóa cả thư mục uploads/<pid>/
```

```bash
curl -s -X DELETE http://localhost:5000/api/projects/demo-20261105-101530 | jq
```

> `DELETE /api/projects/<pid>` **không** xóa file MP4 đã render trong `outputs/`.
> Dự án không tồn tại → `404`.

---

## 4. Bắt đầu render

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

- `id` = **job id** (dùng cho các bước sau); `output` = **tên file MP4** sẽ ghi vào `outputs/`
- Job được **xếp hàng** và trả về ngay; render chạy nền **1 job/lúc**
- Lỗi: `404` nếu `project` không tồn tại; `400` nếu tham số sai hoặc encoder không khả dụng

### 4.1 Bảng tham số

| Trường | Kiểu | Mặc định | Giá trị hợp lệ / ghi chú |
|---|---|---|---|
| `project` | string | — | **Bắt buộc**. `id` từ mục 3 |
| `tts` | string | `"edge"` | `edge` · `piper` · `elevenlabs` · `vieneu` |
| `voice` | string | `vi-VN-HoaiMyNeural` | Xem [4.2](#42-giọng-theo-từng-tts) |
| `piper_model` | string | `""` | **Bắt buộc khi `tts="piper"`**: tên file trong `voices/` |
| `rate` | int | `5` | Tốc độ đọc %, kẹp trong **`-50` … `100`** |
| `aspect` | string | `"16:9"` | `16:9` · `9:16` · `4:3` |
| `resolution` | string | `"1080p"` | `720p` · `1080p` · `1440p` · `2160p` |
| `fps` | int | `30` | `24` · `25` · `30` · `60` |
| `subtitles` | bool | `true` | Bật phụ đề trên video (luôn xuất kèm `.srt`) |
| `encoder` | string | `"cpu"` | `cpu` · `nvidia` · `rockchip` |
| `codec` | string | `"h264"` | `h264` · `hevc` |
| `workers` | int | `0` | `0`…`8`; `0` = số luồng tự động (`auto_workers`) |
| `upscale` | bool | `false` | Chụp ở 2/3 độ phân giải rồi phóng to (Chromium nhẹ hơn) |
| `chromium_gpu` | bool | `false` | Cho Chromium dùng GPU (thử nghiệm) |
| `extra_css` | string | `""` | CSS chèn thêm vào trang, tối đa 50 000 ký tự |

Thứ tự ưu tiên khi kiểm tra lỗi: encoder khả dụng → aspect/resolution/fps → TTS & giọng.

### 4.2 Giọng theo từng TTS

| `tts` | `voice` | Ghi chú |
|---|---|---|
| `edge` | Mã giọng Edge, vd `vi-VN-HoaiMyNeural` | Chỉ cho phép chữ/số/`-`/`_` |
| `piper` | *bỏ qua* — dùng `piper_model` | Model phải có trong `voices/` |
| `elevenlabs` | Voice ID, vd `21m00Tcm4TlvDq8ikWAM` | Bỏ trống → dùng `ELEVENLABS_VOICE_ID`; cần `ELEVENLABS_API_KEY` |
| `vieneu` | Tên preset, vd `Mai Anh` | Bỏ trống → dùng `VIENEU_VOICE`; cần `VIENEU_API_KEY` |

Ví dụ từng loại:

```bash
# Edge (online, miễn phí)
-d '{"project":"p1","tts":"edge","voice":"vi-VN-NamMinhNeural","rate":10}'

# Piper (offline)
-d '{"project":"p1","tts":"piper","piper_model":"vi_VN-vais1000-medium.onnx"}'

# ElevenLabs (cần key trong .env)
-d '{"project":"p1","tts":"elevenlabs","voice":"21m00Tcm4TlvDq8ikWAM"}'

# VieNeu-TTS (cần máy chủ + key trong .env)
-d '{"project":"p1","tts":"vieneu","voice":"Mai Anh"}'
```

### 4.3 Khung hình & độ phân giải

Kích thước đầu ra = kích thước gốc của khung hình × hệ số độ phân giải:

| `aspect` | `720p` | `1080p` | `1440p` | `2160p` |
|---|---|---|---|---|
| `16:9` | 1280×720 | 1920×1080 | 2560×1440 | 3840×2160 |
| `9:16` | 720×1280 | 1080×1920 | 1440×2560 | 2160×3840 |
| `4:3` | 960×720 | 1440×1080 | 1920×1440 | 2880×2160 |

### 4.4 Encoder

```bash
-d '{"project":"p1","encoder":"rockchip","codec":"h264"}'   # RK3588 khuyến nghị
-d '{"project":"p1","encoder":"nvidia","codec":"hevc"}'     # máy có GPU NVIDIA
-d '{"project":"p1","encoder":"cpu","codec":"h264"}'        # mặc định
```

Kiểm tra `capabilities.encoders` trước; encoder không khả dụng → `400`.

---

## 5. Theo dõi hàng đợi

```
GET    /api/jobs                 # [{id, project, output, status, progress, message, summary, created}]
POST   /api/jobs/<id>/cancel     # yêu cầu hủy
DELETE /api/jobs/<id>            # bỏ job khỏi UI + xóa MP4/SRT + build/<id>
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

| `status` | Ý nghĩa |
|---|---|
| `queued` | Đang chờ (chỉ 1 job render mỗi lúc) |
| `running` | Đang render — theo dõi `progress` (0–100) và `message` |
| `done` | Xong, `progress: 100` |
| `cancelled` | Đã hủy (`cancel` hoặc `DELETE`) |
| `error` | Lỗi — xem `message`; thư mục `build/<id>/` được giữ lại để xem log |

Hủy / xóa:

```bash
curl -s -X POST   http://localhost:5000/api/jobs/a1b2c3d4/cancel | jq
curl -s -X DELETE http://localhost:5000/api/jobs/a1b2c3d4        | jq
```

> Hàng đợi **không lưu** qua restart. File trong `outputs/` vẫn còn nguyên.

---

## 6. Lấy link tải kết quả

Khi `status = "done"`, tên file nằm ở `job.output`. Tải về bằng một trong hai route:

```
GET /outputs/<name>          # trả file (xem trực tiếp trên trình duyệt)
GET /outputs/<name>?dl=1     # Content-Disposition: attachment → tải xuống
```

```bash
OUT="demo_16x9_1080p_20261105-101602.mp4"

curl -o "$OUT" "http://localhost:5000/outputs/$OUT?dl=1"
curl -o "${OUT%.mp4}.srt" "http://localhost:5000/outputs/${OUT%.mp4}.srt"
```

Danh sách file đã render (bỏ qua file của job đang chạy):

```
GET /api/outputs                 # [{name, size, time, srt}]
DELETE /api/outputs/<name>       # xóa MP4 + SRT tương ứng
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

## 7. Ví dụ end-to-end

### 7.1 Bash (upload → render → chờ → tải)

```bash
#!/usr/bin/env bash
set -e
BASE=http://localhost:5000

# 0) Năng lực hệ thống
curl -s "$BASE/api/capabilities" | jq '{ffmpeg, encoders, piper, elevenlabs, vieneu}'

# 1) Upload
PID=$(curl -s -F file=@examples/demo.html "$BASE/api/upload" | jq -r .id)
echo "project: $PID"

# 2) (tùy chọn) chọn giọng
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

# 4) Chờ tới khi xong
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

# 5) Tải MP4 + SRT
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

## 8. Bảng tra nhanh

| Method | Đường dẫn | Việc |
|---|---|---|
| `GET` | `/api/capabilities` | Encoder, Piper model, TTS khả dụng (`?refresh=1` để dò lại) |
| `GET` | `/api/voices` | Danh sách giọng Edge |
| `GET` | `/api/elevenlabs/voices` | Giọng ElevenLabs (lọc tiếng Việt) |
| `GET` | `/api/vieneu/voices` | Giọng VieNeu (presets) |
| `POST` | `/api/upload` | Upload `.html` / `.htm` / `.zip` → project |
| `GET` | `/api/projects` | Danh sách dự án |
| `GET` | `/api/projects/<pid>` | Chi tiết dự án + cảnh + thời lượng ước tính |
| `DELETE` | `/api/projects/<pid>` | Xóa dự án (`uploads/<pid>/`) |
| `GET` | `/preview/<pid>/<file>` | Phục vụ file của dự án (preview) |
| `POST` | `/api/render` | Tạo job render → `{id, output}` |
| `GET` | `/api/jobs` | Trạng thái hàng đợi |
| `POST` | `/api/jobs/<id>/cancel` | Hủy job |
| `DELETE` | `/api/jobs/<id>` | Xóa job + MP4/SRT + `build/<id>` |
| `GET` | `/api/outputs` | Danh sách file đã render |
| `GET` | `/outputs/<name>?dl=1` | **Tải MP4 về** (`.srt` cùng tên) |
| `DELETE` | `/api/outputs/<name>` | Xóa file MP4 + SRT |

---

[README](README.md) · [English](API-en.md)
