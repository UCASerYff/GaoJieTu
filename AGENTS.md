# 搞截图

- 用户2026-10-18偏好：默认不执行冒烟测试，不自动启动应用、浏览器或测试窗口。按改动需要可运行静态检查、编译及针对性单元测试。实际捕获、收音、系统授权与语言包下载由用户本人明确操作；报告须区分代码检查、用户反馈和实际输出证据。

- 仅本目录与 /Applications/搞截图.app。Bundle ID com.gaoseries.GaoJieTu，初次 V1.00/build1，正式交付后每次 +0.01/build+1；同次未交付修复不增号。
- 原生 SwiftUI/AppKit，macOS14+ Apple Silicon；SCK 麦克风伴录/组合与本机翻译需 macOS15+，独立麦克风录音 macOS14+。没有真实 Developer ID 时本地签名并明确未公证。
- 真实资料 ~/Library/Application Support/GaoSeries/GaoJieTu，备份同级 GaoJieTu-Backups，钥匙串不迁移、不重置。首次不采集、不监听剪贴板、不保存历史。
- Settings.json/History.json/Exchange 是版本化资料。损坏、过新、附件缺失、摘要冲突停止写入，不能空白覆盖。
- Scripts/test.sh、build.sh、package.sh、install.sh 可复现。安装前完整备份、摘要核对、恢复演练；验证前保留旧程序，失败 rollback。仅按本App bundleID 精确登记和清理。
- 测试只用自建样本与隔离目录。TestResults、用户资料、备份、屏幕/声音实录不得进入 Git 或发行包。
- GitHub UCASerYff/GaoJieTu 独立发布；只发布审核源码、原创资源、程序、源码包与 SHA256。无权或能力边界如实记录，不冒称完成。
- GUI/权限/前台验收须与搞操作2、搞机灵协调；不得修改兄弟项目或卸载竞品。系统安全授权由用户本人确认。

## 唯一搜索入口（用户 2026-10-21 要求，2026-10-25 再次强调）

- 必须同时遵守上级 `/Users/yufeifan/Desktop/搞app/AGENTS.md` 的搜索结果与安装入口唯一性规则；本项是交付必检项。用户再次报告多个“搞截图”时，重新查明当时每条结果的真实来源，不复用历史通过结论。
- 唯一正式入口为 `/Applications/搞截图.app`，Bundle ID `com.gaoseries.GaoJieTu`。收尾检查 Spotlight 与 LaunchServices，不能让 `.build/搞截图.app`、旧安装副本、备份中的 `Previous.app` / `PreviousInstalled.app` 或挂载镜像产生第二个“搞截图”。
- 构建、安装暂存与展开核验必须从生成 `.app` 前就使用不索引的位置；不得在可索引目录留下可被再次登记的展开副本。
- 程序包与安装字节核验完成后清除展开的构建 App；GUI 验收暂缓不作为保留重复入口的理由。保留最新版发行包、源码、用户资料、验收证据与完整安全备份。
- 本应用回滚备份使用不索引容器或验证过的压缩归档；现有 `Backup-*` 目录变更必须先核对 `Scripts/backup.py`、`install.sh`、`rollback.sh` 与 `TestResults/LatestInstallationBackup.txt`，再校验全部备份内容及恢复可用性，不能直接改变旧 `.app` 的结构。
- 仅精确注销本 Bundle ID 的非正式路径，并复核只有正式路径保留；不使用全局清空登记/索引命令，不更改其他应用或用户系统隐私授权。
- 记录本次检查时间、实际副本及搜索/登记的清理前后路径。实际用户会话的查询必须有效返回正式安装路径；空结果或查询失败不能判定通过。尚有重复项或无法核验时，安装清理和交付保持未完成，不能以跳过验收结束收尾。
- 仅修改本规则或其他文档时，不修改应用版本号、不重建或重新签名程序；若同步 GitHub，只更新文档提交，已发布程序仍对应其原始版本标签与源码提交。
