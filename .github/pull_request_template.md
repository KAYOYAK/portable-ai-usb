## 这个 PR 做了什么

<!-- 一句话说清。 -->

## 为什么

<!-- 解决什么问题、满足什么场景。如果关联某个 Issue，写在下面。 -->

## 验证方式

<!-- 你实际跑过什么。不要写"应该没问题"。 -->

- [ ] 改过 `launcher.ps1` / `tools\*.ps1` / `tools\_公共.ps1` 的话，**实跑过一次 `启动AI.bat`**，能正常对话
- [ ] 改过 `高级选项.bat` 的话，**在 cmd.exe 里实跑过一遍**，菜单正常显示
- [ ] 改过 `tools\menu.ps1` 的话，**每个改动到的选项都实跑过一次**（分支静默失效过一次，见踩坑记录十三）
- [ ] 两个 `.bat` 仍然是**纯 ASCII + CRLF**（中文不进 `.bat`，见下面「编码约定」）
- [ ] `.ps1` 仍然是 **UTF-8 带 BOM**
- [ ] 改过 `启动AI.sh` 的话，跑过 `bash -n 启动AI.sh`，并确认是 **LF、不带 BOM**
- [ ] 改过 `tools\自检.ps1` 的话，跑过一遍 `[9] 环境自检`

## 编码约定（改动前务必确认）

这几条不是风格偏好，是踩过坑之后定下来的：

1. **`.ps1` 必须 UTF-8 带 BOM。** Windows PowerShell 5.1 读没有 BOM 的文件时按系统 ANSI
   码页解码，脚本里的中文直接变乱码 —— 不是显示问题，是读进去就错了。
   `write` / `edit` 这类工具会顺手把 BOM 去掉，改完要补：
   `[System.IO.File]::WriteAllText($p,$t,(New-Object System.Text.UTF8Encoding $true))`
2. **`.bat` 必须 UTF-8 **不带** BOM。** BOM 会被 cmd 当成一条命令去执行。
3. **`.bat` 里不要写中文。** cmd.exe 按本地 ANSI 码页逐字节切分批处理，中文 UTF-8
   字节会撞进 GBK 双字节区间，把解析器带偏成乱码命令。中文界面一律放 PowerShell。
4. **`.sh` 必须 LF、不带 BOM。** 行尾带 CR 时 bash 报 `$'\r': command not found`。
   U 盘多是 exFAT，没有 Unix 权限位，`chmod +x` 存不住 —— 所以调用方式是
   `bash 启动AI.sh`，不是 `./启动AI.sh`，脚本里不要依赖可执行位。
5. **跨函数传值用返回码，不要用全局变量。** bash 的 `$( )` 会开子 shell，
   函数里设的变量传不出来。详见踩坑记录十五、十六。

## 相关 Issue

<!-- Fixes #123 -->
