# 第 1 章 环境与先决条件

本章说明运行本工具前必须满足的全部条件。任何一项不满足时，流水线会在最早的可检测
阶段中止并给出明确提示，不会产出损坏的镜像。

## 1.1 硬件与操作系统

- 操作主机运行 Windows 10/11（64 位），建议使用 Windows 11。
- 当前账户属于本地 Administrators 组，且能够以"以管理员身份运行"方式启动 PowerShell。
  所有脚本入口均内置管理员权限自检，非提权环境会直接退出。
- 工作盘（`$WorkDir` 所在盘）可用空间不少于 20 GB。建议 30 GB 以上：
  解包后的 ISO 约 5–6 GB，挂载的 WIM 展开视图占用同一目录树的硬链接空间，
  导出与重打包过程中还会临时存在一份输出 ISO。

## 1.2 源介质

- 输入为微软官方 Windows 11 ISO。支持两种常见来源：
  - Media Creation Tool 生成的介质（`sources` 下为 `install.esd`，多版本合包）；
  - 微软软件下载中心直接下载的 ISO（可能同样为 ESD，或为 `install.wim`）。
- 流水线自动识别 ESD/WIM：ESD 先按版本名导出单版本 `install.wim`，WIM 则直接校验版本索引。
- 源 ISO 在第一步即被设置为只读属性，全程不会被修改。定制失败或需要重做时，
  源介质始终处于可用状态。

## 1.3 Windows ADK（部署工具）

重打包步骤依赖 Windows ADK"部署工具（Deployment Tools）"组件中的 `oscdimg.exe`。

1. 下载并安装（二选一）：
   - 命令行：`winget install --id Microsoft.WindowsADK`，安装界面勾选"部署工具"；
   - 浏览器：访问微软官方文档
     <https://learn.microsoft.com/windows-hardware/get-started/adk-install>，
     下载 ADK 安装器后仅勾选"部署工具"即可，其余组件可不装。
2. 脚本启动时按以下顺序自动探测 `oscdimg.exe`：
   - `C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe`；
   - 上述路径的 x86 变体与各版本号变体（递归搜索 `Windows Kits\*`）；
   - `PATH` 环境变量。
3. 探测失败时，脚本输出安装指引并以退出码 1 中止。`run-all.ps1` 会在解包之前
   先行探测，避免长时间工作后才发现缺失。

## 1.4 PowerShell 版本

- 全部脚本兼容 Windows PowerShell 5.1（Windows 11 自带），不要求 PowerShell 7。
- 执行策略：通过命令行显式附加 `-ExecutionPolicy Bypass` 运行，不修改系统全局策略。

## 1.5 网络要求

- 定制过程本身完全离线：DISM 离线服务、注册表配置单元注入、oscdimg 打包均不访问网络。
- 仅在首次安装 ADK 时需要联网下载。

## 1.6 先决条件自检清单

| 检查项 | 验证方法 | 期望结果 |
|---|---|---|
| 管理员权限 | 以管理员身份启动 PowerShell | 脚本不报权限错误 |
| 源 ISO 存在 | `Test-Path D:\Win11_Pro.iso` | `True` |
| 工作盘空间 | 资源管理器查看 | ≥ 20 GB |
| oscdimg | 运行 `run-all.ps1` 自动探测 | 输出 oscdimg 完整路径 |
| PowerShell 版本 | `$PSVersionTable.PSVersion` | ≥ 5.1 |
