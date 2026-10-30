# 项目目录整理记录

日期：2026-10-30。

## 文件迁移

| 原路径 | 新路径 |
| --- | --- |
| `docs/automatic-watch-plan.md` | `projects/automatic-watch/PLAN.md` |
| `docs/robot-vacuum-station-plan.md` | `projects/robot-vacuum/PLAN.md` |
| `voiceprint-desktop/` | `projects/voiceprint-desktop/` |
| `index.html` | `archive/pelican-ride/index.html` |
| `pirate-jelly.html` | `archive/pirate-jelly/index.html` |
| `粘贴的内容-1.txt` | `archive/pirate-jelly/prompt.txt` |
| `frames_v/` | `archive/frame-sequence/frames/` |

两个 HTML 页面均为独立页面，没有对原根目录文件或帧序列的外部引用。它们按原内容迁移。海盗场景的提示词与页面放在同一目录，原提示词末尾已有截断，保留原样。

## 文档与本地环境

- 根目录新增 `README.md`，汇总当前项目、归档演示和运行入口。
- 更新规划文件和制作顺序中的相对链接，使其指向新位置。
- 更新 `.gitignore` 中声纹工具虚拟环境、模型与构建目录的路径。
- 声纹工具的 `.venv/`、`models/`、`build/` 随源码目录整体移动。修复 `.venv/bin/` 下文本脚本中指向旧虚拟环境目录的绝对路径，包括环境激活脚本和命令行入口；这些本地生成文件继续忽略。
- 声纹工具构建脚本根据脚本所在目录定位源码。已安装应用的运行配置指向 `~/Library/Application Support/VoiceprintDesktop/Engine/`，不需要因项目目录整理而重新安装。

## 核查结果

- 迁移前共 918 个 Git 跟踪文件。其中 914 个文件的 SHA-256 与原文件一致；另外 4 个文件仅更新忽略规则或文档链接。
- 900 张序列帧完整保留，编号从 `f0000.png` 到 `f0899.png` 连续。
- 10 处文档本地链接通过检查；虚拟环境、模型与构建文件仍被 Git 忽略。
- 迁移后的虚拟环境激活与依赖加载通过，已有声纹测试 5 项全部通过，构建与安装脚本通过 shell 语法检查。
- 两个归档网页、第一张与最后一张序列帧共 4 个新路径通过本地 HTTP 读取检查；检查后临时服务已关闭。

本次整理的 Git 提交保留全部源文件和素材的重命名记录。
