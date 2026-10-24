#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
DESTINATION="$HOME/Desktop/声纹对比.app"
if [[ "${1:-}" == "--install" ]] && pgrep -f "^$DESTINATION/Contents/MacOS/Voiceprint( |$)" >/dev/null; then
  echo '请先退出正在运行的声纹对比，再重新安装，以免影响录音和系统授权。' >&2
  exit 1
fi
APP="$ROOT/build/声纹对比.app"
RESOURCES="$APP/Contents/Resources"
ENGINE="$HOME/Library/Application Support/VoiceprintDesktop/Engine"
mkdir -p "$APP/Contents/MacOS" "$RESOURCES"
if [[ ! -x "$ROOT/.venv/bin/python" || ! -f "$ROOT/models/eres2netv2.onnx" ]]; then
  echo '缺少本地环境或模型，请先运行 ./setup.sh。' >&2
  exit 1
fi
swiftc -parse-as-library -swift-version 5 -O -target arm64-apple-macosx14.0 \
  -framework AppKit -framework SwiftUI -framework AVFoundation \
  -framework ScreenCaptureKit -framework CoreMedia \
  "$ROOT/AudioCapture.swift" "$ROOT/Voiceprint.swift" -o "$APP/Contents/MacOS/Voiceprint"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
mkdir -p "$ENGINE/models"
if [[ ! -x "$ENGINE/.venv/bin/python" ]]; then
  uv venv --python "$ROOT/.venv/bin/python" "$ENGINE/.venv"
fi
uv pip install --index-url https://pypi.tuna.tsinghua.edu.cn/simple \
  --python "$ENGINE/.venv/bin/python" -r "$ROOT/requirements.txt"
cp "$ROOT/worker.py" "$ENGINE/worker.py"
if ! cmp -s "$ROOT/models/eres2netv2.onnx" "$ENGINE/models/eres2netv2.onnx"; then
  cp "$ROOT/models/eres2netv2.onnx" "$ENGINE/models/eres2netv2.onnx"
fi
"$ROOT/.venv/bin/python" - "$ENGINE" "$RESOURCES/runtime.json" <<'PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
pathlib.Path(sys.argv[2]).write_text(json.dumps({
    'python': str(root / '.venv/bin/python'),
    'model': str(root / 'models/eres2netv2.onnx'),
    'worker': str(root / 'worker.py'),
}, ensure_ascii=False), encoding='utf-8')
PY
swift "$ROOT/make-icon.swift" "$ROOT/build"
iconutil -c icns "$ROOT/build/AppIcon.iconset" -o "$RESOURCES/AppIcon.icns"
codesign --force --sign - --identifier local.jackjia.voiceprint "$APP"
if [[ "${1:-}" == "--install" ]]; then
  if [[ -d "$DESTINATION" ]]; then
    EXISTING_ID=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$DESTINATION/Contents/Info.plist" 2>/dev/null || true)
    if [[ "$EXISTING_ID" != 'local.jackjia.voiceprint' ]]; then
      echo '桌面上已有其他同名程序，请先为它改名。' >&2
      exit 1
    fi
  fi
  ditto "$APP" "$DESTINATION"
  echo "已安装：$DESTINATION"
else
  echo "已构建：$APP"
fi
