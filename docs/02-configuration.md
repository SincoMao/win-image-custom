# 第 2 章 配置参考（config.ps1）

`config.ps1` 是流水线唯一需要按环境修改的文件，同时承担共享函数库的角色
（被各步骤脚本以点源方式加载）。本章逐项说明每个配置项的含义、取值与影响。

## 2.1 路径与版本参数

| 参数 | 默认值 | 说明 |
|---|---|---|
| `$IsoPath` | `D:\Win11_Pro.iso` | 源 ISO 完整路径。第一步即被设为只读，全程不修改。 |
| `$WorkDir` | `D:\ISO-Work` | 工作目录。流水线在其中创建 `ISO\`（解包副本）、`Mount\`（挂载点）、`Logs\`（日志）。 |
| `$OutputIso` | `D:\Win11_Dev.iso` | 最终产物路径。重复运行时自动覆盖同名文件。 |
| `$EditionName` | `Windows 11 专业版` | 用于在 WIM/ESD 索引中精确匹配版本的名称（`ImageName` 全等比较）。 |

### 关于 `$EditionName` 的取值

版本名必须与源介质内 `ImageName` 完全一致（区分语言，不区分大小写之外的任何字符）。
中文介质的版本名是中文，英文介质是英文：

| 介质语言 | 专业版版本名 |
|---|---|
| 简体中文 | `Windows 11 专业版` |
| 英文 | `Windows 11 Pro` |

查看源介质全部版本名的方法：

```powershell
Get-WindowsImage -ImagePath <挂载ISO后的盘符>:\sources\install.esd |
    Select-Object ImageIndex, ImageName
```

> **重要**：`config.ps1` 含有中文字符串时必须以 **UTF-8 with BOM** 编码保存。
> Windows PowerShell 5.1 对无 BOM 的脚本按 ANSI 代码页解析，中文字符串会乱码，
> 进而导致版本名匹配失败。

## 2.2 功能开关

所有开关取值均为布尔型。除特别注明外，默认值为 `$true`。

| 开关 | 作用范围 |
|---|---|
| `$RemoveDefender` | 三层冗余的全部内容：8 个服务 `Start=4`、策略层键值、Defender 二进制与计划任务摘除、SetupComplete.cmd 兜底 |
| `$RemoveSecHealthUI` | 摘除 `Windows\SystemApps\Microsoft.Windows.SecHealthUI_cw5n1h2txyewy` 并移除同名预配 AppX 包 |
| `$DisableBitLockerAutoEncrypt` | `Control\BitLocker PreventDeviceEncryption=1`，阻止 OOBE 期间自动启用设备加密 |
| `$DisableSmartScreen` | Explorer（字符串 `Off`）、系统策略、Edge 策略三处，以及默认用户 AppHost 的 Web 内容评估 |
| `$DisableFirewallAllProfiles` | 域/专用/公用三配置文件策略 `EnableFirewall=0`；**不停** `mpssvc` 服务 |
| `$DisableVBS_HVCI_CredGuard` | DeviceGuard 两项、HVCI/CredentialGuard 场景、`LsaCfgFlags=0` |
| `$BypassInstallChecks` | `Setup\LabConfig` 的 TPM/SecureBoot/RAM/CPU 四项 Bypass 置 1 |
| `$DisableTelemetry` | `Policies\Microsoft\Windows\DataCollection AllowTelemetry=0` |
| `$DisableSpectreMeltdownMitigations` | **默认 `$false`**。置 `$true` 时写入 `FeatureSettingsOverride=3` 与 `FeatureSettingsOverrideMask=3`，关闭熔断/幽灵缓解。默认保留补丁。 |

开关之间无隐含依赖，可任意组合。所有写入均为幂等覆盖（`reg add /f`），重复执行
结果一致。

## 2.3 内置常量（一般无需修改）

| 常量 | 值 | 用途 |
|---|---|---|
| `$MinFreeGB` | `20` | 工作盘最小可用空间阈值 |
| `$DefenderServices` | WinDefend、WdNisSvc、Sense、SecurityHealthService、WdFilter、WdBoot、WdNisDrv、MsSecFlt | 被置为 `Start=4` 的 8 个服务 |
| `$ProtectedServices` | mpssvc、BFE、wscsvc、wuauserv、CryptSvc、DcomLaunch | 红线服务，脚本只读校验、绝不修改 |

## 2.4 共享函数库

`config.ps1` 同时提供以下函数，各步骤脚本共用：

| 函数 | 职责 |
|---|---|
| `Write-Log` | 控制台着色输出 + 追加日志文件（`[OK]/[WARN]/[FAIL]` 级别） |
| `Assert-Admin` | 管理员权限自检，不足即退出 |
| `Find-Oscdimg` | 按既定顺序探测 oscdimg.exe |
| `Invoke-Reg` / `Set-RegDword` / `Set-RegString` | reg.exe 封装；写入遇 ACL 拒绝时自动放松离线键 ACL 后重试一次 |
| `Grant-RegFullControl` / `Enable-TokenPrivilege` | 离线配置单元受保护键的所有权接管与授权（详见第 9 章案例三） |
| `Test-ImageMounted` | 判断挂载点是否存在已挂载映像 |
| `Get-EditionIndex` | 按 `$EditionName` 精确匹配索引，匹配数不为 1 时抛出异常 |
| `Invoke-Dism` | DISM 封装：记录完整命令行与输出，非零退出码抛异常 |
| `Stop-Step` | 统一失败出口：写日志 → 卸载离线配置单元 → `/discard` 卸载 WIM → 退出码 1 |
| `Unload-OfflineHives` | 卸载 CUS_SYS/CUS_SW/CUS_DU 三个挂载别名（带重试） |
