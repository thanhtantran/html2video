#!/usr/bin/env bash
# Chạy thủ công (không dùng systemd)
cd "$(dirname "$0")"
if [ -f .env ]; then set -a; . ./.env; set +a; fi
export PATH="$PWD/.venv/bin:$PATH"
exec .venv/bin/python app.py
