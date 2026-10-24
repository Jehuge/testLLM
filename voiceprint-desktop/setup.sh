#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
if ! command -v uv >/dev/null; then
  echo '请先安装 uv：https://docs.astral.sh/uv/getting-started/installation/' >&2
  exit 1
fi
if [[ ! -x "$ROOT/.venv/bin/python" ]]; then
  uv venv --python 3.11 "$ROOT/.venv"
fi
uv pip install --index-url https://pypi.tuna.tsinghua.edu.cn/simple \
  --python "$ROOT/.venv/bin/python" -r "$ROOT/requirements.txt"
mkdir -p "$ROOT/models"
MODEL="$ROOT/models/eres2netv2.onnx"
EXPECTED='bf1a75b9930474cf3389ef415e6e5d38ca96fea4a3a00f7e301d080a58ee2239'
if [[ ! -f "$MODEL" ]] || [[ "$(shasum -a 256 "$MODEL" | cut -d ' ' -f 1)" != "$EXPECTED" ]]; then
  curl -fL --retry 2 --connect-timeout 15 --max-time 300 \
    'https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/3dspeaker_speech_eres2netv2_sv_zh-cn_16k-common.onnx' \
    -o "$MODEL.download"
  ACTUAL="$(shasum -a 256 "$MODEL.download" | cut -d ' ' -f 1)"
  if [[ "$ACTUAL" != "$EXPECTED" ]]; then
    echo '模型校验失败，请重新下载。' >&2
    exit 1
  fi
  mv "$MODEL.download" "$MODEL"
fi
"$ROOT/build.sh" --install
