# portable-ai-usb · 零联网便携 AI

> 把一个大模型装进 U 盘。插到任何一台 Windows 电脑上双击就能用，**用的时候全程不需要网络**。

一个 9B 参数的大模型，连同推理引擎、运行库、聊天界面，全部躺在一支普通 U 盘里。
换一台电脑、换一个盘符、换一套显卡，插上去双击 `启动AI.bat` 就行。
对方电脑上什么都没装过也能跑：不用装 Python，不用装 CUDA，不用装 Visual C++ 运行库，不用联网。

```
U盘 ──插入──> 陌生电脑 ──双击──> 浏览器打开 http://127.0.0.1:8080 ──> 开始对话
                                    ↑
                           全过程零联网、零安装、零残留
```

---

## 为什么做这个

市面上已经有好几个"U 盘便携 AI"项目了 —— [Uncensored AI Studio](https://github.com/techjarves/Uncensored-Local-Studio)、
[Ollama portable](https://ollama.com/download)、GPT4All、Jan……它们的思路都很好，但有一个共同点：

**它们首次启动时需要联网。**

Uncensored AI Studio 的 README 写得很直白：

> On first launch, the script automatically **downloads** a portable Node.js runtime and precompiled binaries
> for the corresponding GPU backend.

也就是说，"便携"是从**第二次**启动才成立的。第一次你必须能上网 —— 而且它还要跑一个 Node 运行时。

在**无网络、空气隔离、内网、需要确定性交付**的场景里，这条路直接断掉。
不是"慢一点"，是**跑不起来**。

这个项目反过来做：**引擎、运行时、模型全部预置，U 盘里就是全部**。

|  | 常见便携方案 | **本项目** |
|---|---|---|
| 首次启动 | 需要联网下载运行时 + 二进制 | **完全离线** |
| 运行时依赖 | 自带 Node.js 等（几十~上百 MB） | **无** —— 只用系统自带的 PowerShell |
| 引擎体积 | 视方案而定 | 三套引擎 850 MB，覆盖 CUDA / Vulkan / CPU |
| 显卡支持 | 挑当前机器配一套 | **一套 U 盘随身携带三种后端，自动挑** |
| VC++ 运行库 | 多数未处理 | **app-local 部署，不碰宿主系统** |
| 宿主残留 | 视方案而定 | 日志与模型缓存都写回 U 盘 |

**核心主张只有一个：用的时候零联网。** 准备阶段（把东西塞进 U 盘）当然可以联网；但准备完之后，这支 U 盘再也不需要网络。

---

## 快速开始

### 1. 准备（需要联网，做一次）

在一台能上网的 Windows 电脑上：

```powershell
git clone https://github.com/<你的用户名>/portable-ai-usb.git
cd portable-ai-usb
powershell -ExecutionPolicy Bypass -File tools\准备U盘.ps1
```

脚本会问你 U 盘是哪个盘符，然后自动完成：
- 检查 U 盘是不是 exFAT（FAT32 装不下 6.4 GB 的模型，会提示你格式化）
- 从 llama.cpp 官方 release 下载 **CPU / Vulkan / CUDA** 三套引擎
- 从 HuggingFace 镜像下载 **MiMo-V2.6-Distill-Qwen-9B** 的 GGUF 模型（约 6.4 GB）
- 补齐 Visual C++ 运行库 DLL（app-local，不动宿主系统）
- 全部复制进 U 盘，并做完整性校验

### 2. 使用（不需要联网）

U 盘插到任意 Windows 电脑上，双击：

```
启动AI.bat
```

等 10~40 秒，浏览器自动打开。开始对话。

### 3. 需要手动挡的时候

双击 `高级选项.bat`：

```
[1] NVIDIA 显卡 - 标准      32K 上下文   (最常用)
[2] NVIDIA 显卡 - 大上下文  64K 上下文   (长文档/长对话)
[3] NVIDIA 显卡 - 省显存     8K 上下文   (小显存机)
[4] AMD / Intel 显卡 (Vulkan)
[5] 纯 CPU 模式              任何电脑都能跑，速度慢
[6] 仅检测硬件，不启动
[7] 停止本 U 盘的 AI         不会影响电脑上其它的 llama-server
[8] 打开 AI 网页界面
[9] 环境自检                 U盘文件是否齐全
```

---

## 它是怎么挑后端的

这是整个项目里最值得说的一部分。启动器不会问你"你有显卡吗"，它自己探：

```
检测到 NVIDIA 显卡？
  ├─ 是 → 试 CUDA   ── llama-server --list-devices 能列出 CUDA0？
  │         ├─ 能 ────> 用 CUDA 13.4        (最快)
  │         └─ 不能 ──> 试 Vulkan
  └─ 否 → 试 Vulkan ── 能列出 Vulkan0？
            ├─ 能 ────> 用 Vulkan             (AMD / Intel / 老 NVIDIA 通用)
            └─ 不能 ──> 纯 CPU               (兜底，任何 x86-64 机器都能跑)
```

挑到后端之后再按显存自动配上下文长度和 KV 缓存精度：

| 显存 | 上下文 | KV 缓存 |
|---|---|---|
| ≥ 15 GB | 65536 | q8_0 |
| ≥ 11 GB | 32768 | q8_0 |
| ≥ 8 GB | 16384 | q8_0 |
| ≥ 6 GB | 8192 | q8_0 |
| > 0 但 < 6 GB | 4096（只卸载 20 层） | q4_0 |
| 纯 CPU | 8192 | f16 |

**为什么值得这么麻烦**：一支 U 盘要面对的是"任何一台电脑"，可能是游戏本、可能是办公机、可能是十年前的老机器。
三套引擎加起来 850 MB，换来的是**永远有能跑的那一套**。

### 关于 CPU 指令集

llama.cpp 官方的 Windows 包已经做了**运行时 CPU 分发**
（编译选项 `-DGGML_CPU_ALL_VARIANTS=ON -DGGML_NATIVE=OFF -DGGML_BACKEND_DL=ON`），
解压出来能看到 14 个 `ggml-cpu-*.dll`，从 `sandybridge` 一路到 `zen4`。

同一个 `llama-server.exe` 在任何 x86-64 机器上都会自动加载匹配的那个 DLL。
**不需要自己编译**。（这一点跟某些项目"启动即 Illegal instruction"的坑正好相反 —— 那些项目发的是 `GGML_NATIVE=ON` 的本机优化版。）

---

## 实测数据

测试机：AMD Ryzen 16 核 / 31.2 GB 内存 / NVIDIA RTX 5070 Ti Laptop 12 GB / Windows 11
模型：MiMo-V2.6-Distill-Qwen-9B **Q5_K_M**（6.40 GB）
引擎：llama.cpp b11270

### 纯生成速度（`llama-bench -p 0 -n 48`）

| 后端 | 速度 |
|---|---|
| CUDA 13.4 | **62.07 tok/s** |
| Vulkan | **48.53 tok/s** |
| CPU | 3.43 tok/s |

### 端到端（从 U 盘启动到能对话）

| 环节 | 耗时 |
|---|---|
| CUDA 引擎冷启动（首次，从 U 盘读模型） | ~52 秒 |
| CUDA 引擎热启动 | ~10 秒 |
| Vulkan 引擎 | ~9 秒 |
| CPU 引擎 | ~5 秒 |
| 实际对话生成速度 | 17 ~ 33 tok/s |

换过盘符（用 `subst` 把 U 盘映射成别的字母）后启动成功，**启动器不依赖盘符**。

### 三套引擎的实际体积

| 后端 | 下载 | 装好后 | 文件数 |
|---|---|---|---|
| CUDA 13.4（含 cudart） | ~549 MB | 711.9 MB | 65 |
| Vulkan | 31.6 MB | 91.9 MB | 62 |
| CPU | 18.3 MB | 48.7 MB | 61 |

---

## 已经在哪些情况下验证过

| 验证项 | 结果 |
|---|---|
| 从 U 盘直接跑 CUDA 推理 | ✅ |
| 把 CUDA 屏蔽掉（`CUDA_VISIBLE_DEVICES=-1`）后自动降级到 CPU | ✅ |
| 换盘符（`subst` 映射）后依然能启动 | ✅ |
| Visual C++ 运行库从 U 盘加载，不依赖宿主安装 | ✅ 用 `Get-Process -Module` 核实过加载路径 |
| exFAT 卷上没有"来自 Internet"标记，不触发 SmartScreen | ✅ |
| 宿主系统盘完全不写（日志、缓存全在 U 盘） | ✅ |
| **在一台全新的、从没装过任何开发工具的 Win11 笔记本上** | ⏳ **还没实测** |

最后一条我没法替你做 —— 那台笔记本不在我手上。
预期是能跑（VC++ 运行库已经 app-local 打包、不依赖任何已安装组件），但**在你亲测之前，这张表里它就是待验证**。

---

## 目录结构

```
U盘根目录/
├── 启动AI.bat              ← 双击这个
├── 高级选项.bat            ← 手动选后端
├── launcher.ps1            ← 启动器（自动探测 + 三级降级）
├── 使用说明.txt
├── docs/                   ← 参考文档、FAQ
├── llama.cpp/
│   ├── cuda13/             ← llama-server.exe + 依赖 DLL（含 vcruntime，app-local）
│   ├── vulkan/
│   └── cpu/
├── models/
│   └── MiMo-V2.6-Distill-Qwen-9B-Q5_K_M.gguf
└── logs/                   ← 运行日志（自动创建）
```

**整个目录是自包含的。** 把它拷到另一个 U 盘、另一个分区、另一个盘符，一样能跑。
`launcher.ps1` 里所有路径都由 `$PSScriptRoot` 拼出来，没有任何一处写死盘符。

---

## 硬件要求

|  | 最低 | 推荐 |
|---|---|---|
| U 盘 | USB 3.0，16 GB，exFAT | USB 3.0+，64 GB |
| 系统 | Windows 10 / 11 x64 | Windows 11 x64 |
| 内存 | 8 GB | 16 GB+ |
| 显卡 | 无所谓（会降到 CPU） | NVIDIA（走 CUDA）或任意支持 Vulkan 的卡 |

**U 盘必须格式化成 exFAT 或 NTFS。** FAT32 单文件上限 4 GB，装不下 6.4 GB 的模型。

### 速度的现实

普通 USB 闪存盘（不是移动固态）的**顺序读**大概 100~150 MB/s，**4K 随机读只有 1~5 MB/s**。
加载模型是顺序读，所以问题不大（6.4 GB / 100 MB/s ≈ 60 秒）。
但如果你打算频繁切换模型，移动固态会舒服很多。

**别把 KV 缓存开得超过物理内存的 20~30%**，否则会开始换页，速度断崖式下跌。

---

## 不会干扰宿主机

一支 U 盘要插到别人电脑上，最容易出事的就是"手伸太长"。这里做了三件事：

- **停止 AI 时只停自己的。** `高级选项.bat` 的 [7] 不用 `taskkill /IM llama-server.exe`，
  而是按可执行文件路径过滤，只终止位于本 U 盘目录内的进程。宿主上另跑的 llama-server 会被跳过并打印出来。

- **端口被占时先认人。** 8080 被占时，启动器会向那个服务请求 `/props`，
  看它的 `model_path` 是否指向本 U 盘的模型。是 → 直接打开页面；不是 → 自动改用 8081~8100 的空闲端口，
  而不是硬挤上去。

- **运行产物全部落在 U 盘。** 日志写进 `logs\`，模型缓存也由环境变量指回盘内。

## 已知问题 / 边界

- **Windows 11 S 模式** 会拒绝运行非商店应用，需要先退出 S 模式。
- **企业受管电脑** 如果策略禁止从可移动介质执行程序（AppLocker / WDAC），这条路走不通。这是策略层面的限制，不是技术问题。
- **杀毒软件** 偶尔会拦 `llama-server.exe`，加白名单即可。
- **没有独显的机器** 会退到纯 CPU，约 3.4 tok/s —— 能用，但只适合短对话。
- **macOS / Linux** 这套启动脚本是 Windows 专用的。模型文件（`.gguf`）本身通用，但那边要另配引擎。

更多见 [docs/常见问题.md](docs/常见问题.md)。

---

## 参考与归属

这个项目是**集成**，不是发明。底下这几层全部是别人的工作：

| 组件 | 作者 | 许可 |
|---|---|---|
| [llama.cpp](https://github.com/ggml-org/llama.cpp) | Georgi Gerganov 及贡献者 | MIT |
| [MiMo-V2.6-Distill-Qwen-9B](https://huggingface.co/XiaomiMiMo/MiMo-V2.6-Distill-Qwen-9B) | 小米 MiMo 团队 | MIT |
| [Qwen3.5-9B](https://huggingface.co/Qwen/Qwen3.5-9B)（基座） | 阿里通义千问 | Apache-2.0 |

完整的归属声明与许可文本见 [THIRD-PARTY.md](THIRD-PARTY.md)。
详细的技术参考链接见 [docs/参考资料.md](docs/参考资料.md)。

关于"便携应用"这个思路本身的来源，可以追溯到 [PortableApps.com](https://portableapps.com/)（2005 年前后）。
本项目做的是把这个思路套到本地大模型上，并且**把"零联网"当作硬约束**。

## 许可

本项目自身的代码（启动器、脚本、文档）以 **MIT** 发布，见 [LICENSE](LICENSE)。
