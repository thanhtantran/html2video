#!/usr/bin/env bash
# Cài đặt HTML → MP4 Studio trên Ubuntu / Debian / Armbian (x86_64 hoặc ARM64)
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
Description=HTML to MP4 Studio
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
