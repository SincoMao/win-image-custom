# 第 3 章 流水线分步详解

流水线由五个顺序步骤（01–05）与一个编排器（run-all.ps1）组成。每一步都是独立的
PowerShell 脚本，既可由编排器串联执行，也可单独执行（单独执行时仍按顺序要求前置
步骤的产物）。本章逐步说明每个脚本的行为、判定条件与失败处理。

## 3.0 编排器：run-all.ps1

执行顺序与检查点：

1. 管理员权限自检；
2. 预探测 oscdimg.exe（缺失则在解包前直接退出，避免无效劳动）；
3. 检查源 ISO 存在；
4. 依次以子进程方式执行 01→05，任一子进程退出码非零即中止并记录日志；
5. 全部成功后输出产物路径与日志路径。

以子进程方式执行的目的是隔离每一步的运行状态：某一步内部调用 `exit` 不会误伤
编排器，编排器可以可靠地读取退出码。

## 3.1 01-extract.ps1 —— 校验与解包

**输入**：源 ISO。**输出**：`$WorkDir\ISO\` 完整副本及单版本 `install.wim`。

1. 管理员自检；源 ISO 存在性检查，并将其设为只读属性；
2. 工作盘剩余空间检查（阈值 `$MinFreeGB`，默认 20 GB）；
3. 幂等判定：若 `$WorkDir\.extract-done` 标记与 `install.wim` 同时存在，跳过解包，
   仅重新校验版本索引；
4. 否则清除旧工作副本，挂载 ISO（`Mount-DiskImage`），完整复制内容到 `$WorkDir\ISO`，
   随后卸载 ISO（复制与卸载在 try/finally 中，异常时也会卸载）；
5. 若 `sources` 下为 `install.esd`：列出全部索引并按 `$EditionName` 精确匹配
   （匹配数必须恰好为 1），执行
   `dism /export-image /sourceindex:N /destinationimagefile:install.wim /compress:max /checkintegrity`，
   成功后删除 `install.esd`；
6. 若已是 `install.wim`：直接校验版本索引；
7. 写入完成标记。

**失败行为**：任何一步失败 → 记录日志 → 卸载可能存在的挂载 → 退出码 1。

## 3.2 02-mount.ps1 —— 挂载映像

1. 确认 `install.wim` 存在；
2. 若挂载点已有映像（例如上次失败残留），先 `/discard` 卸载，保证干净基线；
3. 重新解析版本索引，`dism /mount-image /imagefile:... /index:N /mountdir:...` 挂载；
4. 通过 `Get-WindowsImage -Mounted` 复核挂载状态。

> 注意：`/mount-image` 的映像文件参数名是 `/imagefile`，而非 `/wimfile`
> （`/wimfile` 属于 `/get-wiminfo` 等查询命令）。两者混用会导致 DISM
> 返回错误 87，详见第 9 章案例一。

## 3.3 03-customize.ps1 —— 离线定制核心

**前提**：映像已挂载。这是改动最集中的一步，按以下顺序执行：

1. **加载三个离线配置单元**（reg load）：
   - `Windows\System32\config\SYSTEM` → `HKLM\CUS_SYS`
   - `Windows\System32\config\SOFTWARE` → `HKLM\CUS_SW`
   - `Users\Default\ntuser.dat` → `HKLM\CUS_DU`（默认用户配置单元）
2. **写入注册表清单**（完整清单见第 4 章）。遇到 ACL 拒绝的受保护键（典型如
   `Microsoft\Windows Defender\Features`），自动执行所有权接管与授权后重试一次
   （机制见第 9 章案例三）。
3. **卸载配置单元**（带 GC 回收与重试，确保句柄释放）。
4. **文件摘除**（完整清单见第 5 章）：逐项检查存在性，存在则先 `takeown`+`icacls`
   取得所有权再删除；不存在则记录"已缺席，跳过"。
5. **预配 AppX 移除**：仅移除 `DisplayName` 等于 `Microsoft.Windows.SecHealthUI`
   的包，其余预配包一律不动。
6. **写入 `Windows\Setup\Scripts\SetupComplete.cmd`**：安装完成后的幂等兜底
   （`bcdedit /set hypervisorlaunchtype off`、防火墙三配置文件关闭、高性能电源计划、
   8 个 Defender 服务再次 `sc config start=disabled`）。

任何失败都会先卸载配置单元再 `/discard` 卸载映像，源介质与工作副本不产生半成品。

## 3.4 04-unattend.ps1 —— 应答文件与提交

1. 在 `$WorkDir\ISO` 根目录生成 `autounattend.xml`，两种模式由 `$LocalAdminName` 决定：
   - **默认模式（`$LocalAdminName` 留空）**：应答文件仅接受 EULA，不包含任何
     oobeSystem 设置。OOBE 的区域、键盘、网络、隐私、用户名创建等页面与官方
     介质完全一致；唯一差异是镜像中已写入 `BypassNRO=1`（见第 4 章 4.2.5 节），
     安装过程不再强制联网登录微软账户，安装者可自行创建本地账户。镜像不含任何
     个人化信息，可批量部署。
   - **无人值守模式（`$LocalAdminName` 设置了用户名）**：跳过 EULA/OEM 注册/
     联网账户/无线网络页面，`ProtectYourPC=0`，并自动创建该本地管理员账户
     （生成前做用户名合法性校验与 XML 转义）。
   - 两种模式均不包含任何产品密钥与激活相关内容（红线）。
2. XML 生成后立即做格式合法性校验（`[xml]` 解析），不合法则不提交。
3. `dism /unmount-image /commit /checkintegrity` 提交并卸载映像。
   全程不存在 `/startcomponentcleanup` 与 `/resetbase`（红线）。

> 无人值守模式下密码留空意味着首次登录无需输入密码，装机后应立即通过
> `net user <账户名> *` 或"设置 → 账户 → 登录选项"设置密码。

## 3.5 05-repack.ps1 —— 双启动重打包

1. 探测 oscdimg.exe；确认无残留挂载；确认 `install.wim` 存在；
2. 校验引导文件：`boot\etfsboot.com`（BIOS）与
   `efi\microsoft\boot\efisys_noprompt.bin`（UEFI，免提示；缺失时回退
   `efisys.bin` 并告警）；
3. 删除旧产物（幂等重跑），执行规格化打包命令：

   ```
   oscdimg -m -o -u2 -udfver102 -bootdata:2#p0,e,b"<ISO>\boot\etfsboot.com"#pEF,e,b"<ISO>\efi\microsoft\boot\efisys_noprompt.bin" "<ISO>" "<OutputIso>"
   ```

   该命令构造 BIOS+UEFI 双启动项（`-bootdata:2`），`-m` 突破单文件 4 GB 限制，
   `-u2 -udfver102` 设定 UDF 版本，`-o` 优化重复文件存储。
4. 校验退出码与产物存在性，输出产物大小、验收清单（控制台 + 日志 +
   `Logs\acceptance-checklist.txt`）。

## 3.6 06-verify.ps1 —— 产物离线核查

核查脚本不参与构建，可在任何时刻对 `$OutputIso` 独立执行：

1. 挂载输出 ISO，检查结构与 `autounattend.xml` 内容；
2. 只读挂载其中的 `install.wim`，将三个配置单元复制到临时目录后 reg load；
3. 逐项断言：8 个服务 Start=4、6 个受保护服务未被禁用、BitLocker/DeviceGuard/
   LabConfig/SmartScreen/防火墙/遥测/OOBE/AppHost 全部键值、文件摘除清单全部缺席、
   WinSxS 存在、SetupComplete.cmd 内容完整；
4. 卸载全部配置单元与映像（只读挂载以 `/discard` 卸载），清理临时目录；
5. 汇总输出 `ALL VERIFICATION CHECKS PASSED` 或失败项明细，退出码对应 0/1。

## 3.7 时序总览

```
run-all.ps1
 ├─ 01-extract     校验 → 复制 → ESD→WIM       (~5–10 分钟)
 ├─ 02-mount       挂载 install.wim             (~1 分钟)
 ├─ 03-customize   注册表 → 摘除 → AppX → 兜底  (~1–2 分钟)
 ├─ 04-unattend    autounattend.xml → 提交卸载  (~2–5 分钟)
 └─ 05-repack      oscdimg 重打包               (~1–3 分钟)
06-verify           离线核查（独立执行）          (~2 分钟)
```

总耗时通常 10–20 分钟，主要取决于磁盘速度。
