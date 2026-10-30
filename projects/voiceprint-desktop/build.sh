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
SIGNING_IDENTITY="${VOICEPRINT_SIGNING_IDENTITY:--}"
codesign --force --sign "$SIGNING_IDENTITY" --identifier local.jackjia.voiceprint "$APP"
NEW_HASH="$(codesign -d --verbose=2 "$APP" 2>&1 | sed -n 's/^CDHash=//p')"
if [[ "${1:-}" == "--install" ]]; then
  OLD_HASH=''
  if [[ -d "$DESTINATION" ]]; then
    EXISTING_ID=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$DESTINATION/Contents/Info.plist" 2>/dev/null || true)
    if [[ "$EXISTING_ID" != 'local.jackjia.voiceprint' ]]; then
      echo '桌面上已有其他同名程序，请先为它改名。' >&2
      exit 1
    fi
    OLD_HASH="$(codesign -d --verbose=2 "$DESTINATION" 2>&1 | sed -n 's/^CDHash=//p')"
  fi
  ditto "$APP" "$DESTINATION"
  echo "已安装：$DESTINATION"
  if [[ "$SIGNING_IDENTITY" == '-' && -n "$OLD_HASH" && "$OLD_HASH" != "$NEW_HASH" ]]; then
    echo '本地开发版本签名已更新。若录音权限的开关已开仍提示失败，请在系统设置中移除旧应用，再添加桌面上的当前版本。'
  fi
else
  echo "已构建：$APP"
fi
