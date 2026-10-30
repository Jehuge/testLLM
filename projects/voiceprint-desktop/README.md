# 声纹对比 · Mac 桌面悬浮球

macOS 原生 SwiftUI / AppKit 程序，使用 sherpa-onnx + ERes2NetV2 中文模型离线比较两段声音。适用 Apple Silicon Mac，macOS 14 及以上。

面板默认 430×580 点，相比初版 580×780 点减少约 45% 的占用面积。录音波形仅在录制时显示，「阈值与说明」默认折叠，可按需展开；窗口仍支持拖动边缘调整大小。

## 使用

1. 双击桌面的「声纹对比.app」，右侧出现悬浮球。拖动可以移动，点击打开面板。
2. 在参考录音 A 中选择「麦克风」或「电脑声音」，点击「开始录音」。第一次使用会请求系统权限。
3. 麦克风录制你的输入设备；电脑声音录制 Mac 正在播放的声音，无须安装虚拟声卡。电脑声音模式不保存屏幕画面，但 macOS 仍要求屏幕与系统音频录制权限。
4. 点击「停止录音」，为 B 重复操作，随后点击「开始声纹对比」。也支持导入 WAV、CAF、AIFF、M4A、MP3 等 macOS 可解码音频。
5. 点击播放图标试听。关闭窗口或点击「收起到悬浮球」只隐藏面板；右键悬浮球或点击菜单栏波形图标可退出。

建议每段 5–15 秒、只有一个说话人、无背景音乐。录音 45 秒自动停止；导入限制 60 秒。程序检测到录音过短或没有足够声音时会给出提示。录制时悬浮球变红。隐藏面板不会停止录音。

首次权限：

- 麦克风：系统设置 → 隐私与安全性 → 麦克风 → 声纹对比。
- 电脑声音：系统设置 → 隐私与安全性 → 屏幕与系统音频录制 → 声纹对比。若 macOS 要求重启，请退出程序后重新打开。
- 应用只在用户点击相应录音按钮后申请权限，不会自动开始录音。

### 开关已打开，仍提示录音授权失败

本地开发版本使用临时签名；更新程序后二进制签名会改变。macOS 可能保留旧版本的授权开关，但拒绝新版本。系统日志中会显示 `Failed to match existing code requirement`。这种情况不是没有打开开关。

先退出声纹对比，在「系统设置 → 隐私与安全性 → 录屏与系统录音」中选中旧的「声纹对比.app」并点减号移除，再点加号添加桌面上的当前程序，随后重新打开。可点击错误提示里的「定位当前程序」在访达中找到准确路径。授权必须由用户在 macOS 界面确认，程序不会修改系统权限数据库。

如果本机已有有效的 Apple 代码签名证书，可以设置 `VOICEPRINT_SIGNING_IDENTITY` 后构建，让后续更新沿用稳定的证书身份；未配置时继续采用本地临时签名，并在版本签名变化时输出重新授权提醒。

结果是余弦相似度，不是“身份概率”或准确率百分比。默认阈值 0.60 仅供试用；距离阈值不足 0.08 时提示复录。请用你自己的同人、异人录音校准阈值。背景噪声、合成变声、多人混音都会影响结果。

## 本地数据

录音保存在 `~/Library/Application Support/VoiceprintDesktop/Recordings/`。替换或清除录音会删除当前旧文件；退出后已录文件仍保留，可从面板的「录音文件夹」查看和手动删除。导入时复制并转码到这个目录，原始文件不修改。每次打开程序面板为空，不会自动载入以前的录音。

没有 HTTP 服务、云端调用、账号或 API Key；录音和声纹推理都在本机完成。安装时会联网下载依赖和模型。

## 构建与重新安装

需要 Xcode Command Line Tools、uv、Python 3.11（uv 可管理）。在本目录执行：

```bash
./setup.sh
```

已有模型和 `.venv` 时，只重建应用并复制到桌面：

更新前请先从菜单栏或悬浮球右键菜单退出正在运行的程序。

```bash
./build.sh --install
open "$HOME/Desktop/声纹对比.app"
```

这是针对当前机器的本地安装版：安装脚本把引擎、模型和独立 Python 虚拟环境部署到 `~/Library/Application Support/VoiceprintDesktop/Engine/`，桌面应用不依赖项目目录，也不会因项目移动而失效。基础 Python 由本机提供，升级或删除基础 Python 后请重新安装环境。模型和运行环境不提交 Git。

开发检查：

```bash
.venv/bin/python test_worker.py
swiftc -parse-as-library -swift-version 5 -target arm64-apple-macosx14.0 \
  -framework AVFoundation -framework ScreenCaptureKit -framework CoreMedia \
  AudioCapture.swift test_capture.swift -o build/test-capture
./build/test-capture
```

启动桌面应用时可传入 `--show-panel` 打开面板；`--compare-files /absolute/a.wav /absolute/b.wav` 导入指定两段文件并分析，便于联调，不会启动录音。

验证记录：音频输入边界检查 5 项通过；采集缓冲区转换到 CAF 的合成音频测试通过；已通过实际界面导入官方录音、同人对比（0.798）、异人对比（0.216）、悬浮球收起与打开。

2026-10-24 授权问题修复验证：系统日志确认授权对应旧版签名。移除旧项、由用户重新确认当前版本授权后，已在实际界面完成电脑声音录制并保存 CAF（16kHz 单声道，录音总长 28.62 秒）。播放约 5 秒官方测试录音，实录经去除首尾静音后与原始文件的声纹相似度为 0.996789。当前应用签名保持不变，录屏与系统录音授权已生效。该测试验证采集链路，不代表模型业务准确率。

上游：[sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx)、[3D-Speaker](https://github.com/modelscope/3D-Speaker)、[官方 ONNX 模型下载](https://github.com/k2-fsa/sherpa-onnx/releases/tag/speaker-recongition-models)。模型 SHA-256 通过上游校验文件核对。分发或商业使用前需核对所选模型权重的许可。
