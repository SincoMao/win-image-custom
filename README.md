# Win11 开发机镜像定制工具（win-image-custom）

一套基于微软官方工具链的 Windows 11 专业版镜像离线定制流水线。输入一份微软官方 ISO
（Media Creation Tool 或软件下载中心产物），输出一份面向固件/驱动/底层开发场景的定制
ISO：移除或关闭阻碍开发效率的安全组件，同时保持系统完整、可安装任意应用、可正常接收
月度累积更新。

整套流水线仅使用 Windows 自带工具与 Windows ADK 组件（DISM、reg.exe、oscdimg.exe），
不引入任何第三方"系统优化/精简"软件。

## 功能总览

| 定制项 | 实现方式 | 开关 |
|---|---|---|
| 移除 Defender | 8 个相关服务 `Start=4` + 策略层禁用 + 二进制与计划任务摘除 | `RemoveDefender` |
| 移除"Windows 安全中心"应用 | 摘除 SystemApps 目录与 SecHealthUI 预配包 | `RemoveSecHealthUI` |
| 禁止 BitLocker 自动加密 | `Control\BitLocker PreventDeviceEncryption=1` | `DisableBitLockerAutoEncrypt` |
| 关闭 SmartScreen | Explorer / 系统策略 / Edge 三处 + 默认用户 AppHost | `DisableSmartScreen` |
| 关闭防火墙过滤 | 域/专用/公用三配置文件 `EnableFirewall=0`（只关策略，不停服务） | `DisableFirewallAllProfiles` |
| 关闭 VBS / HVCI / Credential Guard | DeviceGuard 与 Lsa 键值置 0 | `DisableVBS_HVCI_CredGuard` |
| 跳过安装硬件检测 | `Setup\LabConfig` 四项 Bypass 置 1 | `BypassInstallChecks` |
| 关闭遥测与 CEIP | `DataCollection AllowTelemetry=0` | `DisableTelemetry` |
| 关闭熔断/幽灵缓解 | 默认关闭（保留补丁），仅预留开关 | `DisableSpectreMeltdownMitigations` |
| 无人值守安装 | `autounattend.xml`：跳过 EULA/OOBE、自动创建本地管理员（账户名与密码在 config.ps1 配置）、BypassNRO | 内置 |

## 设计原则

1. **官方工具链**：仅 DISM / reg.exe / oscdimg.exe 及 Windows 内置命令，拒绝第三方精简工具。
2. **原介质只读**：源 ISO 全程只读，所有修改发生在工作副本；定制失败不产生半成品。
3. **幂等可重入**：任意脚本可重复执行，结果一致；失败步骤卸载配置单元并 `/discard` 卸载 WIM 后中止。
4. **可维护性优先**：不执行 `/startcomponentcleanup` 与 `/resetbase`，不动 WinSxS，不禁用
   Windows Update 等基础设施服务，保证系统可正常安装 Visual Studio 等大型软件并持续打补丁。
5. **防复活三层冗余**：策略层 → 服务层 → 二进制层，任一层被更新重置，仍有下层兜底。
   详见 [docs/07-design-anti-revival.md](docs/07-design-anti-revival.md)。

## 快速开始

```powershell
# 1. 安装 Windows ADK（勾选"部署工具 / Deployment Tools"）
winget install --id Microsoft.WindowsADK

# 2. 编辑 config.ps1：设置 ISO 路径、工作目录、版本名、安装账户、功能开关

# 3. 以管理员身份执行
powershell -NoProfile -ExecutionPolicy Bypass -File .\run-all.ps1

# 4. 核查产物（可选但强烈建议）
powershell -NoProfile -ExecutionPolicy Bypass -File .\06-verify.ps1
```

产物为 `$OutputIso` 指定的 ISO 文件；完整日志位于 `$WorkDir\Logs\customize.log`。

## 文档目录

| 章节 | 内容 |
|---|---|
| [docs/01-prerequisites.md](docs/01-prerequisites.md) | 第 1 章 环境与先决条件 |
| [docs/02-configuration.md](docs/02-configuration.md) | 第 2 章 配置参考（`config.ps1` 逐项说明） |
| [docs/03-pipeline.md](docs/03-pipeline.md) | 第 3 章 流水线分步详解（01–05 与 run-all） |
| [docs/04-registry-manifest.md](docs/04-registry-manifest.md) | 第 4 章 注册表清单完整参考 |
| [docs/05-file-and-appx-manifest.md](docs/05-file-and-appx-manifest.md) | 第 5 章 文件摘除与预配包清单 |
| [docs/06-verification.md](docs/06-verification.md) | 第 6 章 产物验证与装机验收 |
| [docs/07-design-anti-revival.md](docs/07-design-anti-revival.md) | 第 7 章 防复活设计与约束红线 |
| [docs/08-maintenance-new-builds.md](docs/08-maintenance-new-builds.md) | 第 8 章 适配新版 Windows 11 的维护指南 |
| [docs/09-troubleshooting.md](docs/09-troubleshooting.md) | 第 9 章 故障排除 |
| [docs/10-ai-assisted-customization.md](docs/10-ai-assisted-customization.md) | 第 10 章 使用 AI 工具完成定制（提示词规范与模板） |

## 目录结构

```
win-image-custom/
├── config.ps1          # 集中配置与共享函数库（唯一需要按环境修改的文件）
├── run-all.ps1         # 流水线编排器（01→05 顺序执行，失败即中止）
├── 01-extract.ps1      # 校验与解包：复制 ISO、ESD→WIM 导出
├── 02-mount.ps1        # 挂载 install.wim
├── 03-customize.ps1    # 注册表注入、文件摘除、AppX 移除、SetupComplete.cmd
├── 04-unattend.ps1     # 生成 autounattend.xml 并提交卸载 WIM
├── 05-repack.ps1       # oscdimg 双启动重打包
├── 06-verify.ps1       # 产物离线核查（70+ 项断言）
└── docs/               # 分章教程
```

## 许可证与责任说明

本工具仅组合微软官方命令行工具与公开的注册表策略项，不修改任何微软二进制文件的
代码与签名。请确保你对所定制的 Windows 副本持有合法授权。移除安全组件会显著降低
系统防护水平，产物镜像仅应用于隔离的开发/测试环境。
