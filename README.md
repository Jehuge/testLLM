# 交互作品与本地工具工作区

当前优先制作 **自动机械腕表**，下一项是 **扫地机器人及全能基站**。这两个项目已完成规划，应用源码尚未创建。

## 项目入口

| 项目 | 状态 | 入口 |
| --- | --- | --- |
| 自动机械腕表 | 第一项，待开发 | [项目规划](./projects/automatic-watch/PLAN.md) |
| 扫地机器人及全能基站 | 后续项目，方案保留 | [项目规划与技术分析](./projects/robot-vacuum/PLAN.md) |
| 声纹对比桌面工具 | 已有 macOS 原生应用 | [使用、构建与验证说明](./projects/voiceprint-desktop/README.md) |

机械交互作品的技术方向为 Vite + TypeScript + 原生 Three.js，配合 HTML/CSS 面板、程序化模型、总成拆解、机构联动与自动镜头。详情见各项目规划。

## 目录

```text
testLLM/
├── README.md
├── projects/
│   ├── automatic-watch/          首期：自动机械腕表
│   │   └── PLAN.md
│   ├── robot-vacuum/             后续：扫地机器人及基站
│   │   └── PLAN.md
│   └── voiceprint-desktop/       声纹工具源码与本地开发环境
├── archive/
│   ├── pelican-ride/             鹈鹕骑行 SVG 动画
│   │   └── index.html
│   ├── pirate-jelly/             海盗果冻 WebGPU 场景
│   │   ├── index.html
│   │   └── prompt.txt            原始创作提示词
│   └── frame-sequence/
│       └── frames/               900 张既有竖屏序列帧
└── docs/
    ├── README.md                 制作顺序
    └── organization.md           文件迁移与路径处理记录
```

## 查看既有网页

在仓库根目录运行：

```bash
python3 -m http.server 8000 --bind 127.0.0.1
```

- [鹈鹕骑行动画](http://127.0.0.1:8000/archive/pelican-ride/)
- [海盗果冻场景](http://127.0.0.1:8000/archive/pirate-jelly/)

海盗场景使用 WebGPU，需要浏览器支持并启用相应图形能力。900 张序列帧独立归档，保留原始编号 `f0000.png`–`f0899.png`，尺寸为 1080×1920。

## 声纹工具

源码和脚本入口已移到 `projects/voiceprint-desktop/`。桌面已安装的应用使用用户目录下的独立引擎运行。

```bash
cd projects/voiceprint-desktop
.venv/bin/python test_worker.py
```

安装与构建步骤见[声纹工具说明](./projects/voiceprint-desktop/README.md)。`.venv/`、模型及 `build/` 保留在本机，由 Git 忽略。

所有源文件与素材的移动均由 Git 记录。后续代码、素材和项目文档放在对应项目目录；公共说明放在 `docs/`，既有独立实验放在 `archive/`。
