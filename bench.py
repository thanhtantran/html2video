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
