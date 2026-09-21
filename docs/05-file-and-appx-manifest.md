# 第 5 章 文件摘除与预配包清单

本章说明 03-customize.ps1 在挂载映像内执行的文件与预配包删除：删什么、为什么、
怎么删，以及明确不删什么。

## 5.1 文件摘除清单

| 相对路径（挂载点内） | 内容 | 开关 |
|---|---|---|
| `Program Files\Windows Defender\` | Defender 引擎实例一（平台二进制） | `RemoveDefender` |
| `Program Files\Windows Defender Advanced Threat Protection\` | WDATP（Sense）组件 | `RemoveDefender` |
| `ProgramData\Microsoft\Windows Defender\` | Defender 引擎实例二（数据与副本） | `RemoveDefender` |
| `Windows\System32\drivers\wd\` | WdFilter/WdBoot 等驱动文件（新版镜像可能不存在，自动跳过） | `RemoveDefender` |
| `Windows\System32\Tasks\Microsoft\Windows\Windows Defender\` | Defender 计划任务定义 | `RemoveDefender` |
| `Windows\SystemApps\Microsoft.Windows.SecHealthUI_cw5n1h2txyewy\` | "Windows 安全中心"应用 | `RemoveSecHealthUI` |

注意要点：

1. **Program Files 与 ProgramData 是两个独立实例**，缺一不可；只删其一，
   另一实例仍可被拉起。
2. **幂等**：逐项先判存在性。新版 Windows 11 镜像可能本就不含其中若干目录
   （例如 `drivers\wd`），脚本记录"已缺席，跳过"，不视为错误。
3. **每一项摘除都写入日志**，审计时可逐项对照。

## 5.2 删除方法

映像内系统目录的 ACL 拒绝 Administrators 直接删除，因此删除前依次执行：

```
takeown.exe /F <目标> /R /D Y
icacls.exe <目标> /grant Administrators:F /T /C /Q
Remove-Item -Recurse -Force
```

三者均为 Windows 内置工具/命令。删除后再次检查路径存在性，未删净则抛出异常
并进入统一失败出口（卸载配置单元 + `/discard` 卸载映像）。

## 5.3 预配 AppX 包

```powershell
Get-AppxProvisionedPackage -Path <挂载点> |
    Where-Object { $_.DisplayName -eq 'Microsoft.Windows.SecHealthUI' } |
    Remove-AppxProvisionedPackage
```

- 白名单只有 `Microsoft.Windows.SecHealthUI` 一项，**其余预配包一律不动**
  （含 Store、计算器等全部保留）。
- 部分新版镜像中该包不存在（安全中心仅以 SystemApps 形态存在或已调整分发方式），
  脚本记录提示后继续。

## 5.4 明确不删除的内容（红线）

| 内容 | 原因 |
|---|---|
| `Windows\WinSxS` 下任何内容 | 组件存储是补丁与可选功能安装的基础；其中未注册的 Defender 副本无服务注册即为死文件，随累积更新自然更迭 |
| 其他系统组件、驱动、字体 | 保证 Visual Studio 等大型软件可正常安装运行 |
| .NET / VC++ / DirectX 运行库 | 同上 |
| 其他预配 AppX 包 | 同上 |
| `wuauserv`、`CryptSvc`、`DcomLaunch` 及网络/存储栈服务 | 保证可正常打补丁、网络与存储功能完整 |
| `mpssvc`、`BFE` 服务 | 防火墙只关策略；停服务会破坏 DHCP/IPsec |
| 激活、ei.cfg、产品密钥相关内容 | 授权合规红线 |

## 5.5 不执行的操作

- 不执行 `dism /cleanup-image /startcomponentcleanup`；
- 不执行 `dism /cleanup-image /resetbase`。

二者会压缩组件存储并固化更新状态，属于以牺牲可维护性换取体积的做法，
与本工具"系统完整可维护"的目标相冲突。
