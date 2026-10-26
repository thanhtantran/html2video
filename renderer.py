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
