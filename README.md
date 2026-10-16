# portable-ai-usb · 零联网便携 AI

> 把一个大模型装进 U 盘。插到任何一台 Windows 电脑上双击就能用，**用的时候全程不需要网络**。

![界面截图：浏览器里的聊天界面，模型 MiMo-V2.6-Distill-Qwen-9B，右下角显示当前模型](docs/界面截图.png)

一个 9B 参数的大模型，连同推理引擎、运行库、聊天界面，全部躺在一支普通 U 盘里。
换一台电脑、换一个盘符、换一套显卡，插上去双击 `启动AI.bat` 就行。
对方电脑上什么都没装过也能跑：不用装 Python，不用装 CUDA，不用装 Visual C++ 运行库，不用联网。

```
U盘 ──插入──> 陌生电脑 ──双击──> 浏览器打开 http://127.0.0.1:8080 ──> 开始对话
                                    ↑
                           全过程零联网、零安装、零残留
```

> **这个项目没有推广，只有一个人在做。** 如果它帮到你了，回个 star；更欢迎在
> [Issues](https://github.com/KAYOYAK/portable-ai-usb/issues) 里留一句你的硬件和实测速度 ——
> 我手上只有一台电脑、一支 U 盘，[docs/硬件与性能.md](docs/硬件与性能.md) 里那张速度表
> 需要更多人的真实数字才站得住。跑不起来也欢迎来骂，那是更有用的信息。

---

## 为什么不直接用 Ollama / LM Studio 便携版？

因为**它们的"便携"大多从第二次启动才开始**：

|  | 常见便携方案 | **本项目** |
|---|---|---|
| 首次启动 | 需要联网（至少要把模型下下来） | **完全离线**，插上就能用 |
| 模型 | 首次使用时下载 | **6.4 GB 已经躺在盘里** |
| 运行时依赖 | 自带 Node.js / Electron（几十~几百 MB） | **无** —— 只用系统自带的 PowerShell |
| 加速后端 | 通常一套，或按当前机器配一套 | **CUDA / Vulkan / CPU 三套随身带，自动降级** |
| VC++ 运行库 | 多数未处理 | **app-local 部署，不碰宿主系统** |
| 宿主残留 | 视方案而定 | 日志与模型缓存都写回 U 盘 |
| 体积 | 小（因为模型不在里面） | ~7.3 GB（因为模型在里面） |

最直接的一个例子是 [Uncensored AI Studio](https://github.com/techjarves/Uncensored-Local-Studio)，
它的 README 写得很坦白：

> On first launch, the script automatically **downloads** a portable Node.js runtime and precompiled binaries
> for the corresponding GPU backend.

于是"便携"是从**第二次**启动才成立的。第一次你必须能上网。

在**无网络、空气隔离、内网、需要确定性交付**的场景里，这条路直接断掉 ——
不是"慢一点"，是**跑不起来**。

这个项目反过来做：**引擎、运行时、模型全部预置，U 盘里就是全部**。

### 什么时候你该用别的

说句实在话：

- **你有网、而且只在一台固定电脑上用** → 装 Ollama 或 LM Studio 更省事，别折腾 U 盘。
- **你要的是图形界面、模型商店、一键换模型** → 它们的体验比这个项目好得多。
- **你想在一台没有显卡的机器上跑"聪明"的模型** → 9B 就是 9B，换更大的模型才是正解
  （本项目的 `models\` 支持随便换，见 [使用说明.txt](使用说明.txt)）。

本项目的取舍只有一个：**拿体积换"拔了网线照样能用"**。

**核心主张：用的时候零联网。** 准备阶段（把东西塞进 U 盘）当然可以联网；
但准备完之后，这支 U 盘再也不需要网络。

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
| **在一台全新的、从没装过任何开发工具的 Win11 笔记本上** | ✅ **2026-10-16 真机实测通过** |

最后一条是这张表里最要紧的一条，也是「零联网便携」这个定位本身要证的事：

一台出厂状态的 Windows 11 笔记本，**没装过 Visual C++ 运行库，没有 Python / Node / CUDA，
没连过网**，插上 U 盘双击 `启动AI.bat` 直接就起来了。

它之所以能成立，靠的是前面那条 —— VC++ 运行库以 app-local 方式躺在 `llama.cpp\<后端>\`
目录里，Windows 的 DLL 搜索顺序会优先在同目录找，于是不依赖宿主机装过任何东西。

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

**改脚本之前先看这条。** `launcher.ps1` 和 `tools/*.ps1` 必须存成 **UTF-8 带 BOM**。
Windows PowerShell 5.1 读没有 BOM 的文件时会按系统 ANSI 码页解码，脚本里的中文直接变乱码
（不是显示问题，是读进去就错了）。好几种编辑器会默认把 BOM 去掉，改完记得确认一下。
`.bat` 反过来要**不带 BOM** —— BOM 会被 cmd 当成一条命令去执行。

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

本机那支 USB 3.x 闪存盘：顺序读 **127~146 MB/s**、随机 4K **约 2,000 IOPS**、
冷启动加载 6.4 GB 模型 **实测 53.7 秒**（同样的模型放内置 NVMe 只要 5 秒）。

启动器每次启动都会现场测一遍并给出预估等待时间，菜单 `[11]` 也能单独测盘。
分档、怎么挑盘、插哪个口 → [docs/硬件与性能.md](docs/硬件与性能.md)。

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

## 已知限制

这一节刻意写得比项目介绍长。一个"便携 AI"值不值得用，取决于它的边界在哪，不取决于它能做什么。

### 平台

- **只有 Windows。** 启动器、菜单、运行库部署全是 Windows 专用的，macOS / Linux 上用不了这套脚本。
  模型文件（`.gguf`）本身通用，那边要另配引擎。这是有意的取舍，见下面的 Roadmap。
- **Windows 11 S 模式** 会拒绝运行非商店应用，需要先退出 S 模式。
- **Windows on ARM**（骁龙本）没有对应引擎包，跑不了。

### 权限与环境

- **企业受管电脑** 如果策略禁止从可移动介质执行程序（AppLocker / WDAC），这条路走不通。
  这是策略层面的限制，不是技术问题 —— 加白名单也没用。判定方法与对策见 [docs/杀毒软件误报.md](docs/杀毒软件误报.md)。
- **杀毒软件** 偶尔会拦 `llama-server.exe`（未签名 exe + 监听端口，启发式容易误判）。加白名单即可。
- **不需要管理员权限**，但如果目标机器上已经有什么程序占了 8080~8100 整段端口，会启动失败。

### 性能

- **没有独显的机器** 会退到纯 CPU，约 3.4 tok/s —— 能用，但只适合短对话。
- **冷启动 50 秒起步**，取决于 U 盘速度。本机那支 USB 3.x 闪存盘实测 53.7 秒；
  插到 USB 2.0 口上会掉到 4~5 分钟。**这是整个方案里最硬的一道墙。**
  启动器会现场测盘并给出预估等待时间，菜单 `[11]` 可单独测 —— 详见
  [docs/硬件与性能.md](docs/硬件与性能.md)。
- **内存小于 8 GB** 会很吃力。启动器会自动压低上下文并改用 q4_0 KV 缓存，但仍然会频繁换页。

### 能力

- **模型是 9B。** 它能做工具调用、能写代码、中文也可以，但它不是 GPT-4 级别的模型。
  需要更强的话往 `models\` 里换更大的 GGUF 就行 —— 见 [使用说明.txt](使用说明.txt) 的「换模型」一节。
- **上下文默认 32K**，不是无限的。显存够的机器可以用 `高级选项.bat` 的 [2] 开到 64K。
- **界面就是 llama.cpp 自带的 WebUI**，够用但很朴素，没有对话历史管理。
- **多模态未启用。** MiMo 有视觉能力，但需要额外下载 `mmproj-*.gguf` 并给 llama-server 加 `--mmproj`，
  当前启动器没有做这一步。

更多见 [docs/常见问题.md](docs/常见问题.md)。

**想知道这东西怎么踩出来的** → [docs/踩坑记录.md](docs/踩坑记录.md)。
`cmd.exe` 解析中文 `.bat` 错位、VC++ 运行库 app-local、断点续传下坏文件、
PowerShell 的大小写陷阱…… 每条都带报错原文，方便搜过来。

---

## Roadmap

按"对一个陌生用户的实际价值"排序，不是按开发难度。

### 想做

- [ ] **macOS / Linux 启动器** —— 复用同一套 `models\` 与 `llama.cpp\` 目录约定，另写一个 bash 启动器。
      工程量主要在三套引擎的 `.so` / `.dylib` 分发上。
- [ ] **一段 GIF** —— 截图已经有了，但"插上 → 双击 → 开始对话"这 15 秒的过程，
      动态演示比静态图更有说服力。
- [ ] **多模态开关** —— 检测到 `models\mmproj-*.gguf` 就自动加 `--mmproj`，把视觉能力打开。
- [ ] **换模型脚本** —— `tools\换模型.ps1`：列出几个已知能跑的小模型，选一个下进 `models\`。

### 明确不做

- **不做图形安装器。** 双击一个 `.bat` 已经是最短路径；再加一层 Electron 就等于把"零依赖"这个卖点自己拆了。
- **不把模型打包进仓库。** 6.4 GB 放不进 Git，也放不进大多数人的耐心。
- **不盲目追最新引擎版本。** 现在锁定 b11270 并校验 SHA-256；升级要重新验三套后端的
  `--list-devices` 与显存分档，不是改个版本号的事。

### 已完成

- [x] 多模型支持（v1.1.0）
- [x] 在一台全新的 Windows 11 笔记本上实测通过（v1.0.1）
- [x] README 顶部放一张实机运行的界面截图（v1.1.0）
- [x] [开发过程踩坑记录](docs/踩坑记录.md)（v1.1.0）
- [x] **U 盘速度自测 + 加载时间预估**（v1.1.1）—— 启动时实测顺序读，报"预计约 N 秒"；菜单 `[11]` 可单独测
- [x] **慢盘兜底开关**（v1.1.1）—— `-LoadMode none` / 菜单 `[12]`：不用 mmap，整块读进内存
- [ ] 让 [docs/硬件与性能.md](docs/硬件与性能.md) 里的表格带上更多真实机器的数据 ——
      这一条靠 [硬件兼容性反馈](.github/ISSUE_TEMPLATE/hardware_report.yml) 里收到的记录。

---

## 参与

- **跑在什么机器上、什么结果** —— 请开一个 [硬件兼容性反馈](.github/ISSUE_TEMPLATE/hardware_report.yml)。
  这类记录比 Bug 报告更有用：它能进 [docs/硬件与性能.md](docs/硬件与性能.md)，让下一个人知道自己的机器行不行。
- **改动之前**请看 [.github/pull_request_template.md](.github/pull_request_template.md) 里的**编码约定**。
  那三条不是风格偏好，是踩过坑之后定下来的（cmd.exe 会把带中文的 `.bat` 解析错位、
  PowerShell 5.1 会把没 BOM 的 `.ps1` 按 ANSI 码页读成乱码）。
- 完整变更历史见 [CHANGELOG.md](CHANGELOG.md)。

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
