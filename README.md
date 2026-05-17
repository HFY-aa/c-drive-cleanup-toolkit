# C盘安全清理与迁移工具包

这是一个可直接分发的 Windows 工具包，不需要安装 AI，也不需要先安装成 skill 才能使用。

## 运行命令

在本目录打开 PowerShell，执行：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Invoke-SafeCDriveCleanup.ps1
```

## 它默认会做什么

- 自动清理安全缓存和临时文件
- 自动跳过正在占用或无权限删除的文件
- 清理完成后扫描仍放在 `C:` 的大目录
- 如果发现 `桌面 / 下载 / 文档 / 图片 / 视频 / 微信 / QQ` 数据仍在 `C:`，会先汇总，再一次性询问是否迁移到 `D:`

## 当前工作流程

1. 先读取 `C:` 当前可用空间。
2. 自动清理安全范围内的内容：
   - 用户临时文件
   - Windows 临时目录
   - Windows 更新下载缓存
   - 回收站
   - Chrome / Edge / Firefox / WPS / 百度网盘等常见缓存目录
3. 自动跳过被占用、无权限或不存在的路径，不会因为个别文件失败就中断整轮流程。
4. 自动扫描仍位于 `C:` 的大目录，重点关注：
   - `桌面`
   - `下载`
   - `文档`
   - `图片`
   - `视频`
   - `WeChat Files / Weixin Files / Tencent Files`
5. 把这些候选目录汇总成一张表，统一问你一次：是否迁移到 `D:`。
6. 如果你确认：
   - `桌面 / 下载 / 文档 / 图片 / 视频` 会迁移到 `D:\UserFolders\...`
   - `微信 / QQ` 这类目录会迁移到 `D:\AppDataRelocated\...`
   - 对微信 / QQ 类目录，会尽量保留原路径连接点，降低软件失效风险
7. 最后输出：
   - 清理前后 `C:` 可用空间
   - 每类清理结果
   - 迁移结果
   - 被占用或建议稍后重试的项目

## 推荐运行方式

- 最推荐：管理员 PowerShell 运行
- 如果只想先预览，不真正删除：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Invoke-SafeCDriveCleanup.ps1 -DryRun
```

## 安全边界

- 默认不碰个人文档内容
- 默认不删系统关键目录
- 默认不改路径，除非你确认迁移到 `D:`
- 微信和 QQ 这类目录迁移时，会优先使用“迁移到 `D:` + 原路径保留连接点”的方式，尽量不影响软件继续使用

## 转给别人时可以这样说

“管理员打开 PowerShell，进入这个文件夹，运行 `./scripts/Invoke-SafeCDriveCleanup.ps1`。它会先自动清理安全缓存，再统一询问一次要不要把仍在 C 盘的大目录迁到 D 盘。”
