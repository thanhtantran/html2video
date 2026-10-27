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
