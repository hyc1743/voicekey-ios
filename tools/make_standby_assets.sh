#!/usr/bin/env bash
# 生成画中画待命素材（两个都必须是 H.264、无音轨、体积几 KB）。
#
#   StandbyHidden.mp4  隐藏模式：2432×2 的极扁条带 —— 窗口因此退化成一缕发丝，用户基本无感
#                      （规格与已验证实现一致；App 内锚点叠加 resizeAspect 后同样只剩发丝宽）
#   Standby.mp4        可见模式：192×108 的小画面，仅在"隐藏适配"不可用时才会用到
#
# 用法：bash tools/make_standby_assets.sh
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=VoiceKey/Resources

ffmpeg -hide_banner -loglevel error \
  -f lavfi -i color=c=black:s=2432x2:d=2:r=15 -pix_fmt yuv420p \
  -c:v libx264 -profile:v high -crf 51 -movflags +faststart -an \
  "$OUT/StandbyHidden.mp4" -y

ffmpeg -hide_banner -loglevel error \
  -f lavfi -i color=c=0x1b2a41:s=192x108:d=2:r=15 -pix_fmt yuv420p \
  -c:v libx264 -profile:v high -crf 40 -movflags +faststart -an \
  "$OUT/Standby.mp4" -y

for f in "$OUT/StandbyHidden.mp4" "$OUT/Standby.mp4"; do
  printf '%s: ' "$f"
  ffprobe -hide_banner -loglevel error -show_entries stream=codec_name,width,height \
    -show_entries format=size -of csv=p=0 "$f" | tr '\n' ' '
  echo
done
