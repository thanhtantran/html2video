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
