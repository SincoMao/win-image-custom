# 第 9 章 故障排除

本章收录离线定制 Windows 11 镜像过程中的典型故障。每个案例按"现象 → 机理 →
处置"的结构给出。本工具的实现已内置这些处置；本章供阅读者理解机制，并供自行
扩展脚本时参考。

## 案例一：DISM 挂载报"错误 87，在此上下文中不识别 /wimfile 选项"

**现象**：`dism /mount-image /wimfile:... /index:1 /mountdir:...` 返回错误 87。

**机理**：DISM 各子命令的参数名并不统一。`/wimfile` 是 `/get-wiminfo` 等查询
命令的参数；`/mount-image` 与 `/apply-image` 使用 `/imagefile`。两者不能混用。

**处置**：挂载命令写作

```
dism /mount-image /imagefile:<wim路径> /index:<索引> /mountdir:<挂载点>
```

## 案例二：脚本在 reg query 一个不存在键时整体崩溃

**现象**：脚本以 `$ErrorActionPreference = 'Stop'` 运行，`reg.exe query` 查询一个
不存在的键（预期内的探测动作）时，脚本以 `NativeCommandError` 终止，
错误文本为"系统找不到指定的注册表项或值"。

**机理**：Windows PowerShell 5.1 中，当 `$ErrorActionPreference` 为 `Stop` 时，
原生命令写入 stderr 的任何文本都会被提升为终止性错误——即使 stderr 已被
`2>$null` 重定向丢弃。这使得"查询探测 + 依据退出码分支"这一惯用法失效，
更危险的是它可能击穿失败清理路径本身（清理代码里的探测命令再次抛出异常，
导致 `/discard` 卸载被跳过）。

**处置**：将所有原生命令调用封装在函数内，函数首行将偏好变量局部降为
`Continue`（PowerShell 偏好变量为动态作用域，函数返回后自动恢复），以
`$LASTEXITCODE` 判定成败：

```powershell
function Test-RegKey {
    param([string]$Key)
    $ErrorActionPreference = 'Continue'
    & reg.exe query $Key 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}
```

## 案例三：写入 Defender 注册表键报"拒绝访问"

**现象**：`reg add HKLM\<别名>\Microsoft\Windows Defender\Features /v TamperProtection ...`
返回"错误: 拒绝访问"。

**机理**：Defender 相关键携带防篡改 ACL，Administrators 组默认没有写权限。
离线配置单元中同样如此。另有一个叠加陷阱：PowerShell 注册表提供程序对进程
启动之后才加载的配置单元不可见（`reg.exe` 可正常访问，`Registry::HKLM\...`
路径却报告不存在），因此 `Get-Acl`/`Set-Acl`/`Test-Path` 均不可用于此场景。

**处置**（本工具 `Grant-RegFullControl` 的实现路径）：

1. 通过 P/Invoke 调用 `AdjustTokenPrivileges` 启用 `SeTakeOwnershipPrivilege`；
2. 使用 `Microsoft.Win32.Registry` API（绕开提供程序缓存），以
   `RegistryRights.TakeOwnership` 打开目标路径上**最近的存在键**；
3. 将所有者设置为 Administrators，重新以 `ChangePermissions` 打开，
   追加 Administrators 完全控制规则；
4. 重试原 `reg add` 写入。

**P/Invoke 结构体对齐陷阱**：`TOKEN_PRIVILEGES` 的原生布局为 4 字节对齐
（`DWORD Count; LUID Luid; DWORD Attr`）。C# 中若以 `long` 表示 LUID，
顺序布局会插入 4 字节填充，导致 API 读取到错误的 LUID，
`AdjustTokenPrivileges` 返回成功但特权实际未启用。正确做法是以两个 4 字节
字段表示 LUID，并以 `Marshal.GetLastWin32Error() == 0` 排除
`ERROR_NOT_ALL_ASSIGNED` 的伪成功。

## 案例四：含中文的脚本字符串执行时乱码

**现象**：`$EditionName = 'Windows 11 专业版'` 在运行时变成乱码，版本匹配失败。

**机理**：Windows PowerShell 5.1 对无 BOM 的 `.ps1` 文件按系统 ANSI 代码页解析。
以无 BOM UTF-8 保存的中文按 ANSI 读取后产生乱码。

**处置**：凡含非 ASCII 字符的脚本一律以 **UTF-8 with BOM** 保存。注意多数文本
编辑器与自动化写文件操作默认写入无 BOM UTF-8；对文件进行过程序化改写后应重新
确认 BOM 存在。

## 案例五：Start-Process 提权与输出重定向冲突

**现象**：`Start-Process -Verb RunAs -RedirectStandardOutput ...` 报参数集歧义错误。

**机理**：`-Verb RunAs` 所属参数集不包含 `-RedirectStandardOutput` 等重定向参数，
二者不能同用。

**处置**：在提权的子进程内部自行落盘输出（如 `Tee-Object` 或 `Out-File`），
父进程仅以 `-Wait -PassThru` 等待并读取退出码。

## 案例六：产物 ISO 明显大于源 ISO

**现象**：源 ISO 约 7 GB，产物 ISO 超过 8 GB。

**机理**：见 8.6 节——这不是故障，是压缩格式差异。ESD 采用固态（solid）压缩，
跨文件块去重能力强；`/export-image /compress:max` 产出的 WIM 使用 LZX 非固态
压缩，同内容体积更大。oscdimg 的 `-o` 仅做包内重复文件优化，无法消除该差异。

**处置**：无需处置。若确需缩小体积，可将 `install.wim` 以
`dism /export-image /compress:recovery` 重新导出为 `install.esd` 再打包
（需同步修改 05 步的引导路径检查）；代价是导出耗时显著增加，且本工具默认保留
WIM 形态以保证后续维护便利。

## 8.6 附：微软官方介质体积差异的说明

微软官方下载渠道的不同 ISO 体积差异较大，主要原因包括：

1. **包含版本数**：消费版介质通常合包家庭版/教育版/专业版等多个索引，
   体积随版本数增长；
2. **压缩格式**：`install.esd`（固态压缩）显著小于同内容 `install.wim`；
3. **语言与内置组件**：不同语言镜像的内置应用、语音包、字体不同；
4. **发布批次**：同一版本不同月份的介质集成了不同级别的累积更新。

因此介质间体积差异不能直接反映内容差异，比较应以索引表与版本号为准。
