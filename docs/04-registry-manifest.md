# 第 4 章 注册表清单完整参考

本章是 03-customize.ps1 写入的全部注册表项的规格化清单。所有写入通过
`reg add /f` 完成，天然幂等。离线配置单元只暴露 `ControlSet001`，无需也不应
向其他 ControlSet 写入。

三个配置单元的挂载别名：

| 别名 | 来源文件 |
|---|---|
| `HKLM\CUS_SYS` | `Mount\Windows\System32\config\SYSTEM` |
| `HKLM\CUS_SW`  | `Mount\Windows\System32\config\SOFTWARE` |
| `HKLM\CUS_DU`  | `Mount\Users\Default\ntuser.dat`（默认用户配置单元） |

## 4.1 SYSTEM 配置单元

### 4.1.1 服务层禁用（开关 `$RemoveDefender`）

路径前缀 `HKLM\CUS_SYS\ControlSet001\Services\`，以下 8 个服务键均写入
`Start = 4 (DWORD)`（4 = 禁用）：

| 服务 | 说明 |
|---|---|
| WinDefend | Microsoft Defender 防病毒服务 |
| WdNisSvc | Defender 网络检查服务 |
| Sense | Defender for Endpoint（WDATP）传感器 |
| SecurityHealthService | Windows 安全中心服务（Defender 专属部分） |
| WdFilter | Defender 文件系统筛选驱动 |
| WdBoot | Defender 预启动驱动 |
| WdNisDrv | Defender 网络检查驱动 |
| MsSecFlt | Microsoft 安全事件筛选驱动 |

### 4.1.2 明确禁止修改的服务（红线）

以下服务脚本只读校验、绝不写入。06-verify.ps1 会断言它们的 `Start` 值不为 4：

| 服务 | 保留原因 |
|---|---|
| mpssvc | Windows 防火墙服务。防火墙只关策略；停服务会破坏 DHCP/IPsec |
| BFE | 基础筛选引擎，mpssvc 的依赖 |
| wscsvc | 安全中心（健康监视）服务 |
| wuauserv | Windows Update，保证可正常打月度补丁 |
| CryptSvc | 加密服务，更新与签名验证依赖 |
| DcomLaunch | COM 基础设施 |

### 4.1.3 BitLocker 自动加密（开关 `$DisableBitLockerAutoEncrypt`）

| 路径 | 值 | 类型 | 数据 |
|---|---|---|---|
| `ControlSet001\Control\BitLocker` | `PreventDeviceEncryption` | DWORD | `1` |

阻止 OOBE 期间对系统盘自动启用设备加密。

### 4.1.4 虚拟化安全（开关 `$DisableVBS_HVCI_CredGuard`）

| 路径 | 值 | 类型 | 数据 |
|---|---|---|---|
| `ControlSet001\Control\DeviceGuard` | `EnableVirtualizationBasedSecurity` | DWORD | `0` |
| `ControlSet001\Control\DeviceGuard` | `RequirePlatformSecurityFeatures` | DWORD | `0` |
| `ControlSet001\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity` | `Enabled` | DWORD | `0` |
| `ControlSet001\Control\DeviceGuard\Scenarios\CredentialGuard` | `Enabled` | DWORD | `0` |
| `ControlSet001\Control\Lsa` | `LsaCfgFlags` | DWORD | `0` |

分别关闭：基于虚拟化的安全性（VBS）、平台安全特性要求、内核隔离内存完整性
（HVCI）、Credential Guard，以及 LSA 保护的 UEFI 锁定标志。

### 4.1.5 安装检测绕过（开关 `$BypassInstallChecks`）

路径 `ControlSet001\Setup\LabConfig`，四个值均为 DWORD `1`：

`BypassTPMCheck`、`BypassSecureBootCheck`、`BypassRAMCheck`、`BypassCPUCheck`

### 4.1.6 熔断/幽灵缓解（开关 `$DisableSpectreMeltdownMitigations`，默认关）

仅当开关为 `$true` 时写入，路径
`ControlSet001\Control\Session Manager\Memory Management`：
`FeatureSettingsOverride = 3`、`FeatureSettingsOverrideMask = 3`（均为 DWORD）。
默认不写入任何值，系统保留缓解补丁。

## 4.2 SOFTWARE 配置单元

### 4.2.1 Defender 策略层（开关 `$RemoveDefender`）

| 路径 | 值 | 类型 | 数据 |
|---|---|---|---|
| `Microsoft\Windows Defender\Features` | `TamperProtection` | DWORD | `0` |
| `Policies\Microsoft\Windows Defender` | `DisableAntiSpyware` | DWORD | `1` |
| `Policies\Microsoft\Windows Defender` | `DisableAntiVirus` | DWORD | `1` |
| `Policies\Microsoft\Windows Defender\Real-Time Protection` | `DisableRealtimeMonitoring` | DWORD | `1` |
| 同上 | `DisableBehaviorMonitoring` | DWORD | `1` |
| 同上 | `DisableOnAccessProtection` | DWORD | `1` |
| 同上 | `DisableScanOnRealtimeEnable` | DWORD | `1` |
| 同上 | `DisableIOAVProtection` | DWORD | `1` |
| 同上 | `DisableScriptScanning` | DWORD | `1` |
| `Policies\Microsoft\Windows Defender\Spynet` | `SpynetReporting` | DWORD | `0` |
| `Policies\Microsoft\Windows Defender\Spynet` | `SubmitSamplesConsent` | DWORD | `2` |

`SubmitSamplesConsent = 2` 表示"永不发送"样本。

> 说明：`Microsoft\Windows Defender\Features` 键带有拒绝 Administrators 写入的
> ACL。脚本检测到拒绝访问后，会自动启用 SeTakeOwnershipPrivilege、接管所有权并
> 授予 Administrators 完全控制后重试。该机制只作用于离线配置单元内的目标键。

### 4.2.2 SmartScreen（开关 `$DisableSmartScreen`）

| 路径 | 值 | 类型 | 数据 |
|---|---|---|---|
| `Microsoft\Windows\CurrentVersion\Explorer` | `SmartScreenEnabled` | SZ | `Off` |
| `Policies\Microsoft\Windows\System` | `EnableSmartScreen` | DWORD | `0` |
| `Policies\Microsoft\Edge` | `SmartScreenEnabled` | DWORD | `0` |

### 4.2.3 防火墙策略（开关 `$DisableFirewallAllProfiles`）

路径前缀 `Policies\Microsoft\WindowsFirewall\`，三个配置文件键
`DomainProfile`、`StandardProfile`（专用）、`PublicProfile`（公用）均写入
`EnableFirewall = 0 (DWORD)`。

### 4.2.4 遥测（开关 `$DisableTelemetry`）

| 路径 | 值 | 类型 | 数据 |
|---|---|---|---|
| `Policies\Microsoft\Windows\DataCollection` | `AllowTelemetry` | DWORD | `0` |

### 4.2.5 OOBE（无条件写入）

| 路径 | 值 | 类型 | 数据 |
|---|---|---|---|
| `Microsoft\Windows\CurrentVersion\OOBE` | `BypassNRO` | DWORD | `1` |

解除安装过程对联网与微软账户的强制要求（等效于手动执行 `oobe\bypassnro`）。

## 4.3 DEFAULT 默认用户配置单元（无条件写入）

| 路径 | 值 | 类型 | 数据 |
|---|---|---|---|
| `Software\Microsoft\Windows\CurrentVersion\AppHost` | `EnableWebContentEvaluation` | DWORD | `0` |

关闭 SmartScreen 对 Web 内容的评估。写入默认用户配置单元后，所有新建用户
（包括 autounattend.xml 创建的账户）均继承该设置。

## 4.4 清单完整性与验证

以上每一项在 06-verify.ps1 中都有对应的断言。任何一项未写入、写成错误值或
被意外删改，核查阶段都会以 `VERIFY FAIL` 指出具体键值。
