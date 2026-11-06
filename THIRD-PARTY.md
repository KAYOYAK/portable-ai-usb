# 第三方组件与许可

本项目自身只包含**启动脚本与文档**（Apache-2.0，见 `LICENSE`）。
运行时使用的引擎和模型**不在仓库里**，由 `tools\准备U盘.ps1` 从上游官方渠道下载到你的 U 盘。
下面是这些组件的信息与许可，以及再分发时需要注意的事项。

---

## 1. llama.cpp — 推理引擎

- 项目：<https://github.com/ggml-org/llama.cpp>
- 许可：**MIT**
- 版权：The ggml authors
- 本 U 盘用的是**官方预编译 Windows 二进制包**（release tag 形如 `b11270`），未做任何修改。

> llama.cpp 的发布页里，`releases/latest` 那个 tag（2026-10-16 当天查为 `v0.7.0`）**只有源码包，没有二进制**。
> 真正的预编译包挂在 `b####` 形式的 tag 上。
> 取用方式：<https://github.com/ggml-org/llama.cpp/releases/expanded_assets/b11270>

**再分发注意**：MIT 允许自由再分发，但必须保留原始版权声明与许可文本。
如果你把自己做好的整套 U 盘镜像发出去，请把 llama.cpp 的 `LICENSE` 一并放进去。

---

## 2. MiMo-V2.6-Distill-Qwen-9B — 模型

- 上游仓库：<https://huggingface.co/XiaomiMiMo/MiMo-V2.6-Distill-Qwen-9B>
- 量化版本：<https://huggingface.co/bartowski/MiMo-V2.6-Distill-Qwen-9B-GGUF>
- 官方 GGUF：<https://huggingface.co/ggml-org/MiMo-V2.6-Distill-Qwen-9B-GGUF>
- 许可：**MIT**
- 版权：小米 MiMo 团队
- 基座模型：[Qwen/Qwen3.5-9B](https://huggingface.co/Qwen/Qwen3.5-9B)（Apache-2.0）

**模型架构要点**（决定了 U 盘场景下的内存开销）：

| 项 | 值 |
|---|---|
| 层数 | 32 |
| 注意力 | 每 4 层一个 `full_attention`，其余 24 层是 `linear_attention` |
| KV 头数 | 4 |
| head_dim | 256 |
| 最大位置 | 262144 |
| vocab | 248320 |

**只有 8 层是全注意力**，所以 KV 缓存极小：
`2 × 8 层 × 4 头 × 256 dim = 16384 元素/token` → f16 约 32 KB/token → **8K 上下文只要约 256 MB**。

作为对比，同样 8K 上下文下 Qwen3-8B 要 2.3 GB。
这个架构对"内存有限的陌生电脑"极其友好。

**再分发注意**：模型是 MIT，允许再分发。但它是**分离的版权作品**，
建议在 U 盘里单独放一份 `models\LICENSE-MiMo.txt`，不要跟本项目的 MIT 许可混在一起。

---

## 3. Visual C++ 运行库 DLL

`tools\准备U盘.ps1` 会从 `C:\Windows\System32` 复制下列 DLL 到引擎目录（app-local 部署）：

```
vcruntime140.dll          vcruntime140_1.dll        vcruntime140_threads.dll
msvcp140.dll              msvcp140_1.dll            msvcp140_2.dll
msvcp140_atomic_wait.dll  msvcp140_codecvt_ids.dll
concrt140.dll             vcomp140.dll
```

- 版权：Microsoft Corporation
- 性质：**Microsoft Visual C++ 可再发行组件**（Microsoft Visual C++ Redistributable）
- 用途：让 `llama-server.exe` 在没装过 VC++ 运行库的干净系统上也能启动

**为什么要这么做**：`llama-server.exe` 本身只有 9 KB，它是个 import stub，依赖 `VCRUNTIME140.dll`。
在一台全新的 Windows 上，这个 DLL 可能不存在，程序会直接报"缺少 VCRUNTIME140.dll"起不来。
放进 exe 同目录后，Windows 的 DLL 搜索顺序会**优先加载 exe 同目录的版本**，不碰宿主系统。

**再分发注意**：微软允许随应用再分发这些 DLL（属于 Visual Studio 可再发行组件的一部分）。
如果你要把整套 U 盘发出去，建议同时附上微软的再分发条款说明。

---

## 4. PowerShell

启动器是 `.ps1` 脚本，靠 Windows 自带的 Windows PowerShell 5.1 运行。
不需要额外安装任何东西 —— 这正是"零运行时依赖"的前提。

---

## 5. Xiaomi-OCR-0 — 文档识别模型（v1.12.0 起，可选）

- 上游仓库：<https://huggingface.co/xiaomi-research/Xiaomi-OCR-0>
- 量化版本：<https://huggingface.co/prithivMLmods/Xiaomi-OCR-0-GGUF>
- 许可：**Apache-2.0**
- 版权：小米 MiMo 团队（SeerRay-Lab）
- 基座模型：[Qwen/Qwen3.5-0.8B-Base](https://huggingface.co/Qwen/Qwen3.5-0.8B-Base)（Apache-2.0）
- 本 U 盘用 Q5_K_M 量化（551 MB）+ bf16 投影文件（198 MB）
- 只在 `models\ocr\` 里，是菜单 `[23]` 用的独立组件，不参与聊天

**再分发注意**：Apache-2.0 允许商用与再分发，但必须保留版权声明、
许可文本，并说明修改（本项目只做量化，未改架构）。
上游还提供了一份 arXiv 技术报告，引用时请注明。

---

## 6. MiMo Code — AI 编程助手（v1.12.0 起，可选）

- 项目：<https://github.com/XiaomiMiMo/MiMo-Code>
- 许可：**MIT**
- 版权：Xiaomi MiMo
- 本 U 盘用的是官方发布的 **独立可执行文件**，从作者的 FDS 拉取，未做任何修改，
  也不经过 npm
- **六个平台各放一份**：Windows x64 / arm64、macOS arm64 / x64、Linux x64 / arm64
  （合计约 710 MB）。MiMo Code 是按平台发布不同二进制的，只放 Windows 那份的话，
  插到 Mac 上这个功能就用不了
- 它不需要 Node.js 运行时 —— 那是 npm 安装方式才需要的
- 升级靠 `agent\版本.txt` 比对；`准备U盘.ps1` 发现版本不一致会重新下载

> **这一项没有 SHA-256 可校验**：上游 FDS 不发布 `.sha256`（其他组件都有）。
> `准备U盘.ps1` 的验证方式是「大小相符 + 解压后跑一次 `--version`」。

**再分发注意**：MIT 允许自由再分发，保留版权声明与许可文本即可。

---

## 一句话总结

| 层 | 谁做的 | 许可 |
|---|---|---|
| 推理引擎 | llama.cpp 社区 | MIT |
| 模型权重 | 小米 MiMo 团队（基座：通义千问） | MIT / Apache-2.0 |
| 文档识别模型 | 小米 MiMo 团队（基座：Qwen3.5-0.8B） | Apache-2.0 |
| AI 编程助手 | 小米 MiMo 团队 | MIT |
| C++ 运行库 | Microsoft | 可再发行组件 |
| 启动器 + 文档 | 本项目 | MIT |
