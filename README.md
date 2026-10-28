# 🎬 HTML2Video

> Chạy trên Orange Pi Rockchip 3588

Công cụ chuyển một **trang HTML hoạt hình chia theo cảnh** kèm **giọng đọc TTS** thành video **MP4**. Công cụ có giao diện web, render song song nhiều tiến trình Chromium, và mã hóa video bằng **CPU / NVIDIA NVENC / Rockchip MPP**. Được tối ưu để chạy trên **Orange Pi 5 Plus (RK3588)**, đồng thời chạy được trên mọi máy chủ Linux x86_64 hoặc ARM64.

---

## Mục lục
1. [Tính năng](#1-tính-năng)
2. [Nguyên tắc hoạt động](#2-nguyên-tắc-hoạt-động)
3. [Định dạng HTML đầu vào](#3-định-dạng-html-đầu-vào)
4. [Cấu trúc thư mục](#4-cấu-trúc-thư-mục)
5. [Triển khai trên Orange Pi 5 Plus](#5-triển-khai-trên-orange-pi-5-plus-rk3588)
6. [Triển khai trên máy chủ Linux khác](#6-triển-khai-trên-máy-chủ-linux-khác)
7. [Cấu hình](#7-cấu-hình)
8. [Sử dụng](#8-sử-dụng)
9. [Tinh chỉnh hiệu năng](#9-tinh-chỉnh-hiệu-năng)
10. [Xử lý sự cố](#10-xử-lý-sự-cố)
11. [Bảo mật khi đưa ra mạng](#11-bảo-mật-khi-đưa-ra-mạng)
12. [Giới hạn đã biết](#12-giới-hạn-đã-biết)

---

## 1. Tính năng
- Upload file `.html` hoặc `.zip` (HTML kèm ảnh, font, CSS). Mỗi dự án được lưu trong một thư mục riêng.
- Xem trước trang theo đúng tỉ lệ khung hình, kèm danh sách cảnh, lời thoại và thời lượng ước tính.
- **TTS:** Edge TTS (online, nhiều giọng tiếng Việt) hoặc **Piper** (offline). Chỉnh được tốc độ đọc.
- **Khung hình** 16:9, 9:16, 4:3. **Độ phân giải** 720p đến 4K. **FPS** 24, 25, 30, 60.
- **Phụ đề** bật/tắt, chia theo câu và đồng bộ với giọng đọc. Luôn xuất kèm file `.srt`.
- **Mã hóa:** libx264/libx265, h264/hevc_nvenc, h264/hevc_rkmpp. Ứng dụng tự kiểm tra encoder nào chạy được trên máy.
- **Render song song** N tiến trình Chromium, chụp khung hình qua CDP, ghép các đoạn mà không mã hóa lại.
- Hàng đợi tác vụ, thanh tiến độ, thời gian còn lại, nút hủy, xem và tải video ngay trên web.

---

## 2. Nguyên tắc hoạt động

### 2.1 Luồng xử lý
```
 Trình duyệt người dùng
        │ upload .html/.zip, chọn tùy chọn
        ▼
 Flask (app.py) ──hàng đợi (1 tác vụ mỗi lúc)──▶ renderer.py
                                                   │
 ① PHÂN TÍCH   Chromium mở trang, đọc mọi <… class="scene" data-say data-t>
 ② TTS         Edge: tối đa 4 cảnh song song. Piper: 1 process, load model 1 lần rồi synth tuần tự
              thời lượng cảnh = max(data-t, 0.5s + độ dài giọng + 1s), làm tròn theo khung hình
              ghép thành audio.wav có độ dài khớp chính xác với tổng số khung hình
 ③ RENDER      chia tổng số khung thành ~3×N đoạn; N tiến trình worker, mỗi worker một Chromium:
                 lặp từng khung g:  tua animation tới thời điểm g → chụp JPEG qua CDP
                                    → đẩy vào ffmpeg (encoder đã chọn) → segXXXX.ts
 ④ GHÉP        ffmpeg concat (-c:v copy, không mã hóa lại) + audio.wav (AAC) → MP4
               sinh file .srt từ mốc thời gian phụ đề
```

### 2.2 "Thời gian ảo": vì sao không giật và chạy song song được
Ứng dụng **không quay màn hình theo thời gian thực**. Với mỗi khung hình `g`, script `__seek()` chèn vào trang sẽ:
1. Bật class `active` cho cảnh `k` chứa khung `g`.
2. Dừng mọi animation (Web Animations API) và đặt `currentTime`:
   - phần tử **trong cảnh hiện tại**: theo thời gian tính từ đầu cảnh `t`;
   - phần tử **bên ngoài** (nền, hiệu ứng chạy liên tục): theo thời gian tổng `T`.
3. Cập nhật phụ đề và thanh tiến độ, sau đó Chromium mới vẽ và chụp khung hình.

Nhờ vậy, máy chậm đến đâu thì video vẫn mượt đúng FPS đã chọn. Mỗi khung hình chỉ phụ thuộc vào chỉ số `g` của nó, nên có thể **chia video cho nhiều Chromium chụp cùng lúc** rồi ghép lại mà không có đường nối.

### 2.3 Đồng bộ âm thanh
- Thời lượng mỗi cảnh được làm tròn thành số nguyên khung hình: `D = n / fps`.
- Âm thanh của cảnh được thêm khoảng lặng ở đầu (0,5 giây), rồi đệm thêm im lặng đến đúng `D`.
- Tổng độ dài âm thanh vì thế bằng đúng `tổng_khung / fps`, nên tiếng không bị lệch dù video dài.

### 2.4 Phụ đề
Lời thoại được chia thành các câu ngắn (tối đa 90 ký tự, hoặc 55 ký tự với khung 9:16). Thời gian hiển thị của mỗi câu tỉ lệ với số ký tự trong tổng thời lượng giọng đọc. Phụ đề được hiển thị qua phần tử `#caption` (tự tạo nếu trang chưa có) và xuất kèm file `.srt`.

### 2.5 Chia việc cho các luồng
- Số đoạn ≈ 3×N, mỗi đoạn tối thiểu 3 giây. Worker nào xong trước thì tự nhận đoạn tiếp theo qua một bộ đếm dùng chung, nên các luồng luôn có việc.
- Mỗi worker là một **tiến trình Python riêng** (multiprocessing kiểu `spawn`) có driver Playwright riêng, nên không bị nghẽn bởi GIL.
- Mỗi worker chỉ khởi động Chromium một lần và dùng lại cho mọi đoạn nó nhận.

### 2.6 Bộ mã hóa
| Lựa chọn | Encoder | Ghi chú |
|---|---|---|
| CPU | `libx264` CRF 18 / `libx265` CRF 20 | Chạy được ở mọi nơi, nhưng tranh CPU với Chromium |
| NVIDIA | `h264_nvenc` / `hevc_nvenc` (VBR, CQ 19/21) | Cần driver và bản FFmpeg có NVENC |
| Rockchip | `h264_rkmpp` / `hevc_rkmpp` (VBR) | Dùng VPU của RK35xx, CPU được dành hết cho Chromium |

> Phần chậm nhất là Chromium vẽ và chụp khung hình, không phải bước mã hóa. Vì vậy **số luồng render** ảnh hưởng tới tốc độ nhiều hơn loại encoder.

---

## 3. Định dạng HTML đầu vào

Yêu cầu tối thiểu:
- Mỗi cảnh là một phần tử có `class="scene"`, với:
  - `data-say="…"`: lời thoại cho TTS (có thể để trống);
  - `data-t="8"`: thời lượng **tối thiểu** của cảnh, tính bằng giây.
- Cảnh đang hiển thị được renderer gán class `active`. CSS cần dựa vào `.scene.active …` để chạy animation.
- Mọi chuyển động phải là **CSS animation hoặc CSS transition**.
- Tùy chọn: phần tử `#progress` (thanh tiến độ, được chỉnh chiều rộng theo %) và `#caption` (khung phụ đề).
- Các phần tử `#start` và `#num` (nếu có) sẽ bị ẩn khi render.

Khung tối thiểu:
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

**Lưu ý quan trọng:** nếu trang có JavaScript tự chuyển cảnh, hãy tắt nó khi bị điều khiển tự động, nếu không nó sẽ xung đột với renderer:
```js
if (!navigator.webdriver) { /* chạy slideshow tự động ở đây */ }
```
Xem ví dụ đầy đủ trong `examples/demo.html`.

**Không hỗ trợ tua:** animation viết bằng `requestAnimationFrame`, canvas/WebGL, GSAP, video `<video>`, GIF. Các nội dung này vẫn hiển thị nhưng không đồng bộ theo thời gian ảo, và có thể bị lệch giữa các đoạn khi render song song.

**Upload dạng .zip:** file HTML chính nên đặt tên `index.html`. Nếu không có, ứng dụng chọn file `.html` nằm nông nhất trong cây thư mục. Dùng đường dẫn tương đối cho ảnh và font.

---

## 4. Cấu trúc thư mục
```
html2video/
├── app.py                 # Web server Flask, API, hàng đợi render
├── renderer.py            # Engine: phân tích → TTS → render song song → ghép
├── bench.py               # Đo tốc độ chụp khung hình theo số luồng
├── requirements.txt
├── install.sh             # Cài đặt tự động (+ systemd khi dùng --service)
├── run.sh                 # Chạy thủ công
├── .env.example           # Mẫu cấu hình biến môi trường
├── static/index.html      # Giao diện web
├── scripts/
│   ├── build-ffmpeg-rockchip.sh   # Build FFmpeg có rkmpp/rkrga
│   ├── perf-mode.sh               # Ép CPU/RAM chạy xung tối đa
│   └── get-piper-voice.sh         # Cài Piper + giọng tiếng Việt
├── examples/demo.html     # Video mẫu 3 cảnh
├── voices/                # Model Piper (*.onnx + *.onnx.json)
├── uploads/               # Dự án đã tải lên
├── outputs/               # MP4 + SRT
└── build/                 # File tạm (tự xóa khi xong; được giữ lại khi lỗi để xem log)
```

---

## 5. Triển khai trên Orange Pi 5 Plus (RK3588)

### 5.1 Chuẩn bị phần cứng và hệ điều hành
| Hạng mục | Khuyến nghị |
|---|---|
| Tản nhiệt | **Bắt buộc có quạt và tản nhiệt**. RK3588 tự hạ xung khi quá nóng nếu render lâu |
| Nguồn | USB-C 5V/4A trở lên |
| Lưu trữ | SSD NVMe (đọc ghi file tạm nhanh hơn nhiều so với thẻ SD) |
| Hệ điều hành | Bản dùng **kernel BSP của Rockchip (5.10 hoặc 6.1)**, ví dụ: Orange Pi Ubuntu 22.04 chính hãng, Armbian (vendor kernel), Ubuntu Rockchip 24.04 (Joshua Riek) |

Kiểm tra kernel có hỗ trợ MPP hay không:
```bash
uname -r
ls -l /dev/mpp_service /dev/rga /dev/dri
```
Nếu **không có `/dev/mpp_service`** (thường gặp với kernel mainline), encoder Rockchip sẽ không chạy được. Ứng dụng vẫn hoạt động với encoder CPU.

### 5.2 Chép mã nguồn lên bo mạch
```bash
# Trên máy tính của bạn
scp html2video.zip orangepi@<IP-ORANGEPI>:~
# Trên Orange Pi
cd ~ && unzip html2video.zip && cd html2video
```

### 5.3 Build FFmpeg có hỗ trợ Rockchip MPP (khoảng 20–40 phút)
```bash
bash scripts/build-ffmpeg-rockchip.sh
```
Script sẽ build `mpp`, `librga` và `ffmpeg-rockchip` (kèm libx264/libx265), cài vào `/usr/local`, đồng thời thêm luật udev cấp quyền cho `/dev/mpp_service` và `/dev/rga`. Sau khi xong, mở file `.env` (tạo ở bước 5.4) và bỏ dấu `#` ở hai dòng:
```
FFMPEG_BIN=/usr/local/bin/ffmpeg
FFPROBE_BIN=/usr/local/bin/ffprobe
```

### 5.4 Cài ứng dụng
```bash
./install.sh --service
```
Script sẽ:
- cài Python venv, font Noto (hỗ trợ tiếng Việt, CJK và emoji), FFmpeg từ apt nếu máy chưa có;
- cài Flask, edge-tts, Playwright, cùng Chromium ARM64 và các thư viện hệ thống đi kèm;
- thêm user hiện tại vào nhóm `video` và `render`;
- tạo service systemd `html2video` chạy dưới user hiện tại, tự bật **chế độ hiệu năng** trước mỗi lần khởi động (`ExecStartPre`).

Nếu không muốn dùng systemd: chạy `./install.sh`, đăng xuất rồi đăng nhập lại, sau đó dùng `./run.sh`.

Quản lý service:
```bash
sudo systemctl status html2video
sudo systemctl restart html2video      # bắt buộc sau khi sửa .env
journalctl -u html2video -f            # xem log
```

### 5.5 Kiểm tra
1. Mở `http://<IP-ORANGEPI>:5000`.
2. Thanh trạng thái phía trên cần hiển thị `FFmpeg ✅ · CPU ✅ · Rockchip ✅`. Nếu vừa sửa `.env`, hãy restart service rồi bấm **↻ Kiểm tra lại**.
3. Upload file `examples/demo.html` và render thử ở 720p.
4. Đo tốc độ để chọn số luồng phù hợp:
   ```bash
   .venv/bin/python bench.py examples/demo.html 1080p
   ```

### 5.6 Piper TTS offline (tùy chọn)
```bash
bash scripts/get-piper-voice.sh
```
Sau đó bấm **↻ Kiểm tra lại** trên giao diện. Service đã có `.venv/bin` trong `PATH`, nên tìm được lệnh `piper`. Nếu cài Piper ở chỗ khác (ví dụ bản binary `piper_linux_aarch64.tar.gz`), khai báo `PIPER_BIN=/đường/dẫn/piper` trong `.env`.

### 5.7 Cấu hình khuyến nghị cho RK3588
| Tùy chọn | Gợi ý |
|---|---|
| Bộ mã hóa | **Rockchip · H.264** (hoặc H.265 nếu muốn file nhỏ hơn) |
| Số luồng | **Tự động (4)**. Dùng `bench.py` để thử thêm 5–6 luồng |
| FPS | 30 |
| Độ phân giải | 1080p. Bật "Chụp 2/3 rồi phóng to" khi cần render nhanh |
| CSS tối ưu | Bật khi render `rockchip.html` (bỏ nền vẽ lại toàn màn hình và hiệu ứng blur) |
| RAM | Mỗi luồng dùng khoảng 0,5–1 GB. Bản 32 GB chạy thoải mái 8 luồng |

### 5.8 Chromium dùng GPU Mali-G610 (thử nghiệm)
Mặc định Chromium vẽ bằng CPU (SwiftShader). Tùy chọn **"Chromium dùng GPU"** chỉ có tác dụng khi hệ thống có driver GPU chạy được với Chromium, thường là **kernel mainline 6.10+ cùng Mesa 24.1+ (driver Panthor)**. Bản BSP dùng libmali thường không chạy được.

Cách kiểm tra:
```bash
.venv/bin/python bench.py examples/demo.html --gpu
```
- Dòng "Bộ dựng hình" hiện **Mali-G610**: GPU đang hoạt động. So sánh fps với lần chạy không có `--gpu`.
- Vẫn hiện **SwiftShader**: GPU không được dùng. Có thể thử bộ cờ khác qua biến `CHROMIUM_GPU_ARGS`.

Lưu ý: kernel mainline có GPU tốt hơn nhưng thường **không có MPP**. Hiện chưa có cấu hình nào vừa dùng được GPU cho Chromium vừa dùng được VPU, nên với RK3588 khuyến nghị **kernel BSP + MPP + render bằng CPU nhiều luồng**.

---

## 6. Triển khai trên máy chủ Linux khác

### 6.1 Máy chủ x86_64 / ARM64 chỉ có CPU
Hỗ trợ Ubuntu 22.04/24.04, Debian 12 và các bản tương đương.
```bash
unzip html2video.zip && cd html2video
./install.sh --service
```
FFmpeg từ apt đã có sẵn libx264 và libx265. Với máy có nhiều lõi, số luồng tự động = số lõi ÷ 2 (tối đa 8). Khi dùng encoder CPU, nên để lại một phần CPU cho x264.

### 6.2 Máy chủ có GPU NVIDIA
1. Cài driver NVIDIA và kiểm tra bằng `nvidia-smi`.
2. Kiểm tra FFmpeg có NVENC: `ffmpeg -hide_banner -encoders | grep nvenc`. Gói FFmpeg của Ubuntu/Debian thường đã có sẵn.
   - Nếu chưa có, tải bản static của BtbN (`ffmpeg-master-latest-linux64-gpl.tar.xz`), giải nén vào `/opt/ffmpeg`, rồi đặt `FFMPEG_BIN=/opt/ffmpeg/bin/ffmpeg` và `FFPROBE_BIN=/opt/ffmpeg/bin/ffprobe` trong `.env`.
3. Restart service và bấm **↻ Kiểm tra lại**. Nút NVIDIA sẽ được bật.
4. Card GeForce giới hạn số phiên NVENC chạy đồng thời (khoảng 8 phiên với driver mới), nên **số luồng không được vượt quá giới hạn này**.
5. Nếu FFmpeg quá cũ, báo lỗi preset `p5`: sửa `"p5"` thành `"slow"` trong hàm `video_args()` của `renderer.py`.

### 6.3 Chạy trong Docker hoặc máy ảo (gợi ý)
- Chromium cần bộ nhớ chia sẻ lớn: thêm `--ipc=host` hoặc `--shm-size=2g`.
- Dùng image nền `mcr.microsoft.com/playwright/python:v1.49.0-jammy` (có bản cho arm64).
- Muốn dùng VPU Rockchip trong container: `--device /dev/mpp_service --device /dev/rga --device /dev/dri --device /dev/dma_heap`, và FFmpeg trong container phải là bản ffmpeg-rockchip.
- Muốn dùng NVIDIA: cài NVIDIA Container Toolkit và chạy với `--gpus all`.

### 6.4 Bản phân phối không dùng apt
`install.sh` dùng `apt-get`. Với Fedora, Arch… hãy cài thủ công:
1. Cài python3, venv, ffmpeg và font Noto bằng trình quản lý gói của bản phân phối.
2. Chạy:
   ```bash
   python3 -m venv .venv
   .venv/bin/pip install -r requirements.txt
   .venv/bin/python -m playwright install chromium
   ```
3. Cài các thư viện Chromium cần (xem lỗi khi khởi chạy lần đầu).
4. Chạy `./run.sh`.

---

## 7. Cấu hình
Sửa file `.env` (được tạo từ `.env.example`), rồi chạy `sudo systemctl restart html2video`.

| Biến | Mặc định | Ý nghĩa |
|---|---|---|
| `HOST` / `PORT` | `0.0.0.0` / `5000` | Địa chỉ và cổng web |
| `FFMPEG_BIN` / `FFPROBE_BIN` | `ffmpeg` / `ffprobe` | Đường dẫn FFmpeg (vd: bản ffmpeg-rockchip) |
| `PIPER_BIN` | `piper` | Fallback native binary (chỉ dùng khi không có `piper-tts` trong venv) |
| `PIPER_CONCURRENCY` | `1` | Số synth Piper cùng lúc. **Giữ = 1** trên RK3588; >1 từng làm board hard-reboot. Clone thư mục binary **không** giúp — mỗi process vẫn load full ONNX |
| `PIPER_ORT_THREADS` / `PIPER_OMP_THREADS` | `2` / `2` | Giới hạn thread onnxruntime/OpenMP cho Piper in-process |
| `CHROMIUM_ARGS` | (trống) | Cờ bổ sung cho mọi tiến trình Chromium |
| `CHROMIUM_GPU_ARGS` | ANGLE/GLES | Cờ dùng khi bật "Chromium dùng GPU" |

Các hằng số khác nằm trong `renderer.py`: `lead`/`tail` (khoảng lặng đầu và cuối cảnh), `jpeg_quality`, tham số bitrate và CRF trong `video_args()`. Giới hạn upload (200 MB) nằm trong `app.py`.

---

## 8. Sử dụng

### 8.1 Giao diện web
1. Kéo thả file `.html` hoặc `.zip` vào khung **Dự án**.
2. Kiểm tra khung xem trước và bảng cảnh/lời thoại.
3. Chọn TTS, giọng đọc, tốc độ, khung hình, độ phân giải, FPS, số luồng, phụ đề, encoder và codec.
4. (Tùy chọn) Nhập **CSS bổ sung**, ví dụ để chỉnh bố cục cho khung 9:16. Khung xem trước cập nhật ngay.
5. Bấm **🚀 Render MP4**. Theo dõi tiến độ trong **Hàng đợi**, sau đó xem hoặc tải MP4/SRT.

### 8.2 API (dùng cho script tự động)
| Phương thức | Đường dẫn | Mô tả |
|---|---|---|
| GET | `/api/capabilities[?refresh=1]` | Encoder khả dụng, Piper, số CPU |
| GET | `/api/voices` | Danh sách giọng Edge |
| GET / POST | `/api/projects` / `/api/upload` (multipart, trường `file`) | Liệt kê / tải lên dự án |
| GET / DELETE | `/api/projects/<id>` | Chi tiết (danh sách cảnh) / xóa dự án |
| POST | `/api/render` (JSON) | Tạo tác vụ render |
| GET | `/api/jobs` | Trạng thái các tác vụ |
| POST | `/api/jobs/<id>/cancel` | Hủy tác vụ |
| GET / DELETE | `/api/outputs`, `/outputs/<file>[?dl=1]` | Liệt kê, tải, xóa video |

Ví dụ:
```bash
curl -F file=@examples/demo.html http://localhost:5000/api/upload
curl -X POST http://localhost:5000/api/render -H 'Content-Type: application/json' -d '{
  "project":"demo-20250101-120000","tts":"edge","voice":"vi-VN-HoaiMyNeural","rate":5,
  "aspect":"16:9","resolution":"1080p","fps":30,"subtitles":true,
  "encoder":"rockchip","codec":"h264","workers":0,"upscale":false,"chromium_gpu":false}'
```

---

## 9. Tinh chỉnh hiệu năng
- **Số luồng** ảnh hưởng nhiều nhất. Dùng `bench.py` để tìm điểm mà tăng thêm luồng không còn nhanh hơn. Trên RK3588 thường là 4–6 luồng.
- **Encoder phần cứng** (rkmpp, nvenc) giải phóng CPU cho Chromium.
- **CSS nặng làm chậm rõ rệt:**
  - tránh animation `background-position`, `width`, `top`/`left`, `box-shadow` lớn; dùng `transform` và `opacity` thay thế;
  - tránh `backdrop-filter`, `filter: blur()` diện tích lớn;
  - hạn chế các lớp nền phủ toàn màn hình có chuyển động.
- **Chụp 2/3 rồi phóng to:** số điểm ảnh cần vẽ giảm 2,25 lần, chữ hơi mềm hơn một chút.
- **Chế độ hiệu năng:** `sudo scripts/perf-mode.sh` (service đã tự chạy script này). Theo dõi nhiệt độ bằng `watch -n2 cat /sys/class/thermal/thermal_zone*/temp`.
- FPS 60 tốn gấp đôi thời gian so với 30. 4K tốn gấp 4 lần so với 1080p.

---

## 10. Xử lý sự cố
| Hiện tượng | Nguyên nhân / Cách khắc phục |
|---|---|
| Rockchip ❌ dù đã build ffmpeg-rockchip | Chưa đặt `FFMPEG_BIN` trong `.env` hoặc chưa restart service; thiếu quyền `/dev/mpp_service` (kiểm tra `groups`, luật udev); kernel không phải BSP |
| `Edge TTS lỗi` | Mất Internet hoặc bị chặn kết nối. Chuyển sang Piper |
| Board reboot / crash khi chọn Piper | Đừng chạy nhiều process Piper song song (kể cả clone `piper-tts-cpu2`). Mỗi process load ~60 MB ONNX + ORT. Code hiện load model **1 lần trong process** rồi synth tuần tự. Restart service sau cập nhật. **Không** tăng `PIPER_CONCURRENCY` trên RK3588 |
| `Piper lỗi (… size=0)` / WAV rỗng | Lần chạy trước bị cắt giữa chừng (reboot), để lại `build/*/raw*.wav` rỗng. Xóa job đó và chạy lại; ưu tiên `piper-tts` trong `.venv` (warm). `PIPER_BIN` chỉ là fallback |
| Chữ tiếng Việt hoặc emoji hiển thị thành ô vuông | Thiếu font: `sudo apt install fonts-noto-core fonts-noto-color-emoji fonts-noto-cjk` |
| `Executable doesn't exist` / Chromium không chạy | Chạy lại `.venv/bin/python -m playwright install chromium` **bằng đúng user chạy service** |
| Lỗi thiếu thư viện `.so` của Chromium | `sudo .venv/bin/python -m playwright install-deps chromium` |
| "Một tiến trình render dừng bất thường" | Thiếu RAM hoặc Chromium crash. Giảm số luồng hoặc độ phân giải, xem `journalctl -u html2video` |
| Video bị giật hoặc animation không chạy | Animation dùng JavaScript/rAF/canvas (không tua được). Chuyển sang CSS animation |
| Cảnh nhảy lung tung khi render | Script của trang tự chuyển cảnh. Bọc slideshow trong `if (!navigator.webdriver)` |
| Lỗi FFmpeg khi mã hóa | Xem `build/<job-id>/ff*.log` (thư mục được giữ lại khi lỗi) |
| Render chậm dần theo thời gian | Chip quá nóng nên hạ xung. Cải thiện tản nhiệt và kiểm tra nhiệt độ |
| Tác vụ biến mất sau khi restart | Hàng đợi chỉ lưu trong RAM. Video đã render vẫn còn trong `outputs/` |

---

## 11. Bảo mật khi đưa ra mạng
Ứng dụng **không có đăng nhập** và chạy `0.0.0.0:5000`. Chỉ dùng trong mạng LAN tin cậy. Nếu cần truy cập từ xa, hãy đặt `HOST=127.0.0.1` và dùng Nginx làm reverse proxy có xác thực:
```bash
sudo apt install nginx apache2-utils
sudo htpasswd -c /etc/nginx/.htpasswd admin
```
```nginx
server {
    listen 80;
    server_name _;
    client_max_body_size 200m;
    location / {
        auth_basic "HTML2Video";
        auth_basic_user_file /etc/nginx/.htpasswd;
        proxy_pass http://127.0.0.1:5000;
        proxy_set_header Host $host;
        proxy_read_timeout 600s;
    }
}
```
Nên bật HTTPS (ví dụ certbot) hoặc truy cập qua VPN (Tailscale, WireGuard).

Lưu ý thêm: file HTML upload được chạy trong Chromium trên máy chủ. Chỉ render file từ nguồn tin cậy.

---

## 12. Giới hạn đã biết
- Mỗi lúc chỉ render một tác vụ (các tác vụ khác xếp hàng). Mỗi tác vụ dùng N luồng.
- Chỉ tua được CSS animation và transition.
- Thời điểm phụ đề được ước lượng theo số ký tự, không phải theo mốc thời gian từng từ.
- Edge TTS là dịch vụ không chính thức của Microsoft, có thể thay đổi bất kỳ lúc nào. Cân nhắc trước khi dùng cho mục đích thương mại.
- Hàng đợi tác vụ không được lưu lại sau khi khởi động lại service.
