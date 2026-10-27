#!/usr/bin/env bash
# make_html2video.sh – Tạo thư mục dự án html2video/ và file html2video.zip
set -e
ROOT="html2video"
mkdir -p "$ROOT"/{static,voices,examples,scripts,uploads,outputs,build}
cd "$ROOT"
touch voices/.gitkeep uploads/.gitkeep outputs/.gitkeep build/.gitkeep

# =====================================================================
cat > requirements.txt <<'__EOF__'
flask>=3.0
edge-tts>=6.1
playwright>=1.49
# Tùy chọn – TTS offline:
# piper-tts
__EOF__

# =====================================================================
cat > .gitignore <<'__EOF__'
.venv/
__pycache__/
uploads/*
outputs/*
build/*
voices/*.onnx
voices/*.onnx.json
!*/.gitkeep
.env
__EOF__

# =====================================================================
cat > .env.example <<'__EOF__'
# Sao chép thành file .env rồi chỉnh. File .env được cả run.sh và systemd service đọc.
PORT=5000
HOST=0.0.0.0

# Dùng bản ffmpeg-rockchip đã build (scripts/build-ffmpeg-rockchip.sh)
#FFMPEG_BIN=/usr/local/bin/ffmpeg
#FFPROBE_BIN=/usr/local/bin/ffprobe

# Đường dẫn Piper nếu không nằm trong PATH
#PIPER_BIN=/opt/piper/piper

# Cờ bổ sung cho Chromium (cách nhau bởi dấu cách)
#CHROMIUM_ARGS=
#CHROMIUM_GPU_ARGS="--ignore-gpu-blocklist --enable-gpu-rasterization --use-gl=angle --use-angle=gles"
__EOF__

# =====================================================================
cat > run.sh <<'__EOF__'
#!/usr/bin/env bash
# Chạy thủ công (không dùng systemd)
cd "$(dirname "$0")"
if [ -f .env ]; then set -a; . ./.env; set +a; fi
export PATH="$PWD/.venv/bin:$PATH"
exec .venv/bin/python app.py
__EOF__

# =====================================================================
cat > install.sh <<'__EOF__'
#!/usr/bin/env bash
# Cài đặt HTML2Video trên Ubuntu / Debian / Armbian (x86_64 hoặc ARM64)
#   ./install.sh            cài gói hệ thống + venv + Chromium
#   ./install.sh --service  cài thêm systemd service (tự chạy khi khởi động)
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"
if [ "$(id -u)" -eq 0 ]; then
  echo "❌ Hãy chạy bằng user thường, không dùng sudo (script tự gọi sudo khi cần)."; exit 1
fi

echo "==> [1/5] Cài gói hệ thống"
sudo apt-get update
sudo apt-get install -y python3 python3-venv python3-pip unzip curl \
  fonts-noto-core fonts-noto-cjk fonts-noto-color-emoji fonts-dejavu-core
if command -v ffmpeg >/dev/null 2>&1; then
  echo "    Đã có ffmpeg: $(command -v ffmpeg)"
else
  sudo apt-get install -y ffmpeg
fi

echo "==> [2/5] Tạo môi trường Python (.venv)"
python3 -m venv .venv
.venv/bin/pip install -U pip wheel
.venv/bin/pip install -r requirements.txt

echo "==> [3/5] Cài Chromium cho Playwright"
sudo "$DIR/.venv/bin/python" -m playwright install-deps chromium \
  || echo "⚠ install-deps lỗi một phần (thường gặp trên Armbian), vẫn tiếp tục…"
.venv/bin/python -m playwright install chromium

echo "==> [4/5] Quyền truy cập thiết bị video và thư mục làm việc"
for g in video render; do
  if getent group "$g" >/dev/null; then sudo usermod -aG "$g" "$USER"; fi
done
mkdir -p uploads outputs build voices
[ -f .env ] || cp .env.example .env
chmod +x run.sh scripts/*.sh

if [ "${1:-}" = "--service" ]; then
  echo "==> [5/5] Cài systemd service html2video"
  sudo tee /etc/systemd/system/html2video.service >/dev/null <<EOF
[Unit]
Description=HTML2Video
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$USER
WorkingDirectory=$DIR
Environment=PYTHONUNBUFFERED=1
Environment=PATH=$DIR/.venv/bin:/usr/local/bin:/usr/bin:/bin
EnvironmentFile=-$DIR/.env
ExecStartPre=-+$DIR/scripts/perf-mode.sh
ExecStart=$DIR/.venv/bin/python $DIR/app.py
Restart=on-failure
RestartSec=5
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
EOF
  sudo systemctl daemon-reload
  sudo systemctl enable --now html2video
  echo "    Xem log: journalctl -u html2video -f"
else
  echo "==> [5/5] Bỏ qua systemd. Chạy thủ công bằng: ./run.sh"
  echo "    (Đăng xuất rồi đăng nhập lại để quyền nhóm video/render có hiệu lực)"
fi

IP=$(hostname -I 2>/dev/null | awk '{print $1}')
echo "✅ Hoàn tất. Mở http://${IP:-localhost}:5000"
__EOF__

# =====================================================================
cat > scripts/perf-mode.sh <<'__EOF__'
#!/usr/bin/env bash
# Ép CPU và RAM chạy xung tối đa (cần quyền root). Cài đặt sẽ mất sau khi khởi động lại.
for f in /sys/devices/system/cpu/cpufreq/policy*/scaling_governor; do
  [ -w "$f" ] && echo performance > "$f"
done
[ -w /sys/class/devfreq/dmc/governor ] && echo performance > /sys/class/devfreq/dmc/governor
exit 0
__EOF__

# =====================================================================
cat > scripts/build-ffmpeg-rockchip.sh <<'__EOF__'
#!/usr/bin/env bash
# Build ffmpeg-rockchip (nyanmisaka) với MPP + RGA + libx264/libx265 cho RK3588/RK3576/RK3568.
# Yêu cầu kernel BSP của Rockchip (có /dev/mpp_service). Thời gian build khoảng 20–40 phút.
set -euo pipefail
[ -e /dev/mpp_service ] || echo "⚠ Không thấy /dev/mpp_service: kernel hiện tại có thể không phải BSP, encoder rkmpp sẽ không chạy."
SRC="${SRC:-$HOME/src/ffmpeg-rockchip}"
mkdir -p "$SRC" && cd "$SRC"

sudo apt-get update
sudo apt-get install -y git build-essential cmake meson ninja-build pkg-config \
  libdrm-dev libx264-dev libx265-dev

echo "==> [1/4] MPP"
[ -d rkmpp ] || git clone -b jellyfin-mpp --depth=1 https://github.com/nyanmisaka/mpp.git rkmpp
cmake -S rkmpp -B rkmpp/build -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=ON -DBUILD_TEST=OFF
cmake --build rkmpp/build -j"$(nproc)"
sudo cmake --install rkmpp/build

echo "==> [2/4] RGA"
[ -d rkrga ] || git clone -b jellyfin-rga --depth=1 https://github.com/nyanmisaka/rk-mirrors.git rkrga
[ -d rkrga_build ] || meson setup rkrga rkrga_build --prefix=/usr --libdir=lib --buildtype=release \
  --default-library=shared -Dcpp_args=-fpermissive -Dlibdrm=false -Dlibrga_demo=false
sudo ninja -C rkrga_build install

echo "==> [3/4] FFmpeg"
[ -d ffmpeg ] || git clone --depth=1 https://github.com/nyanmisaka/ffmpeg-rockchip.git ffmpeg
cd ffmpeg
./configure --prefix=/usr/local --enable-gpl --enable-version3 --enable-libdrm \
  --enable-rkmpp --enable-rkrga --enable-libx264 --enable-libx265 --disable-doc
make -j"$(nproc)"
sudo make install
sudo ldconfig

echo "==> [4/4] Quyền truy cập thiết bị (udev)"
sudo tee /etc/udev/rules.d/99-rockchip-media.rules >/dev/null <<'EOF'
KERNEL=="mpp_service", MODE="0660", GROUP="video"
KERNEL=="rga", MODE="0660", GROUP="video"
SUBSYSTEM=="dma_heap", MODE="0666"
EOF
sudo udevadm control --reload-rules && sudo udevadm trigger || true

echo
/usr/local/bin/ffmpeg -hide_banner -encoders 2>/dev/null | grep rkmpp || echo "⚠ Không thấy encoder rkmpp"
echo "✅ Xong. Thêm vào file .env:"
echo "   FFMPEG_BIN=/usr/local/bin/ffmpeg"
echo "   FFPROBE_BIN=/usr/local/bin/ffprobe"
__EOF__

# =====================================================================
cat > scripts/get-piper-voice.sh <<'__EOF__'
#!/usr/bin/env bash
# Cài Piper vào .venv và tải giọng tiếng Việt vi_VN-vais1000-medium vào thư mục voices/
set -euo pipefail
cd "$(dirname "$0")/.."
.venv/bin/pip install piper-tts
B=https://huggingface.co/rhasspy/piper-voices/resolve/main/vi/vi_VN/vais1000/medium
for f in vi_VN-vais1000-medium.onnx vi_VN-vais1000-medium.onnx.json; do
  [ -f "voices/$f" ] || curl -L -o "voices/$f" "$B/$f"
done
echo "✅ Đã tải xong. Bấm '↻ Kiểm tra lại' trên giao diện web để bật lựa chọn Piper."
__EOF__

# =====================================================================
cat > examples/demo.html <<'__EOF__'
<!DOCTYPE html>
<html lang="vi">
<head>
<meta charset="UTF-8">
<title>Demo HTML2Video</title>
<style>
body{margin:0;background:#0b1020;color:#fff;font-family:"Noto Sans",sans-serif;overflow:hidden;height:100vh}
.scene{position:absolute;inset:0;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:4vmin;opacity:0}
.scene.active{opacity:1}
.a{opacity:0}
.scene.active .a{animation:up .8s ease-out forwards;animation-delay:var(--d,0s)}
@keyframes up{from{opacity:0;transform:translateY(40px)}to{opacity:1;transform:none}}
h1{font-size:8vmin;margin:0;background:linear-gradient(90deg,#00c2ff,#7b5cff);-webkit-background-clip:text;color:transparent}
p{font-size:4.5vmin;color:#9fb6d9;margin:0;text-align:center}
.box{width:22vmin;height:22vmin;border-radius:3vmin;background:linear-gradient(135deg,#00c2ff,#7b5cff)}
.scene.active .spin{animation:spin 3s linear infinite}
@keyframes spin{to{transform:rotate(360deg)}}
#progress{position:fixed;left:0;bottom:0;height:6px;width:0;background:#00c2ff}
</style>
</head>
<body>
<section class="scene active" data-t="4" data-say="Xin chào! Đây là video thử nghiệm của HTML2Video.">
  <h1 class="a">HTML2Video</h1>
  <p class="a" style="--d:.5s">Video thử nghiệm</p>
</section>
<section class="scene" data-t="5" data-say="Mỗi cảnh là một thẻ section có class scene. Lời thoại nằm trong thuộc tính data say.">
  <div class="box spin"></div>
  <p class="a" style="--d:.3s">Mỗi cảnh = &lt;section class="scene" data-say="…"&gt;</p>
</section>
<section class="scene" data-t="4" data-say="Chúc bạn render vui vẻ trên Orange Pi 5 Plus!">
  <h1 class="a">Hoàn tất 🎉</h1>
</section>
<div id="progress"></div>
<script>
// Khi xem bình thường thì tự chuyển cảnh. Khi bị Playwright điều khiển (lúc render) thì không làm gì.
if (!navigator.webdriver) {
  const sc = [...document.querySelectorAll('.scene')]; let i = 0;
  const next = () => { sc.forEach(s => s.classList.remove('active')); sc[i].classList.add('active');
    setTimeout(() => { i = (i + 1) % sc.length; next(); }, (+sc[i].dataset.t || 5) * 1000); };
  next();
}
</script>
</body>
</html>
__EOF__

# =====================================================================
cat > renderer.py <<'__EOF__'
"""
renderer.py (v2) – HTML + TTS → MP4, render song song nhiều tiến trình Chromium.

  1. Đọc danh sách cảnh, tạo giọng đọc song song, tính thời lượng từng cảnh.
  2. Chia video thành nhiều đoạn khung hình. N tiến trình worker (mỗi worker một Chromium riêng)
     lần lượt nhận đoạn, tua tới đúng thời điểm, chụp qua CDP và mã hóa đoạn đó.
  3. Ghép các đoạn bằng concat (không mã hóa lại) và trộn âm thanh.
"""
import asyncio
import base64
import bisect
import math
import multiprocessing as mp
import os
import re
import shutil
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Optional

import edge_tts
from playwright.async_api import async_playwright

FFMPEG = os.environ.get("FFMPEG_BIN", "ffmpeg")
FFPROBE = os.environ.get("FFPROBE_BIN", "ffprobe")
PIPER = os.environ.get("PIPER_BIN", "piper")

ASPECTS = {"16:9": (1280, 720), "9:16": (720, 1280), "4:3": (960, 720)}
SCALES = {"720p": 1.0, "1080p": 1.5, "1440p": 2.0, "2160p": 3.0}
ENCODERS = {
    "cpu":      {"h264": "libx264",    "hevc": "libx265"},
    "nvidia":   {"h264": "h264_nvenc", "hevc": "hevc_nvenc"},
    "rockchip": {"h264": "h264_rkmpp", "hevc": "hevc_rkmpp"},
}
FALLBACK_VOICES = [
    {"id": "vi-VN-HoaiMyNeural", "locale": "vi-VN", "gender": "Female"},
    {"id": "vi-VN-NamMinhNeural", "locale": "vi-VN", "gender": "Male"},
    {"id": "en-US-AriaNeural", "locale": "en-US", "gender": "Female"},
    {"id": "en-US-GuyNeural", "locale": "en-US", "gender": "Male"},
]

# ---------------------------------------------------------------- cờ Chromium
BASE_ARGS = [
    "--hide-scrollbars", "--mute-audio", "--disable-extensions",
    "--disable-background-timer-throttling", "--disable-renderer-backgrounding",
    "--disable-backgrounding-occluded-windows", "--disable-features=PaintHolding",
    "--force-color-profile=srgb",
]
GPU_ARGS = os.environ.get(
    "CHROMIUM_GPU_ARGS",
    "--ignore-gpu-blocklist --enable-gpu-rasterization --use-gl=angle --use-angle=gles").split()
EXTRA_ARGS = os.environ.get("CHROMIUM_ARGS", "").split()


def launch_kwargs(gpu: bool = False) -> dict:
    kw = {"args": BASE_ARGS + (GPU_ARGS if gpu else []) + EXTRA_ARGS}
    if gpu:
        kw["channel"] = "chromium"      # chế độ headless mới (Chromium đầy đủ), cần Playwright >= 1.49
    return kw


def auto_workers() -> int:
    """RK3588 có 8 lõi (4×A76 + 4×A55) → 4 luồng."""
    return max(1, min(8, (os.cpu_count() or 2) // 2))


class Cancelled(Exception):
    pass


# ---------------------------------------------------------------- tiện ích
def run(cmd):
    r = subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    if r.returncode != 0:
        tail = r.stderr.decode(errors="ignore").strip().splitlines()[-6:]
        raise RuntimeError(f"Lỗi khi chạy {Path(cmd[0]).name}:\n" + "\n".join(tail))


def probe(path) -> float:
    out = subprocess.check_output([FFPROBE, "-v", "error", "-show_entries", "format=duration",
                                   "-of", "csv=p=0", str(path)])
    return float(out.decode().strip())


def fmt_time(sec: float) -> str:
    m, s = divmod(int(sec), 60)
    return f"{m}:{s:02d}"


# ---------------------------------------------------------------- năng lực hệ thống
def test_encoder(encoder: str, codec: str) -> bool:
    name = ENCODERS[encoder][codec]
    pix = "nv12" if encoder == "rockchip" else "yuv420p"
    try:
        r = subprocess.run([FFMPEG, "-hide_banner", "-v", "error", "-f", "lavfi",
                            "-i", "color=c=black:s=1280x720:r=30", "-frames:v", "15",
                            "-pix_fmt", pix, "-c:v", name, "-f", "null", "-"],
                           capture_output=True, timeout=40)
        return r.returncode == 0
    except Exception:
        return False


def list_piper_models(voices_dir: Path):
    return sorted(p.name for p in Path(voices_dir).glob("*.onnx")
                  if p.with_suffix(".onnx.json").exists())


def detect_capabilities(voices_dir: Path) -> dict:
    ffmpeg_ok = shutil.which(FFMPEG) is not None and shutil.which(FFPROBE) is not None
    enc = {e: {c: bool(ffmpeg_ok and test_encoder(e, c)) for c in ENCODERS[e]} for e in ENCODERS}
    return {
        "ffmpeg": ffmpeg_ok, "ffmpeg_bin": FFMPEG, "encoders": enc,
        "piper": shutil.which(PIPER) is not None,
        "piper_models": list_piper_models(voices_dir),
        "cpus": os.cpu_count() or 1, "auto_workers": auto_workers(),
    }


_voice_cache = None


def edge_voices():
    global _voice_cache
    if _voice_cache is None:
        try:
            vs = asyncio.run(edge_tts.list_voices())
            _voice_cache = sorted(
                ({"id": v["ShortName"], "locale": v["Locale"], "gender": v["Gender"]} for v in vs),
                key=lambda v: (not v["locale"].startswith("vi"), v["locale"], v["id"]))
        except Exception:
            return FALLBACK_VOICES
    return _voice_cache


# ---------------------------------------------------------------- tham số encoder
def video_args(encoder: str, codec: str, W: int, H: int, fps: int):
    hevc = codec == "hevc"
    if encoder == "cpu":
        if hevc:
            return ["-c:v", "libx265", "-preset", "medium", "-crf", "20", "-pix_fmt", "yuv420p"]
        return ["-c:v", "libx264", "-preset", "medium", "-crf", "18", "-pix_fmt", "yuv420p"]
    if encoder == "nvidia":
        return ["-c:v", "hevc_nvenc" if hevc else "h264_nvenc", "-preset", "p5", "-tune", "hq",
                "-rc", "vbr", "-cq", "21" if hevc else "19", "-b:v", "0", "-pix_fmt", "yuv420p"]
    if encoder == "rockchip":
        br = int(W * H * fps * (0.08 if hevc else 0.12))
        return ["-c:v", "hevc_rkmpp" if hevc else "h264_rkmpp", "-rc_mode", "VBR",
                "-b:v", str(br), "-maxrate", str(int(br * 1.5)), "-pix_fmt", "nv12"]
    raise ValueError(encoder)


def tag_args(codec: str):
    return ["-tag:v", "hvc1"] if codec == "hevc" else []


async def shot_params(cdp, quality: int) -> dict:
    """Tham số chụp CDP. Thử optimizeForSpeed, bỏ đi nếu bản Chromium không hỗ trợ."""
    shot = {"format": "jpeg", "quality": quality, "fromSurface": True,
            "captureBeyondViewport": False, "optimizeForSpeed": True}
    try:
        await cdp.send("Page.captureScreenshot", shot)
    except Exception:
        shot.pop("optimizeForSpeed")
    return shot


# ---------------------------------------------------------------- phụ đề
def split_chunks(text: str, maxlen: int = 90):
    parts = re.split(r"(?<=[.!?;:…])\s+", text.strip())
    out = []
    for p in parts:
        while len(p) > maxlen:
            cut = p.rfind(", ", 0, maxlen)
            if cut < maxlen * 0.4:
                cut = p.rfind(" ", 0, maxlen)
            if cut <= 0:
                cut = maxlen
            out.append(p[:cut + 1].strip())
            p = p[cut + 1:].strip()
        if p:
            out.append(p)
    return out


def timed_cues(chunks, start: float, dur: float):
    total = sum(len(c) for c in chunks) or 1
    t, cues = start, []
    for c in chunks:
        d = dur * len(c) / total
        cues.append((t, t + d, c))
        t += d
    return cues


def current_cue(cues, t: float) -> str:
    txt = cues[0][2] if cues else ""
    for s, _, c in cues:
        if t >= s:
            txt = c
        else:
            break
    return txt


def write_srt(path: Path, plan):
    def ts(x):
        ms = int(round(x * 1000))
        h, ms = divmod(ms, 3600000)
        m, ms = divmod(ms, 60000)
        s, ms = divmod(ms, 1000)
        return f"{h:02d}:{m:02d}:{s:02d},{ms:03d}"
    lines, n, T0 = [], 1, 0.0
    for sc in plan:
        for s, e, c in sc["cues"]:
            lines.append(f"{n}\n{ts(T0 + s)} --> {ts(T0 + e)}\n{c}\n")
            n += 1
        T0 += sc["D"]
    path.write_text("\n".join(lines), encoding="utf-8")


# ---------------------------------------------------------------- JS điều khiển trang
RENDER_JS = r"""
window.__setup = () => {
  for (const id of ['start', 'num']) { const e = document.getElementById(id); if (e) e.style.display = 'none'; }
  const st = document.createElement('style');
  st.textContent = '.scene{transition:none!important}::-webkit-scrollbar{display:none}';
  document.head.appendChild(st);
  let c = document.getElementById('caption');
  if (!c) {
    c = document.createElement('div'); c.id = 'caption';
    c.style.cssText = 'position:fixed;left:50%;bottom:4%;transform:translateX(-50%);max-width:88%;' +
      'text-align:center;font:600 clamp(14px,2.4vmin,40px)/1.45 sans-serif;color:#fff;' +
      'background:rgba(0,0,0,.6);padding:.4em .9em;border-radius:10px;z-index:99999';
    document.body.appendChild(c);
  }
  c.style.transition = 'none';
  window.__cur = -1; window.__cap = null;
};
window.__seek = (k, t, T, cap, prog) => {
  const scenes = [...document.querySelectorAll('.scene')];
  if (window.__cur !== k) {
    scenes.forEach(s => s.classList.remove('active'));
    scenes[k].classList.add('active');
    window.__cur = k;
  }
  if (window.__cap !== cap) {
    const c = document.getElementById('caption');
    c.textContent = cap; c.style.opacity = cap ? 1 : 0; c.style.visibility = cap ? 'visible' : 'hidden';
    window.__cap = cap;
  }
  const s = scenes[k];
  for (const a of document.getAnimations()) {
    a.pause();
    const el = a.effect && a.effect.target;
    a.currentTime = (el && s.contains(el)) ? t * 1000 : T * 1000;
  }
  const p = document.getElementById('progress');
  if (p) p.style.width = prog + '%';
};
"""


# ---------------------------------------------------------------- cấu hình
@dataclass
class RenderConfig:
    html: Path
    out: Path
    work: Path
    tts: str = "edge"
    voice: str = "vi-VN-HoaiMyNeural"
    piper_model: Optional[Path] = None
    rate: int = 5
    aspect: str = "16:9"
    resolution: str = "1080p"
    fps: int = 30
    subtitles: bool = True
    encoder: str = "cpu"
    codec: str = "h264"
    extra_css: str = ""
    lead: float = 0.5
    tail: float = 1.0
    workers: int = 0            # 0 = tự động
    upscale: bool = False       # chụp ở 2/3 độ phân giải rồi phóng to
    gpu: bool = False           # Chromium dùng GPU (thử nghiệm)
    jpeg_quality: int = 90


# ---------------------------------------------------------------- bước 1: TTS song song
async def _synth(cfg: RenderConfig, text: str, k: int, out_wav: Path):
    if cfg.tts == "edge":
        raw = cfg.work / f"raw{k:02d}.mp3"
        for attempt in range(3):
            try:
                await edge_tts.Communicate(text, cfg.voice, rate=f"{cfg.rate:+d}%").save(str(raw))
                break
            except Exception as e:
                if attempt == 2:
                    raise RuntimeError(f"Edge TTS lỗi (kiểm tra kết nối Internet): {e}")
                await asyncio.sleep(2)
        af = "aresample=48000"
    else:
        raw = cfg.work / f"raw{k:02d}.wav"
        r = await asyncio.to_thread(subprocess.run, [PIPER, "-m", str(cfg.piper_model), "-f", str(raw)],
                                    input=text.encode("utf-8"), capture_output=True)
        if r.returncode != 0 or not raw.exists():
            raise RuntimeError("Piper lỗi: " + r.stderr.decode(errors="ignore")[-500:])
        tempo = min(2.0, max(0.5, 1 + cfg.rate / 100))
        af = f"atempo={tempo:.3f},aresample=48000" if abs(tempo - 1) > 1e-3 else "aresample=48000"
    await asyncio.to_thread(run, [FFMPEG, "-y", "-i", str(raw), "-af", af, "-ac", "2", str(out_wav)])


async def _prepare(cfg: RenderConfig, progress, check):
    bw, bh = ASPECTS[cfg.aspect]
    async with async_playwright() as p:
        browser = await p.chromium.launch(**launch_kwargs(False))
        try:
            page = await browser.new_page(viewport={"width": bw, "height": bh})
            await page.goto(cfg.html.resolve().as_uri(), wait_until="networkidle")
            scenes = await page.evaluate(
                "[...document.querySelectorAll('.scene')]"
                ".map(s => ({say: s.dataset.say || '', t: parseFloat(s.dataset.t) || 8}))")
        finally:
            await browser.close()
    if not scenes:
        raise RuntimeError('Không tìm thấy phần tử class="scene" nào trong file HTML.')

    fps, maxlen = cfg.fps, (55 if cfg.aspect == "9:16" else 90)
    sem, done = asyncio.Semaphore(4), [0]

    async def one(k, s):
        async with sem:
            check()
            text = s["say"].strip()
            seg = cfg.work / f"aud{k:02d}.wav"
            speech = 0.0
            if text:
                voice = cfg.work / f"voice{k:02d}.wav"
                await _synth(cfg, text, k, voice)
                speech = await asyncio.to_thread(probe, voice)
                D = max(s["t"], cfg.lead + speech + cfg.tail)
            else:
                D = s["t"]
            n = max(1, round(D * fps))
            D = n / fps
            if text:
                await asyncio.to_thread(run, [FFMPEG, "-y", "-i", str(voice), "-af",
                                              f"adelay={int(cfg.lead * 1000)}:all=1,apad",
                                              "-t", f"{D:.4f}", str(seg)])
            else:
                await asyncio.to_thread(run, [FFMPEG, "-y", "-f", "lavfi", "-i",
                                              "anullsrc=r=48000:cl=stereo", "-t", f"{D:.4f}", str(seg)])
            done[0] += 1
            progress(0.10 * done[0] / len(scenes), f"Tạo giọng đọc: {done[0]}/{len(scenes)} cảnh")
            cues = timed_cues(split_chunks(text, maxlen), cfg.lead, speech) if text else []
            return {"n": n, "D": D, "cues": cues}, seg

    res = await asyncio.gather(*(one(k, s) for k, s in enumerate(scenes)))
    plan, segs = [r[0] for r in res], [r[1] for r in res]
    lst = cfg.work / "audio_list.txt"
    lst.write_text("".join(f"file '{x.resolve().as_posix()}'\n" for x in segs), encoding="utf-8")
    audio = cfg.work / "audio.wav"
    await asyncio.to_thread(run, [FFMPEG, "-y", "-f", "concat", "-safe", "0", "-i", str(lst),
                                  "-c", "copy", str(audio)])
    return plan, audio


# ---------------------------------------------------------------- bước 2: worker (tiến trình riêng)
def _worker_entry(wid, job, chunks, nxt, counters, cancel_ev):
    try:
        asyncio.run(_worker(wid, job, chunks, nxt, counters, cancel_ev))
    except Cancelled:
        pass
    except BaseException as e:
        if not cancel_ev.is_set():          # chỉ ghi lỗi gốc, bỏ qua lỗi phát sinh do đã bị hủy
            Path(job["work"], f"err{wid}.txt").write_text(f"[Luồng {wid + 1}] {e}", encoding="utf-8")
        cancel_ev.set()


async def _worker(wid, job, chunks, nxt, counters, cancel_ev):
    fps, W, H = job["fps"], job["W"], job["H"]
    plan, starts, total_T = job["plan"], job["starts"], job["total_T"]
    work = Path(job["work"])

    async with async_playwright() as p:
        browser = await p.chromium.launch(**launch_kwargs(job["gpu"]))
        try:
            page = await browser.new_page(viewport={"width": job["bw"], "height": job["bh"]},
                                          device_scale_factor=job["cap_scale"])
            await page.goto(job["url"], wait_until="networkidle")
            await page.evaluate("document.fonts.ready.then(() => true)")
            if job["extra_css"].strip():
                await page.add_style_tag(content=job["extra_css"])
            await page.add_script_tag(content=RENDER_JS)
            await page.evaluate("window.__setup()")
            cdp = await page.context.new_cdp_session(page)
            shot = await shot_params(cdp, job["quality"])

            while True:
                with nxt.get_lock():                 # nhận đoạn tiếp theo
                    c = nxt.value
                    nxt.value += 1
                if c >= len(chunks):
                    break
                cid, a, b = chunks[c]
                seg = work / f"seg{cid:04d}.ts"
                cmd = [FFMPEG, "-y", "-hide_banner", "-loglevel", "error",
                       "-f", "image2pipe", "-framerate", str(fps), "-c:v", "mjpeg", "-i", "-"]
                if job["upscale"]:
                    cmd += ["-vf", f"scale={W}:{H}:flags=lanczos"]
                cmd += video_args(job["encoder"], job["codec"], W, H, fps) + ["-an", "-f", "mpegts", str(seg)]
                log_path = work / f"ff{cid:04d}.log"
                with open(log_path, "wb") as log:
                    ff = await asyncio.create_subprocess_exec(
                        *cmd, stdin=asyncio.subprocess.PIPE,
                        stdout=asyncio.subprocess.DEVNULL, stderr=log)
                    try:
                        for g in range(a, b):
                            if cancel_ev.is_set():
                                raise Cancelled()
                            k = bisect.bisect_right(starts, g) - 1
                            t, T = (g - starts[k]) / fps, g / fps
                            cap = current_cue(plan[k]["cues"], t) if job["subtitles"] else ""
                            await page.evaluate("a => window.__seek(...a)", [k, t, T, cap, T / total_T * 100])
                            r = await cdp.send("Page.captureScreenshot", shot)
                            ff.stdin.write(base64.b64decode(r["data"]))
                            await ff.stdin.drain()
                            counters[wid] += 1
                        ff.stdin.close()
                        rc = await ff.wait()
                    except (BrokenPipeError, ConnectionResetError):
                        rc = await ff.wait() or -1
                    except BaseException:
                        ff.kill()
                        await ff.wait()
                        raise
                if rc != 0:
                    tail = log_path.read_text(errors="ignore").strip().splitlines()[-6:]
                    raise RuntimeError("FFmpeg lỗi khi mã hóa đoạn:\n" + "\n".join(tail))
        finally:
            await browser.close()


# ---------------------------------------------------------------- điều phối
def render(cfg: RenderConfig,
           progress: Callable[[float, str], None] = lambda p, m: None,
           cancelled: Callable[[], bool] = lambda: False):
    def check():
        if cancelled():
            raise Cancelled()

    cfg.work.mkdir(parents=True, exist_ok=True)
    for f in cfg.work.glob("err*.txt"):
        f.unlink()

    # ===== 1. TTS =====
    plan, audio = asyncio.run(_prepare(cfg, progress, check))
    check()

    # ===== 2. Chia đoạn và chạy worker =====
    bw, bh = ASPECTS[cfg.aspect]
    scale = SCALES[cfg.resolution]
    W, H, fps = int(bw * scale), int(bh * scale), cfg.fps
    up = cfg.upscale and scale > 1
    cap_scale = scale * 2 / 3 if up else scale

    starts, acc = [], 0
    for sc in plan:
        starts.append(acc)
        acc += sc["n"]
    total_frames, total_T = acc, acc / fps
    N = max(1, min(cfg.workers or auto_workers(), 8, total_frames))
    clen = max(fps * 3, math.ceil(total_frames / (N * 3)))
    chunks = [(i, a, min(a + clen, total_frames)) for i, a in enumerate(range(0, total_frames, clen))]

    job = {"url": cfg.html.resolve().as_uri(), "bw": bw, "bh": bh, "cap_scale": cap_scale,
           "W": W, "H": H, "fps": fps, "plan": plan, "starts": starts, "total_T": total_T,
           "subtitles": cfg.subtitles, "extra_css": cfg.extra_css, "encoder": cfg.encoder,
           "codec": cfg.codec, "upscale": up, "gpu": cfg.gpu, "quality": cfg.jpeg_quality,
           "work": str(cfg.work)}

    ctx = mp.get_context("spawn")
    nxt, counters, cancel_ev = ctx.Value("i", 0), ctx.RawArray("i", N), ctx.Event()
    procs = [ctx.Process(target=_worker_entry, args=(i, job, chunks, nxt, counters, cancel_ev))
             for i in range(N)]
    for p in procs:
        p.start()

    t0, t_first, cancel_at = time.time(), None, None
    try:
        while any(p.is_alive() for p in procs):
            if cancelled():
                cancel_ev.set()
            if cancel_ev.is_set():
                cancel_at = cancel_at or time.time()
                if time.time() - cancel_at > 20:
                    for p in procs:
                        if p.is_alive():
                            p.kill()
            done = sum(counters)
            if done and t_first is None:
                t_first = time.time()
            if done:
                spd = done / max(1e-6, time.time() - t_first)
                eta = (total_frames - done) / max(spd, 1e-6)
                msg = f"{N} luồng · khung {done}/{total_frames} · {spd:.1f} fps · còn ~{fmt_time(eta)}"
            else:
                msg = f"Khởi động {N} trình duyệt… ({time.time() - t0:.0f}s)"
            progress(0.10 + 0.87 * done / total_frames, msg)
            time.sleep(0.5)
    finally:
        for p in procs:
            p.join(5)
            if p.is_alive():
                p.kill()

    if cancelled():
        raise Cancelled()
    errs = [f.read_text(encoding="utf-8", errors="ignore") for f in sorted(cfg.work.glob("err*.txt"))]
    if errs:
        raise RuntimeError("\n".join(errs)[-3000:])
    if sum(counters) != total_frames or any(p.exitcode not in (0, None) for p in procs):
        raise RuntimeError("Một tiến trình render dừng bất thường (có thể do thiếu RAM hoặc Chromium bị crash).")

    # ===== 3. Ghép đoạn + âm thanh =====
    progress(0.98, "Ghép các đoạn video và âm thanh…")
    lst = cfg.work / "segs.txt"
    lines = []
    for cid, a, b in chunks:
        seg = cfg.work / f"seg{cid:04d}.ts"
        if not seg.exists():
            raise RuntimeError(f"Thiếu đoạn {seg.name}")
        lines.append(f"file '{seg.resolve().as_posix()}'\nduration {(b - a) / fps:.6f}\n")
    lst.write_text("".join(lines), encoding="utf-8")
    try:
        run([FFMPEG, "-y", "-hide_banner", "-f", "concat", "-safe", "0", "-i", str(lst),
             "-i", str(audio), "-map", "0:v", "-map", "1:a", "-c:v", "copy", *tag_args(cfg.codec),
             "-c:a", "aac", "-b:a", "192k", "-shortest", "-movflags", "+faststart", str(cfg.out)])
    except Exception:
        cfg.out.unlink(missing_ok=True)
        raise

    write_srt(cfg.out.with_suffix(".srt"), plan)
    spent = time.time() - (t_first or t0)
    progress(1.0, "Hoàn tất")
    return {"duration": total_T, "frames": total_frames, "size": [W, H],
            "workers": N, "fps": total_frames / max(spent, 1e-6)}
__EOF__

# =====================================================================
cat > app.py <<'__EOF__'
"""
app.py – Giao diện web Flask cho HTML2Video
Chạy: python app.py → mở http://<IP>:5000
"""
import json
import os
import queue
import re
import shutil
import threading
import time
import traceback
import uuid
import zipfile
from html.parser import HTMLParser
from pathlib import Path

from flask import Flask, abort, jsonify, request, send_from_directory
from werkzeug.utils import secure_filename

import renderer as R

BASE = Path(__file__).parent.resolve()
UPLOADS, OUTPUTS, BUILD, VOICES = (BASE / d for d in ("uploads", "outputs", "build", "voices"))
for d in (UPLOADS, OUTPUTS, BUILD, VOICES):
    d.mkdir(exist_ok=True)

app = Flask(__name__, static_folder="static")
app.config["MAX_CONTENT_LENGTH"] = 200 * 1024 * 1024        # 200 MB
SAFE = re.compile(r"^[\w.\-]+$")


# ------------------------------------------------------------ phân tích HTML
class SceneParser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.scenes, self.title, self._t = [], "", False

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if "scene" in (a.get("class") or "").split():
            try:
                t = float(a.get("data-t") or 8)
            except ValueError:
                t = 8
            self.scenes.append({"say": (a.get("data-say") or "").strip(), "t": t})
        if tag == "title":
            self._t = True

    def handle_endtag(self, tag):
        if tag == "title":
            self._t = False

    def handle_data(self, data):
        if self._t:
            self.title += data


def load_meta(pid):
    if not SAFE.match(pid or ""):
        return None
    f = UPLOADS / pid / "project.json"
    return json.loads(f.read_text(encoding="utf-8")) if f.exists() else None


# ------------------------------------------------------------ năng lực hệ thống
_caps, _caps_lock = {"data": None}, threading.Lock()


def get_caps(refresh=False):
    with _caps_lock:
        if refresh or _caps["data"] is None:
            _caps["data"] = R.detect_capabilities(VOICES)
        _caps["data"]["piper_models"] = R.list_piper_models(VOICES)
        return _caps["data"]


# ------------------------------------------------------------ hàng đợi render
JOBS, Q = {}, queue.Queue()
PUBLIC = ("id", "project", "output", "status", "progress", "message", "summary", "created")


def fmt_dur(s):
    m, s = divmod(int(s), 60)
    return f"{m} phút {s:02d} giây"


def worker():
    while True:
        jid = Q.get()
        job = JOBS.get(jid)
        if not job or job["cancel"]:
            if job:
                job.update(status="cancelled", message="Đã hủy")
            continue
        o, work = job["opts"], BUILD / jid
        cfg = R.RenderConfig(
            html=UPLOADS / o["project"] / o["entry"], out=OUTPUTS / job["output"], work=work,
            tts=o["tts"], voice=o["voice"],
            piper_model=(VOICES / o["piper_model"]) if o["piper_model"] else None,
            rate=o["rate"], aspect=o["aspect"], resolution=o["resolution"], fps=o["fps"],
            subtitles=o["subtitles"], encoder=o["encoder"], codec=o["codec"],
            extra_css=o["extra_css"],
            workers=o["workers"], upscale=o["upscale"], gpu=o["chromium_gpu"])
        job.update(status="running", started=time.time(), message="Khởi động trình duyệt…")
        try:
            info = R.render(cfg,
                            progress=lambda p, m: job.update(progress=round(p * 100, 1), message=m),
                            cancelled=lambda: job["cancel"])
            job.update(status="done", progress=100.0,
                       message=f"Hoàn tất sau {fmt_dur(time.time() - job['started'])}"
                               f" · {info['workers']} luồng · trung bình {info['fps']:.1f} khung/giây")
            shutil.rmtree(work, ignore_errors=True)
        except R.Cancelled:
            job.update(status="cancelled", message="Đã hủy")
            shutil.rmtree(work, ignore_errors=True)
        except Exception as e:
            traceback.print_exc()
            job.update(status="error", message=str(e))     # giữ build/<id> để xem log


# ------------------------------------------------------------ routes
@app.get("/")
def index():
    return app.send_static_file("index.html")


@app.get("/api/capabilities")
def api_caps():
    return jsonify(get_caps(refresh=request.args.get("refresh") == "1"))


@app.get("/api/voices")
def api_voices():
    return jsonify(R.edge_voices())


@app.get("/api/projects")
def api_projects():
    items = [json.loads(f.read_text(encoding="utf-8")) for f in UPLOADS.glob("*/project.json")]
    return jsonify(sorted(items, key=lambda m: m["uploaded"], reverse=True))


@app.post("/api/upload")
def api_upload():
    f = request.files.get("file")
    if not f or not f.filename:
        return jsonify(error="Chưa chọn file"), 400
    name = secure_filename(f.filename) or "project.html"
    ext = Path(name).suffix.lower()
    if ext not in (".html", ".htm", ".zip"):
        return jsonify(error="Chỉ chấp nhận .html, .htm hoặc .zip"), 400
    stem = secure_filename(Path(name).stem) or "project"
    pid = f"{stem}-{time.strftime('%Y%m%d-%H%M%S')}"
    d = UPLOADS / pid
    d.mkdir(parents=True)
    try:
        if ext == ".zip":
            tmp = d / "_upload.zip"
            f.save(tmp)
            with zipfile.ZipFile(tmp) as z:
                z.extractall(d)          # zipfile tự loại bỏ đường dẫn tuyệt đối và ".."
            tmp.unlink()
            htmls = sorted(d.rglob("*.htm*"), key=lambda p: (p.name.lower() != "index.html", len(p.parts)))
            if not htmls:
                raise ValueError("File zip không chứa file .html nào")
            entry = htmls[0].relative_to(d).as_posix()
        else:
            f.save(d / name)
            entry = name
    except Exception as e:
        shutil.rmtree(d, ignore_errors=True)
        return jsonify(error=str(e)), 400
    meta = {"id": pid, "name": stem, "entry": entry, "uploaded": time.strftime("%Y-%m-%d %H:%M:%S")}
    (d / "project.json").write_text(json.dumps(meta, ensure_ascii=False), encoding="utf-8")
    return jsonify(meta)


@app.get("/api/projects/<pid>")
def api_project(pid):
    meta = load_meta(pid)
    if not meta:
        abort(404)
    sp = SceneParser()
    sp.feed((UPLOADS / pid / meta["entry"]).read_text(encoding="utf-8", errors="ignore"))
    chars = sum(len(s["say"]) for s in sp.scenes)
    est = sum(max(s["t"], 1.5 + len(s["say"]) / 15) if s["say"] else s["t"] for s in sp.scenes)
    return jsonify({**meta, "title": sp.title.strip(), "scenes": sp.scenes, "chars": chars, "est": est})


@app.delete("/api/projects/<pid>")
def api_delete_project(pid):
    if not load_meta(pid):
        abort(404)
    shutil.rmtree(UPLOADS / pid, ignore_errors=True)
    return jsonify(ok=True)


@app.get("/preview/<pid>/<path:fn>")
def preview(pid, fn):
    if not SAFE.match(pid):
        abort(404)
    return send_from_directory(UPLOADS / pid, fn)


@app.post("/api/render")
def api_render():
    o = request.get_json(force=True) or {}
    meta = load_meta(o.get("project", ""))
    if not meta:
        return jsonify(error="Dự án không tồn tại"), 404
    caps = get_caps()
    tts, enc, codec = o.get("tts", "edge"), o.get("encoder", "cpu"), o.get("codec", "h264")
    aspect, res = o.get("aspect", "16:9"), o.get("resolution", "1080p")
    try:
        fps, rate = int(o.get("fps", 30)), max(-50, min(100, int(o.get("rate", 5))))
        workers = max(0, min(8, int(o.get("workers", 0))))
    except (TypeError, ValueError):
        return jsonify(error="FPS, tốc độ đọc hoặc số luồng không hợp lệ"), 400
    upscale, cgpu = bool(o.get("upscale")), bool(o.get("chromium_gpu"))

    if enc not in R.ENCODERS or codec not in ("h264", "hevc"):
        return jsonify(error="Bộ mã hóa không hợp lệ"), 400
    if not caps["encoders"][enc][codec]:
        return jsonify(error=f"Encoder {R.ENCODERS[enc][codec]} không khả dụng trên máy này"), 400
    if aspect not in R.ASPECTS or res not in R.SCALES or fps not in (24, 25, 30, 60):
        return jsonify(error="Khung hình, độ phân giải hoặc FPS không hợp lệ"), 400

    voice, pmodel = o.get("voice", "vi-VN-HoaiMyNeural"), ""
    if tts == "edge":
        if not re.fullmatch(r"[\w\-]+", voice or ""):
            return jsonify(error="Tên giọng không hợp lệ"), 400
        tts_label = f"Edge · {voice}"
    elif tts == "piper":
        pmodel = o.get("piper_model", "")
        if not caps["piper"] or pmodel not in caps["piper_models"]:
            return jsonify(error="Piper chưa cài hoặc model không có trong thư mục voices/"), 400
        tts_label = f"Piper · {pmodel}"
    else:
        return jsonify(error="TTS không hợp lệ"), 400

    jid = uuid.uuid4().hex[:8]
    out = secure_filename(f"{meta['name']}_{aspect.replace(':', 'x')}_{res}_{time.strftime('%Y%m%d-%H%M%S')}.mp4")
    subs = bool(o.get("subtitles", True))
    JOBS[jid] = {
        "id": jid, "project": meta["id"], "output": out, "status": "queued", "progress": 0.0,
        "message": "Đang chờ…", "created": time.time(), "cancel": False,
        "summary": f"{tts_label} · {aspect} {res} {fps}fps · {R.ENCODERS[enc][codec]}"
                   f" · phụ đề {'bật' if subs else 'tắt'} · {workers or 'tự động'} luồng"
                   + (" · upscale" if upscale else "") + (" · Chromium GPU" if cgpu else ""),
        "opts": {"project": meta["id"], "entry": meta["entry"], "tts": tts, "voice": voice,
                 "piper_model": pmodel, "rate": rate, "aspect": aspect, "resolution": res,
                 "fps": fps, "subtitles": subs, "encoder": enc, "codec": codec,
                 "extra_css": str(o.get("extra_css", ""))[:50000],
                 "workers": workers, "upscale": upscale, "chromium_gpu": cgpu},
    }
    Q.put(jid)
    return jsonify(id=jid, output=out)


@app.get("/api/jobs")
def api_jobs():
    js = sorted(JOBS.values(), key=lambda j: j["created"], reverse=True)
    return jsonify([{k: j[k] for k in PUBLIC} for j in js])


@app.post("/api/jobs/<jid>/cancel")
def api_cancel(jid):
    job = JOBS.get(jid) or abort(404)
    job["cancel"] = True
    if job["status"] == "queued":
        job.update(status="cancelled", message="Đã hủy")
    return jsonify(ok=True)


@app.get("/api/outputs")
def api_outputs():
    busy = {j["output"] for j in JOBS.values() if j["status"] in ("queued", "running")}
    res = []
    for f in sorted(OUTPUTS.glob("*.mp4"), key=lambda p: p.stat().st_mtime, reverse=True):
        if f.name in busy:
            continue
        st, srt = f.stat(), f.with_suffix(".srt")
        res.append({"name": f.name, "size": st.st_size,
                    "time": time.strftime("%d/%m %H:%M", time.localtime(st.st_mtime)),
                    "srt": srt.name if srt.exists() else None})
    return jsonify(res)


@app.get("/outputs/<name>")
def get_output(name):
    if not SAFE.match(name):
        abort(404)
    return send_from_directory(OUTPUTS, name, as_attachment=request.args.get("dl") == "1")


@app.delete("/api/outputs/<name>")
def del_output(name):
    if not SAFE.match(name) or not name.endswith(".mp4"):
        abort(404)
    (OUTPUTS / name).unlink(missing_ok=True)
    (OUTPUTS / name).with_suffix(".srt").unlink(missing_ok=True)
    return jsonify(ok=True)


if __name__ == "__main__":
    # Khởi động luồng ở đây (không ở cấp module) vì multiprocessing "spawn" sẽ import lại file này
    threading.Thread(target=worker, daemon=True).start()
    threading.Thread(target=get_caps, daemon=True).start()
    host, port = os.environ.get("HOST", "0.0.0.0"), int(os.environ.get("PORT", 5000))
    print(f"🎬 HTML2Video (chạy trên Orange Pi Rockchip 3588): http://{host}:{port}")
    app.run(host=host, port=port, threaded=True, debug=False)
__EOF__

# =====================================================================
cat > bench.py <<'__EOF__'
"""
bench.py – đo tốc độ chụp khung hình để chọn số luồng render phù hợp.
Dùng:  python bench.py examples/demo.html [720p|1080p|1440p] [--gpu]
"""
import asyncio
import base64
import multiprocessing as mp
import os
import sys
import time
from pathlib import Path

from playwright.async_api import async_playwright

import renderer as R

FRAMES = 90   # số khung mỗi luồng


async def _bench(wid, url, res, gpu, method, out):
    bw, bh = R.ASPECTS["16:9"]
    async with async_playwright() as p:
        b = await p.chromium.launch(**R.launch_kwargs(gpu))
        try:
            page = await b.new_page(viewport={"width": bw, "height": bh},
                                    device_scale_factor=R.SCALES[res])
            await page.goto(url, wait_until="networkidle")
            await page.add_script_tag(content=R.RENDER_JS)
            await page.evaluate("window.__setup()")
            n = await page.evaluate("document.querySelectorAll('.scene').length") or 1
            cdp = await page.context.new_cdp_session(page)
            shot = await R.shot_params(cdp, 90)
            t0 = time.time()
            for f in range(FRAMES):
                k = (wid * 3 + f // 30) % n
                await page.evaluate("a => window.__seek(...a)", [k, (f % 30) / 30, f / 30, "", 50])
                if method == "cdp":
                    base64.b64decode((await cdp.send("Page.captureScreenshot", shot))["data"])
                else:
                    await page.screenshot(type="jpeg", quality=90)
            out[wid] = FRAMES / (time.time() - t0)
        finally:
            await b.close()


def _entry(*a):
    asyncio.run(_bench(*a))


def trial(n, url, res, gpu, method="cdp"):
    ctx = mp.get_context("spawn")
    out = ctx.RawArray("d", n)
    ps = [ctx.Process(target=_entry, args=(i, url, res, gpu, method, out)) for i in range(n)]
    for p in ps:
        p.start()
    for p in ps:
        p.join()
    return sum(out)


async def gpu_info(gpu):
    async with async_playwright() as p:
        b = await p.chromium.launch(**R.launch_kwargs(gpu))
        page = await b.new_page()
        r = await page.evaluate("""() => {
          const gl = document.createElement('canvas').getContext('webgl');
          if (!gl) return 'không có WebGL';
          const e = gl.getExtension('WEBGL_debug_renderer_info');
          return e ? gl.getParameter(e.UNMASKED_RENDERER_WEBGL) : gl.getParameter(gl.RENDERER);
        }""")
        await b.close()
        return r


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit("Dùng: python bench.py <file.html> [720p|1080p|1440p] [--gpu]")
    url = Path(sys.argv[1]).resolve().as_uri()
    res = next((a for a in sys.argv[2:] if a in R.SCALES), "1080p")
    gpu = "--gpu" in sys.argv
    print("Bộ dựng hình Chromium:", asyncio.run(gpu_info(gpu)))
    print(f"Độ phân giải {res}, {FRAMES} khung mỗi luồng\n")
    print(f"page.screenshot (cách cũ), 1 luồng: {trial(1, url, res, gpu, 'pw'):5.1f} fps")
    base = None
    for n in (1, 2, 3, 4, 6, 8):
        if n > (os.cpu_count() or 1):
            break
        tot = trial(n, url, res, gpu)
        base = base or tot
        print(f"CDP, {n} luồng: {tot:5.1f} fps  (x{tot / base:.2f})")
__EOF__

# =====================================================================
cat > static/index.html <<'__EOF__'
<!DOCTYPE html>
<html lang="vi">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>HTML2Video – chạy trên Orange Pi Rockchip 3588</title>
<style>
:root{--bg:#0b1020;--card:#141b2e;--line:#26314d;--txt:#e6ecff;--mut:#8a97b8;--acc:#00c2ff;--acc2:#7b5cff;--ok:#2bd67b;--err:#ff5c7a;--warn:#ffc246}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--txt);font:14px/1.5 "Segoe UI",Roboto,sans-serif}
header{display:flex;align-items:center;justify-content:space-between;gap:12px;padding:14px 24px;border-bottom:1px solid var(--line);flex-wrap:wrap}
header h1{margin:0;font-size:20px}
header .tagline{margin:2px 0 0;font-size:13px;color:var(--mut)}
footer{text-align:center;padding:16px 24px;border-top:1px solid var(--line);color:var(--mut);font-size:13px}
footer a{text-decoration:none}
a{color:var(--acc)}
main{display:grid;grid-template-columns:340px 1fr;gap:18px;padding:18px 24px;max-width:1500px;margin:auto}
.card{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:16px;margin-bottom:18px}
.card h2{margin:0 0 12px;font-size:15px;color:var(--acc)}
#drop{border:2px dashed var(--line);border-radius:10px;padding:22px;text-align:center;color:var(--mut);cursor:pointer;transition:.2s}
#drop:hover,#drop.over{border-color:var(--acc);color:var(--txt);background:#00c2ff0d}
.item{display:flex;justify-content:space-between;align-items:center;gap:8px;padding:8px 10px;border:1px solid var(--line);border-radius:8px;margin-top:8px;cursor:pointer}
.item:hover{border-color:#3a4a70}.item.sel{border-color:var(--acc);background:#1a2540}
.item button{background:none;border:none;cursor:pointer;font-size:15px;padding:4px}
.pv{position:relative;overflow:hidden;border-radius:8px;background:#000;border:1px solid var(--line);margin:auto}
.pv iframe{position:absolute;left:0;top:0;border:0;transform-origin:0 0}
.opts{display:grid;grid-template-columns:repeat(auto-fill,minmax(240px,1fr));gap:16px}
.t{display:block;color:var(--mut);font-size:12px;margin-bottom:6px;text-transform:uppercase;letter-spacing:.5px}
.seg{display:flex;gap:6px;flex-wrap:wrap}
.seg input{display:none}
.seg label{padding:6px 12px;border:1px solid var(--line);border-radius:8px;cursor:pointer;user-select:none}
.seg input:checked+label{border-color:var(--acc);background:#00c2ff22;color:#fff}
.seg input:disabled+label{opacity:.35;cursor:not-allowed;text-decoration:line-through}
.chk{display:flex;gap:6px;align-items:center;margin-top:6px;cursor:pointer}
select,textarea{width:100%;background:#0e1426;color:var(--txt);border:1px solid var(--line);border-radius:8px;padding:7px;font:inherit}
textarea{font-family:Consolas,monospace;font-size:12px}
input[type=range]{width:100%}
button.main{background:linear-gradient(90deg,var(--acc),var(--acc2));border:none;color:#fff;font-weight:700;font-size:15px;padding:10px 22px;border-radius:10px;cursor:pointer}
button.main:disabled{opacity:.5;cursor:not-allowed}
button.sec{background:#1f2a45;border:1px solid var(--line);color:var(--txt);padding:5px 12px;border-radius:8px;cursor:pointer;margin-top:8px}
.bar{height:8px;background:#0e1426;border-radius:6px;overflow:hidden;margin:6px 0}
.bar i{display:block;height:100%;background:linear-gradient(90deg,var(--acc),var(--acc2));transition:width .4s}
table{width:100%;border-collapse:collapse;font-size:13px}
td,th{padding:6px;border-bottom:1px solid var(--line);text-align:left;vertical-align:top}
th{color:var(--mut);font-weight:600}
.scroll{max-height:260px;overflow:auto}
.job{border:1px solid var(--line);border-radius:10px;padding:10px 12px;margin-bottom:10px}
.st{font-size:12px;padding:2px 8px;border-radius:20px;background:#26314d}
.st.running{background:#00c2ff33;color:var(--acc)}.st.done{background:#2bd67b33;color:var(--ok)}
.st.error{background:#ff5c7a33;color:var(--err)}.st.cancelled{color:var(--mut)}
pre.err{white-space:pre-wrap;color:var(--err);font-size:12px;margin:6px 0 0}
.out{padding:8px 0;border-bottom:1px solid var(--line);word-break:break-all}
.out a{text-decoration:none;margin-right:8px}
.hidden{display:none!important}
.muted{color:var(--mut)}
.warn{color:var(--warn)}
@media(max-width:950px){main{grid-template-columns:1fr}}
</style>
</head>
<body>
<header>
  <div>
    <h1>🎬 HTML2Video</h1>
    <p class="tagline">chạy trên Orange Pi Rockchip 3588</p>
  </div>
  <div><span id="sys" class="muted">Đang kiểm tra hệ thống…</span>
    <a href="#" id="recheck" style="margin-left:8px">↻ Kiểm tra lại</a></div>
</header>

<main>
<aside>
  <div class="card">
    <h2>📁 Dự án</h2>
    <div id="drop">Kéo thả file <b>.html</b> hoặc <b>.zip</b> vào đây<br><small>(hoặc bấm để chọn file)</small></div>
    <input type="file" id="file" accept=".html,.htm,.zip" hidden>
    <div id="upmsg" class="muted" style="margin-top:8px"></div>
    <div id="plist"></div>
  </div>
  <div class="card">
    <h2>🎞️ Video đã xuất</h2>
    <video id="player" controls class="hidden" style="width:100%;border-radius:8px;margin-bottom:8px;background:#000"></video>
    <div id="outs" class="muted">Chưa có video.</div>
  </div>
</aside>

<section>
  <div id="empty" class="card muted">👈 Hãy tải lên hoặc chọn một dự án ở cột bên trái.</div>

  <div id="proj" class="hidden">
    <div class="card">
      <h2 id="ptitle"></h2>
      <div class="pv" id="pv"><iframe id="frame"></iframe></div>
      <div id="pinfo" class="muted" style="margin:10px 0"></div>
      <div class="scroll"><table id="scenes"></table></div>
    </div>

    <div class="card">
      <h2>⚙️ Tùy chọn render</h2>
      <div class="opts">
        <div>
          <span class="t">Giọng đọc (TTS)</span>
          <div class="seg">
            <input type="radio" name="tts" id="tts-edge" value="edge" checked><label for="tts-edge">☁️ Edge TTS</label>
            <input type="radio" name="tts" id="tts-piper" value="piper"><label for="tts-piper">💻 Piper (offline)</label>
          </div>
        </div>
        <div id="box-edge">
          <span class="t">Giọng Edge</span>
          <select id="voice"><option>vi-VN-HoaiMyNeural</option></select>
          <label class="chk"><input type="checkbox" id="vionly" checked> Chỉ hiện giọng tiếng Việt</label>
        </div>
        <div id="box-piper" class="hidden">
          <span class="t">Model Piper (thư mục voices/)</span>
          <select id="pmodel"></select>
        </div>
        <div>
          <span class="t">Tốc độ đọc: <b id="ratev">+5%</b></span>
          <input type="range" id="rate" min="-30" max="50" step="5" value="5">
        </div>
        <div>
          <span class="t">Khung hình</span>
          <div class="seg">
            <input type="radio" name="aspect" id="a1" value="16:9" checked><label for="a1">▭ 16:9</label>
            <input type="radio" name="aspect" id="a2" value="9:16"><label for="a2">▯ 9:16</label>
            <input type="radio" name="aspect" id="a3" value="4:3"><label for="a3">◻ 4:3</label>
          </div>
        </div>
        <div>
          <span class="t">Độ phân giải <span id="resinfo"></span></span>
          <select id="res">
            <option value="720p">720p</option><option value="1080p" selected>1080p</option>
            <option value="1440p">1440p</option><option value="2160p">4K (2160p)</option>
          </select>
        </div>
        <div>
          <span class="t">FPS</span>
          <select id="fps"><option>24</option><option>25</option><option selected>30</option><option>60</option></select>
        </div>
        <div>
          <span class="t">Số luồng render song song</span>
          <select id="workers">
            <option value="0" selected>Tự động</option>
            <option>1</option><option>2</option><option>3</option><option>4</option>
            <option>5</option><option>6</option><option>8</option>
          </select>
          <small class="muted" id="cpuinfo"></small>
        </div>
        <div>
          <span class="t">Tăng tốc</span>
          <label class="chk"><input type="checkbox" id="upscale"> Chụp 2/3 độ phân giải rồi phóng to</label>
          <label class="chk"><input type="checkbox" id="cgpu"> Chromium dùng GPU (thử nghiệm)</label>
        </div>
        <div>
          <span class="t">Phụ đề</span>
          <label class="chk"><input type="checkbox" id="subs" checked> In phụ đề lên video</label>
          <small class="muted">File .srt luôn được xuất kèm</small>
        </div>
        <div>
          <span class="t">Bộ mã hóa video</span>
          <div class="seg">
            <input type="radio" name="encoder" id="enc-cpu" value="cpu" checked><label for="enc-cpu">🖥️ CPU</label>
            <input type="radio" name="encoder" id="enc-nvidia" value="nvidia"><label for="enc-nvidia">🟩 NVIDIA</label>
            <input type="radio" name="encoder" id="enc-rockchip" value="rockchip"><label for="enc-rockchip">🟧 Rockchip</label>
          </div>
        </div>
        <div>
          <span class="t">Codec</span>
          <div class="seg">
            <input type="radio" name="codec" id="c-h264" value="h264" checked><label for="c-h264">H.264</label>
            <input type="radio" name="codec" id="c-hevc" value="hevc"><label for="c-hevc">H.265 / HEVC</label>
          </div>
        </div>
      </div>

      <details style="margin-top:16px">
        <summary style="cursor:pointer">🎨 CSS bổ sung (chèn vào trang khi render; xem trước cập nhật ngay)</summary>
        <textarea id="css" rows="9" style="margin-top:8px" placeholder="Ví dụ: h1{color:red}"></textarea>
        <button class="sec" id="cssPortrait">Chèn mẫu CSS khung dọc (rockchip.html)</button>
        <button class="sec" id="cssPerf">Chèn CSS tối ưu tốc độ (rockchip.html)</button>
        <button class="sec" id="cssClear">Xóa</button>
      </details>

      <div style="margin-top:18px;display:flex;gap:14px;align-items:center;flex-wrap:wrap">
        <button class="main" id="go">🚀 Render MP4</button>
        <span id="gomsg" class="muted"></span>
      </div>
    </div>
  </div>

  <div class="card">
    <h2>⏳ Hàng đợi render</h2>
    <div id="jobs" class="muted">Chưa có tác vụ.</div>
  </div>
</section>
</main>

<footer>
  2026 - Copyright by <a href="https://orangepi.vn" target="_blank" rel="noopener">Orange Pi Việt Nam</a>
</footer>

<script>
const $ = s => document.querySelector(s), $$ = s => [...document.querySelectorAll(s)];
const val = n => (document.querySelector(`input[name=${n}]:checked`) || {}).value;
const ASPECT = {"16:9": [1280, 720], "9:16": [720, 1280], "4:3": [960, 720]};
const SCALE = {"720p": 1, "1080p": 1.5, "1440p": 2, "2160p": 3};
const ST = {queued: "Đang chờ", running: "Đang render", done: "Hoàn tất", error: "Lỗi", cancelled: "Đã hủy"};
let caps = null, cur = null, voices = [], lastDone = -1;

const esc = s => String(s ?? "").replace(/[&<>"']/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));
const fmtT = s => { s = Math.round(s); return Math.floor(s / 60) + ":" + String(s % 60).padStart(2, "0"); };
const fmtB = b => b > 1e6 ? (b / 1e6).toFixed(1) + " MB" : (b / 1e3).toFixed(0) + " KB";
async function api(url, opt) {
  const r = await fetch(url, opt);
  const j = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(j.error || r.statusText);
  return j;
}

/* ---------- Năng lực hệ thống ---------- */
function setDis(id, d) {
  const el = document.getElementById(id);
  el.disabled = d;
  if (d && el.checked) {
    el.checked = false;
    const alt = $$(`input[name=${el.name}]`).find(x => !x.disabled);
    if (alt) alt.checked = true;
  }
}
async function loadCaps(refresh) {
  $("#sys").textContent = "Đang kiểm tra bộ mã hóa…";
  caps = await api("/api/capabilities" + (refresh ? "?refresh=1" : ""));
  const e = caps.encoders, ok = k => e[k].h264 || e[k].hevc, ic = b => b ? "✅" : "❌";
  setDis("enc-cpu", !ok("cpu")); setDis("enc-nvidia", !ok("nvidia")); setDis("enc-rockchip", !ok("rockchip"));
  setDis("tts-piper", !caps.piper || !caps.piper_models.length);
  $("#pmodel").innerHTML = caps.piper_models.map(m => `<option>${esc(m)}</option>`).join("");
  $("#sys").innerHTML = `FFmpeg ${ic(caps.ffmpeg)} · CPU ${ic(ok("cpu"))} · NVIDIA ${ic(ok("nvidia"))}` +
    ` · Rockchip ${ic(ok("rockchip"))} · Piper ${ic(caps.piper && caps.piper_models.length)}`;
  $("#cpuinfo").textContent = `Máy có ${caps.cpus} lõi · Tự động = ${caps.auto_workers} luồng`;
  updateCodec(); updTts();
}
function updateCodec() {
  if (!caps) return;
  const e = caps.encoders[val("encoder")] || {};
  setDis("c-h264", !e.h264); setDis("c-hevc", !e.hevc);
  if (!val("codec")) { const f = $$("input[name=codec]").find(x => !x.disabled); if (f) f.checked = true; }
}
function updTts() {
  const p = val("tts") === "piper";
  $("#box-edge").classList.toggle("hidden", p);
  $("#box-piper").classList.toggle("hidden", !p);
}
function updRes() {
  const [w, h] = ASPECT[val("aspect")], s = SCALE[$("#res").value];
  $("#resinfo").textContent = `→ ${w * s}×${h * s}`;
}

/* ---------- Giọng Edge ---------- */
async function loadVoices() { voices = await api("/api/voices"); fillVoices(); }
function fillVoices() {
  const vi = $("#vionly").checked, keep = $("#voice").value;
  const list = voices.filter(v => !vi || v.locale.startsWith("vi"));
  $("#voice").innerHTML = list.map(v =>
    `<option value="${esc(v.id)}" ${v.id === keep ? "selected" : ""}>${esc(v.id)} (${v.gender === "Female" ? "Nữ" : "Nam"})</option>`).join("");
}

/* ---------- Dự án ---------- */
async function loadProjects() {
  const ps = await api("/api/projects");
  $("#plist").innerHTML = ps.length ? ps.map(p => `
    <div class="item ${cur && cur.id === p.id ? "sel" : ""}" data-id="${esc(p.id)}">
      <div><b>${esc(p.name)}</b><br><small class="muted">${esc(p.entry)} · ${esc(p.uploaded)}</small></div>
      <button data-del="${esc(p.id)}" title="Xóa dự án">🗑</button>
    </div>`).join("") : '<div class="muted" style="margin-top:8px">Chưa có dự án.</div>';
}
$("#plist").onclick = async e => {
  const del = e.target.closest("[data-del]");
  if (del) {
    e.stopPropagation();
    if (!confirm("Xóa dự án này?")) return;
    await api(`/api/projects/${del.dataset.del}`, {method: "DELETE"});
    if (cur && cur.id === del.dataset.del) { cur = null; $("#proj").classList.add("hidden"); $("#empty").classList.remove("hidden"); }
    return loadProjects();
  }
  const it = e.target.closest(".item");
  if (it) selectProject(it.dataset.id);
};
async function selectProject(id) {
  const a = await api(`/api/projects/${id}`);
  cur = a;
  $("#empty").classList.add("hidden"); $("#proj").classList.remove("hidden");
  $("#ptitle").textContent = "📄 " + (a.title || a.name);
  $("#frame").src = `/preview/${a.id}/` + a.entry.split("/").map(encodeURIComponent).join("/");
  $("#pinfo").innerHTML = a.scenes.length
    ? `<b>${a.scenes.length}</b> cảnh · <b>${a.chars}</b> ký tự lời thoại · thời lượng ước tính <b>~${fmtT(a.est)}</b>`
    : `<span class="warn">⚠ Không tìm thấy &lt;section class="scene" data-say="…"&gt; nào. File cần theo cấu trúc này để render.</span>`;
  $("#scenes").innerHTML = "<tr><th>#</th><th>Tối thiểu</th><th>Lời thoại</th></tr>" + a.scenes.map((s, i) =>
    `<tr><td>${i + 1}</td><td>${s.t}s</td><td>${s.say ? esc(s.say) : '<i class="muted">(không có lời)</i>'}</td></tr>`).join("");
  $("#go").disabled = !a.scenes.length;
  fitPreview(); loadProjects();
}

/* ---------- Xem trước ---------- */
function fitPreview() {
  if (!cur) return;
  const [w, h] = ASPECT[val("aspect")], pv = $("#pv");
  const s = Math.min(pv.parentElement.clientWidth / w, window.innerHeight * 0.55 / h);
  pv.style.width = w * s + "px"; pv.style.height = h * s + "px";
  const f = $("#frame");
  f.style.width = w + "px"; f.style.height = h + "px"; f.style.transform = `scale(${s})`;
}
function injectCss() {
  try {
    const d = $("#frame").contentDocument;
    if (!d || !d.head) return;
    let st = d.getElementById("__extra");
    if (!st) { st = d.createElement("style"); st.id = "__extra"; d.head.appendChild(st); }
    st.textContent = $("#css").value;
  } catch (e) {}
}
$("#frame").onload = injectCss;
$("#css").oninput = injectCss;

/* ---------- Upload ---------- */
const drop = $("#drop"), fi = $("#file");
drop.onclick = () => fi.click();
fi.onchange = () => { if (fi.files[0]) upload(fi.files[0]); fi.value = ""; };
drop.ondragover = e => { e.preventDefault(); drop.classList.add("over"); };
drop.ondragleave = () => drop.classList.remove("over");
drop.ondrop = e => { e.preventDefault(); drop.classList.remove("over"); if (e.dataTransfer.files[0]) upload(e.dataTransfer.files[0]); };
async function upload(file) {
  const fd = new FormData(); fd.append("file", file);
  $("#upmsg").textContent = "Đang tải lên…";
  try {
    const p = await api("/api/upload", {method: "POST", body: fd});
    $("#upmsg").textContent = "✅ Đã tải lên: " + p.name;
    await loadProjects(); selectProject(p.id);
  } catch (e) { $("#upmsg").textContent = "❌ " + e.message; }
}

/* ---------- Render ---------- */
$("#go").onclick = async () => {
  if (!cur) return;
  const o = {
    project: cur.id, tts: val("tts"), voice: $("#voice").value, piper_model: $("#pmodel").value,
    rate: +$("#rate").value, aspect: val("aspect"), resolution: $("#res").value, fps: +$("#fps").value,
    subtitles: $("#subs").checked, encoder: val("encoder"), codec: val("codec"), extra_css: $("#css").value,
    workers: +$("#workers").value, upscale: $("#upscale").checked, chromium_gpu: $("#cgpu").checked,
  };
  try {
    const j = await api("/api/render", {method: "POST", headers: {"Content-Type": "application/json"}, body: JSON.stringify(o)});
    $("#gomsg").textContent = "✅ Đã thêm vào hàng đợi: " + j.output;
    pollJobs();
  } catch (e) { $("#gomsg").textContent = "❌ " + e.message; }
};
async function cancelJob(id) { await api(`/api/jobs/${id}/cancel`, {method: "POST"}); pollJobs(); }

async function pollJobs() {
  let js;
  try { js = await api("/api/jobs"); } catch { return; }
  if (js.length) $("#jobs").innerHTML = js.map(j => `
    <div class="job">
      <div style="display:flex;justify-content:space-between;gap:8px"><b style="word-break:break-all">${esc(j.output)}</b>
        <span class="st ${j.status}">${ST[j.status]}</span></div>
      <small class="muted">${esc(j.summary)}</small>
      <div class="bar"><i style="width:${j.progress}%"></i></div>
      ${j.status === "error" ? `<pre class="err">${esc(j.message)}</pre>` : `<small>${j.progress.toFixed(0)}% · ${esc(j.message)}</small>`}
      <div>
        ${["queued", "running"].includes(j.status) ? `<button class="sec" onclick="cancelJob('${j.id}')">✖ Hủy</button>` : ""}
        ${j.status === "done" ? `<a href="/outputs/${encodeURIComponent(j.output)}?dl=1">⬇ Tải MP4</a>
           <a href="#" onclick="play('${encodeURIComponent(j.output)}');return false">▶ Xem</a>` : ""}
      </div>
    </div>`).join("");
  const done = js.filter(j => j.status === "done").length;
  if (done !== lastDone) { lastDone = done; loadOutputs(); }
}

/* ---------- Video đã xuất ---------- */
async function loadOutputs() {
  const os = await api("/api/outputs");
  $("#outs").innerHTML = os.length ? os.map(o => {
    const n = encodeURIComponent(o.name);
    return `<div class="out"><a href="#" onclick="play('${n}');return false">▶ ${esc(o.name)}</a><br>
      <small class="muted">${fmtB(o.size)} · ${o.time}</small>
      <a href="/outputs/${n}?dl=1" title="Tải MP4">⬇ MP4</a>
      ${o.srt ? `<a href="/outputs/${encodeURIComponent(o.srt)}?dl=1">⬇ SRT</a>` : ""}
      <a href="#" onclick="delOut('${n}');return false" title="Xóa">🗑</a></div>`;
  }).join("") : '<div class="muted">Chưa có video.</div>';
}
function play(n) { const p = $("#player"); p.src = "/outputs/" + n; p.classList.remove("hidden"); p.play(); }
async function delOut(n) {
  if (!confirm("Xóa video này?")) return;
  await api("/api/outputs/" + n, {method: "DELETE"});
  loadOutputs();
}

/* ---------- Mẫu CSS (dành cho rockchip.html) ---------- */
const PORTRAIT_CSS = `@media (orientation: portrait) {
  h1{font-size:9vw} h2{font-size:6.5vw;margin-bottom:2vh} h3{font-size:4.6vw}
  p,li{font-size:3.7vw} .sub{font-size:4.2vw;text-align:center}
  .row{flex-direction:column;gap:1.4vh}
  .card{min-width:86vw;max-width:90vw;padding:1.4vh 4vw}
  .blocks{grid-template-columns:repeat(2,42vw);gap:3vw} .blk{font-size:4.5vw} .blk span{font-size:3vw}
  .tl{flex-direction:column;width:86vw;gap:1.6vh} .tl::before{display:none}
  .ev{width:86vw;display:flex;align-items:center;gap:4vw;text-align:left}
  .ev .dot{margin:0;flex:none} .ev b{font-size:4.6vw} .ev p{font-size:3.4vw}
  .bars{width:90vw} .bar label{width:24vw;font-size:3.8vw} .bar .fill{font-size:3.4vw}
  .tag{font-size:3.3vw} .core{font-size:2.6vw}
  #caption{font-size:3.8vw;width:92vw;bottom:5vh}
}`;
const PERF_CSS = `/* Tối ưu tốc độ render cho rockchip.html: hình ảnh gần như không đổi */
#stage{background:radial-gradient(circle at 30% 20%,#0b2a4a 0,#05070f 60%)}
#bg{inset:-400px 0 0 -400px;background:
  linear-gradient(rgba(0,180,255,.06) 1px,transparent 1px) 0 0/40px 40px,
  linear-gradient(90deg,rgba(0,180,255,.06) 1px,transparent 1px) 0 0/40px 40px;
  animation:gridT 20s linear infinite;will-change:transform}
@keyframes gridT{to{transform:translate(400px,400px)}}
.card{backdrop-filter:none;background:rgba(20,35,60,.9)}`;
$("#cssPortrait").onclick = () => { $("#css").value = ($("#css").value.trim() + "\n\n" + PORTRAIT_CSS).trim(); injectCss(); };
$("#cssPerf").onclick = () => { $("#css").value = ($("#css").value.trim() + "\n\n" + PERF_CSS).trim(); injectCss(); };
$("#cssClear").onclick = () => { $("#css").value = ""; injectCss(); };

/* ---------- Sự kiện chung ---------- */
document.addEventListener("change", e => {
  const n = e.target.name, id = e.target.id;
  if (n === "aspect") { fitPreview(); updRes(); }
  if (n === "encoder") updateCodec();
  if (n === "tts") updTts();
  if (id === "res") updRes();
  if (id === "vionly") fillVoices();
});
$("#rate").oninput = () => { const v = +$("#rate").value; $("#ratev").textContent = (v >= 0 ? "+" : "") + v + "%"; };
$("#recheck").onclick = e => { e.preventDefault(); loadCaps(true).catch(err => $("#sys").textContent = "❌ " + err.message); };
window.addEventListener("resize", fitPreview);

(async () => {
  updRes(); updTts();
  loadProjects(); loadOutputs();
  loadVoices().catch(() => {});
  loadCaps().catch(e => $("#sys").textContent = "❌ " + e.message);
  pollJobs(); setInterval(pollJobs, 1500);
})();
</script>
</body>
</html>
__EOF__

# =====================================================================
cat > README.md <<'__EOF__'
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
 ② TTS         Edge/Piper tạo giọng đọc (4 cảnh song song)
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
| `PIPER_BIN` | `piper` | Đường dẫn chương trình Piper |
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
__EOF__

chmod +x install.sh run.sh scripts/*.sh
cd ..

# ---------------------------------------------------------------- nén zip
PY="$(command -v python3 || command -v python || true)"
if [ -n "$PY" ]; then
  "$PY" -c "import shutil; shutil.make_archive('html2video', 'zip', '.', 'html2video')"
elif command -v zip >/dev/null 2>&1; then
  zip -qr html2video.zip html2video
else
  echo "⚠ Không có python hoặc zip để nén. Thư mục html2video/ đã được tạo, hãy tự nén."
  exit 0
fi
echo "✅ Đã tạo thư mục html2video/ và file html2video.zip"
