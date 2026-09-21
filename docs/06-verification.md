# 第 6 章 产物验证与装机验收

验证分两个层次：**离线核查**（06-verify.ps1，构建机自动执行）与**装机验收**
（虚拟机全新安装后人工确认）。前者保证镜像内容正确，后者保证定制在真实安装
链路中生效。

## 6.1 离线核查（06-verify.ps1）

执行方式（管理员）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\06-verify.ps1
```

核查流程：

1. 挂载输出 ISO（只读），检查结构：`autounattend.xml`、`sources\install.wim`、
   `install.esd` 已删除、BIOS/UEFI 双引导文件齐备；
2. 解析 `install.wim` 版本索引（应为单一版本且名称匹配）；
3. 只读挂载 WIM，复制三个配置单元到临时目录后加载，逐项断言第 4 章全部键值；
4. 断言 6 个受保护服务（mpssvc/BFE/wscsvc/wuauserv/CryptSvc/DcomLaunch）未被禁用；
5. 断言第 5 章摘除清单在映像中全部缺席、WinSxS 完整存在；
6. 断言 `SetupComplete.cmd` 存在且包含全部兜底命令；
7. 卸载全部配置单元与映像，清理临时目录。

输出规范：每项一行 `VERIFY PASS/FAIL`，结束时输出
`ALL VERIFICATION CHECKS PASSED`（退出码 0）或失败项汇总（退出码 1）。
核查只读不改写任何内容，可反复执行。

## 6.2 装机验收（必须先在 Hyper-V 虚拟机中进行）

全新安装输出 ISO，首次进入桌面后逐项确认：

### 6.2.1 Defender 已移除

```
sc query WinDefend          # 服务不存在或已禁用
tasklist | findstr MsMpEng  # 无任何匹配行
```

### 6.2.2 BitLocker 无自动加密

```
manage-bde -status C:       # 保护已关闭，且无后台加密动作
```

### 6.2.3 防火墙三配置文件已关闭

```
netsh advfirewall show allprofiles
# 域/专用/公用三个配置文件的"状态"均为 OFF
```

### 6.2.4 虚拟化安全未启用

运行 `msinfo32`，"基于虚拟化的安全性"一项应为"未启用"。

### 6.2.5 安全中心应用缺席

开始菜单中无"Windows 安全中心"，或打开后病毒防护页不可用。

### 6.2.6 开发场景实测

1. 将包含 `.efi` / `.fd` 文件的固件构建目录复制到任意位置：无拦截、无删除告警；
2. 从内网共享与浏览器下载开发资料：无 SmartScreen 拦截提示；
3. 运行 Visual Studio Installer：可正常完成安装；
4. `wuauclt /detectnow` 或"设置 → Windows Update → 检查更新"：可正常执行
   （Windows Update 服务健康）；
5. 电源计划为"高性能"；`bcdedit` 显示 `hypervisorlaunchtype = Off`。

## 6.3 账户与首次登录

`autounattend.xml` 自动创建本地管理员账户，账户名与初始密码由 `config.ps1` 的
`$LocalAdminName`、`$LocalAdminPassword` 决定。默认配置（`dev` + 空密码）下，
首次登录无需输入密码。

> 空密码意味着任何可接触该设备者均可直接以管理员身份登录。进入系统后应立即执行
> `net user <账户名> *` 设置密码，或通过"设置 → 账户 → 登录选项"添加。
> 该镜像面向隔离开发/测试环境，不建议在不可信网络中以空密码运行。

## 6.4 验收记录

`05-repack.ps1` 在打包成功后会将验收清单同时写入控制台、
`Logs\customize.log` 与 `Logs\acceptance-checklist.txt`，可作为验收报告的
核对底稿。
