#!/usr/bin/env bash
# Ép CPU và RAM chạy xung tối đa (cần quyền root). Cài đặt sẽ mất sau khi khởi động lại.
for f in /sys/devices/system/cpu/cpufreq/policy*/scaling_governor; do
  [ -w "$f" ] && echo performance > "$f"
done
[ -w /sys/class/devfreq/dmc/governor ] && echo performance > /sys/class/devfreq/dmc/governor
exit 0
