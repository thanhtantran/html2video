# 🎬 HTML2Video

> Chạy trên Orange Pi Rockchip 3588 · [English](README-en.md) · [Screenshot](screenshot.md)

Công cụ chuyển **trang HTML hoạt hình chia theo cảnh** kèm **TTS** thành video **MP4**. Có giao diện web, render song song nhiều tiến trình Chromium, mã hóa **CPU / NVIDIA NVENC / Rockchip MPP**. Tối ưu **Orange Pi 5 Plus (RK3588)**, chạy được trên Linux x86_64 hoặc ARM64.

![Giao diện tối](screenshots/html2video-1.png)

Xem đủ ảnh: **[screenshot.md](screenshot.md)**

---

## Mục lục

1. [Tính năng](#1-tính-năng)
2. [Luồng xử lý](#2-luồng-xử-lý)
3. [Định dạng HTML](#3-định-dạng-html)
4. [Cấu trúc thư mục](#4-cấu-trúc-thư-mục)
5. [Cài đặt](#5-cài-đặt)
6. [Cấu hình](#6-cấu-hình)
7. [Sử dụng](#7-sử-dụng)
8. [Hiệu năng & sự cố](#8-hiệu-năng--sự-cố)
9. [Bảo mật & giới hạn](#9-bảo-mật--giới-hạn)

---

## 1. Tính năng

- Upload `.html` / `.zip` (HTML + ảnh, font, CSS); mỗi dự án một thư mục; **xóa dự án** trên UI
- Xem trước theo tỉ lệ khung hình; danh sách cảnh / lời thoại / thời lượng ước tính
- Theme **sáng / tối**
- **TTS:** Edge (online) hoặc **Piper** offline (load model 1 lần trong process, synth tuần tự)
- Khung **16:9 / 9:16 / 4:3**, độ phân giải 720p–4K, FPS 24/25/30/60
- Phụ đề trên video + luôn xuất `.srt`
- Encoder: `libx264`/`libx265`, NVENC, `h264_rkmpp`/`hevc_rkmpp` — tự dò trên máy
- Render song song N Chromium; hàng đợi, tiến độ, hủy, **xóa job** (MP4/SRT + `build/`)

---

## 2. Luồng xử lý

```
Trình duyệt → Flask (app.py) → hàng đợi (1 job/lúc) → renderer.py
  ① Phân tích  Chromium đọc .scene[data-say][data-t]
  ② TTS        Edge song song ≤4 · Piper warm + tuần tự
  ③ Render     N worker Chromium · seek CSS animation · JPEG → ffmpeg → .ts
  ④ Ghép       concat (-c:v copy) + audio AAC → MP4 + SRT
```

Ứng dụng **không quay màn hình realtime**. Mỗi khung `g` được tua bằng Web Animations API (`currentTime`), nên máy chậm vẫn đúng FPS và chia được nhiều Chromium.

**HTML đầu vào:** chỉ hỗ trợ **CSS animation / transition**. Không tua được `requestAnimationFrame`, canvas/WebGL, GSAP, `<video>`, GIF.

---

## 3. Định dạng HTML

Mỗi cảnh: `class="scene"`, `data-say` (lời TTS, có thể trống), `data-t` (thời lượng tối thiểu, giây). Cảnh active nhận class `active`.

```html
<section class="scene" data-t="5" data-say="Xin chào các bạn.">
  <h1 class="a">Tiêu đề</h1>
</section>
<style>
  .scene{position:absolute;inset:0;opacity:0}
  .scene.active{opacity:1}
  .a{opacity:0}
  .scene.active .a{animation:up .8s forwards}
  @keyframes up{from{opacity:0;transform:translateY(40px)}to{opacity:1;transform:none}}
</style>
```

Nếu trang tự chuyển cảnh bằng JS:

```js
if (!navigator.webdriver) { /* slideshow tự động */ }
```

Ví dụ đầy đủ: `examples/demo.html`. ZIP: ưu tiên `index.html`, dùng đường dẫn tương đối.

---

## 4. Cấu trúc thư mục

```
html2video/
├── app.py / renderer.py / bench.py
├── install.sh / run.sh / .env.example
├── static/index.html
├── scripts/          # ffmpeg-rockchip, perf-mode, get-piper-voice
├── examples/demo.html
├── voices/           # Piper *.onnx + *.onnx.json
├── uploads/ outputs/ build/
├── screenshots/      # ảnh UI
├── screenshot.md
├── README.md         # tiếng Việt (file này)
└── README-en.md      # English
```

---

## 5. Cài đặt

### 5.1 Orange Pi 5 Plus (RK3588)

- Quạt + tản nhiệt; nguồn đủ; nên dùng NVMe
- Kernel **BSP Rockchip** (có `/dev/mpp_service`) nếu muốn encoder Rockchip

```bash
uname -r
ls -l /dev/mpp_service /dev/rga /dev/dri

# FFmpeg có rkmpp (20–40 phút) — tùy chọn
bash scripts/build-ffmpeg-rockchip.sh
# rồi trong .env: FFMPEG_BIN=/usr/local/bin/ffmpeg , FFPROBE_BIN=/usr/local/bin/ffprobe

./install.sh --service
sudo systemctl status html2video
# hoặc: ./install.sh && ./run.sh
```

Mở `http://<IP>:5000` → thanh trạng thái cần `FFmpeg ✅`. Upload `examples/demo.html`, render 720p thử.

Piper offline (tùy chọn):

```bash
bash scripts/get-piper-voice.sh
```

Bấm **↻ Kiểm tra lại**. Ưu tiên `piper-tts` trong `.venv` (warm model). `PIPER_BIN` chỉ là fallback native.

### 5.2 Linux khác (CPU / NVIDIA)

```bash
./install.sh --service
```

NVIDIA: driver + FFmpeg có `nvenc`; số luồng ≤ giới hạn phiên NVENC. Docker/VM: `--shm-size=2g` (hoặc `--ipc=host`).

---

## 6. Cấu hình

Sửa `.env` (từ `.env.example`), rồi `sudo systemctl restart html2video`.

| Biến | Mặc định | Ý nghĩa |
|---|---|---|
| `HOST` / `PORT` | `0.0.0.0` / `5000` | Địa chỉ web |
| `FFMPEG_BIN` / `FFPROBE_BIN` | `ffmpeg` / `ffprobe` | Đường dẫn FFmpeg |
| `PIPER_BIN` | `piper` | Fallback native |
| `PIPER_CONCURRENCY` | `1` | **Giữ 1 trên RK3588** — song song dễ hard-reboot |
| `PIPER_ORT_THREADS` / `PIPER_OMP_THREADS` | `2` / `2` | Thread ORT/OpenMP |
| `CHROMIUM_ARGS` / `CHROMIUM_GPU_ARGS` | — | Cờ Chromium |

---

## 7. Sử dụng

1. Upload / chọn dự án (có nút **Xóa** → xóa `uploads/<id>/`)
2. Chọn TTS, khung hình, độ phân giải, encoder…
3. **Render MP4** → theo dõi **Hàng đợi** (Hủy / Xóa job / tải MP4·SRT)
4. Đổi theme sáng/tối trên header

API chính: `GET /api/capabilities`, `POST /api/upload`, `POST /api/render`, `GET /api/jobs`, `POST /api/jobs/<id>/cancel`, `DELETE /api/jobs/<id>`, `DELETE /api/projects/<id>`, `GET|DELETE /api/outputs…`

```bash
curl -F file=@examples/demo.html http://localhost:5000/api/upload
curl -X POST http://localhost:5000/api/render -H 'Content-Type: application/json' -d '{
  "project":"demo-YYYYMMDD-HHMMSS","tts":"edge","voice":"vi-VN-HoaiMyNeural","rate":5,
  "aspect":"16:9","resolution":"1080p","fps":30,"subtitles":true,
  "encoder":"rockchip","codec":"h264","workers":0}'
```

---

## 8. Hiệu năng & sự cố

**RK3588 gợi ý:** Rockchip H.264 · luồng Tự động (4) · 30 fps · 1080p. Đo bằng:

```bash
.venv/bin/python bench.py examples/demo.html 1080p
```

| Hiện tượng | Cách xử lý |
|---|---|
| Rockchip ❌ | Đặt `FFMPEG_BIN`, restart; quyền `/dev/mpp_service`; kernel BSP |
| Reboot khi Piper | Không tăng `PIPER_CONCURRENCY` / không spawn nhiều process ONNX |
| WAV rỗng / Piper lỗi | Job trước bị cắt; xóa job, chạy lại; dùng warm `piper-tts` |
| Chromium thiếu | `playwright install chromium` (+ `install-deps`) đúng user service |
| Worker crash / thiếu RAM | Giảm luồng hoặc độ phân giải |
| Animation lệch | Chỉ CSS animation; bọc slideshow trong `!navigator.webdriver` |
| Nóng → chậm dần | Tản nhiệt; `scripts/perf-mode.sh` |

---

## 9. Bảo mật & giới hạn

- **Không có đăng nhập**, mặc định `0.0.0.0:5000` — chỉ LAN tin cậy. Ra ngoài: `HOST=127.0.0.1` + Nginx auth / VPN / HTTPS
- HTML upload chạy trong Chromium trên máy chủ — chỉ render nguồn tin cậy
- 1 job render tại một thời điểm; hàng đợi **không** persist sau restart (file trong `outputs/` vẫn còn)
- Phụ đề ước lượng theo ký tự; Edge TTS là dịch vụ không chính thức

---

[Screenshot](screenshot.md) · [English README](README-en.md)
