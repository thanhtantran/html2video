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
