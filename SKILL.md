---
name: safe-c-drive-cleanup
description: 当用户需要安全、低交互地清理 Windows C 盘，并在必要时把仍位于 C 盘的大型用户目录或聊天数据迁移到 D 盘时使用。默认只清理经过筛选的临时文件、缓存和更新缓存；对于桌面、下载、文档、图片、视频、微信、QQ 等目录，会先汇总再统一询问是否迁移。
---

# C盘安全清理与迁移工具包

当用户希望在 Windows 上安全清理 `C:`，同时尽量减少后续再次占满的风险时，使用这个工具包。

## 这个工具包会做什么

1. 自动清理一批常规安全目标：
   - 用户临时文件
   - Windows 临时目录
   - Windows 更新下载缓存
   - 回收站
   - 常见浏览器与应用缓存目录
2. 对被占用文件自动跳过，不强行删除。
3. 扫描仍位于 `C:` 的大型用户目录。
4. 在真正迁移前，只统一询问一次是否把支持的目录迁移到 `D:`。
5. 迁移时使用更稳妥的方法：
   - `桌面`、`下载`、`文档`、`图片`、`视频`：迁移并更新 Windows 路径
   - `WeChat Files`、`Weixin Files`、`Tencent Files`：迁移到 `D:` 后在原位置保留连接点，尽量不影响软件继续使用

## 安全边界

- 不删除个人文档、项目源码、安装包或未知目录。
- 不删除 `WinSxS`、`System32`、`Prefetch`、分页文件、休眠文件等系统关键内容。
- 不在未确认前迁移任何用户目录。
- 对聊天软件数据优先采用“迁移到 D 盘 + 原路径保留连接点”的方式。
- 如果软件仍在运行导致目录被占用，则跳过并在最后提示用户稍后重试。

## 如何运行

在工具包目录中打开 PowerShell，执行：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Invoke-SafeCDriveCleanup.ps1
```

常用变体：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Invoke-SafeCDriveCleanup.ps1 -DryRun
powershell -ExecutionPolicy Bypass -File .\scripts\Invoke-SafeCDriveCleanup.ps1 -SkipRelocationPrompts
powershell -ExecutionPolicy Bypass -File .\scripts\Invoke-SafeCDriveCleanup.ps1 -UseComponentStoreCleanup
```

## 推荐使用流程

1. 建议以管理员 PowerShell 运行，以获得更完整的清理效果。
2. 先运行 `scripts/Invoke-SafeCDriveCleanup.ps1`。
3. 让脚本先完成自动安全清理。
4. 查看脚本汇总出的迁移计划。
5. 如果确实要进一步压缩 `C:` 占用，再一次性确认是否迁移到 `D:`。
6. 最后查看清理结果、迁移结果和未完成项。

## 附带文件

- `scripts/Invoke-SafeCDriveCleanup.ps1`：主脚本
- `使用说明.md`：给普通用户看的简洁说明
