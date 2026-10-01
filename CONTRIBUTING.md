# 贡献指南

欢迎通过 Issue 讨论问题、通过 Pull Request 提交修改。请先阅读 [README.md](./README.md) 与 [SECURITY.md](./SECURITY.md)；不要在 Issue、PR、测试或截图中附带真实密钥和个人用量数据。

## 本地开发

- 使用 Windows PowerShell 5.1。用量脚本及测试不依赖 Python、Node.js、Pester 或其他第三方库。
- 代码标识使用英文，注释使用中文。
- 所有 `.ps1` 文件保持 **UTF-8 带 BOM**；Windows PowerShell 5.1 会把无 BOM 文件按系统 ANSI 代码页读取，中文可能乱码。
- `.gitattributes` 规定 PowerShell 文件检出为 CRLF，Markdown、JSON、YAML 使用 LF；不要删除 BOM。
- `config.json` 是被忽略的本机私有配置，公开库只包含 `config.example.json` 空模板。自定义配置文件也必须排除在 Git 外。

## 验证

在仓库根目录运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ./tests/test-query-sub2api-usage.ps1
git diff --check
```

测试只使用合成数据，不触网、不读取本机配置、不使用真实凭据。测试非零退出表示失败。GitHub Actions 使用 Windows PowerShell 执行离线测试，并检查版本一致性及公开模板；以实际运行结果为准。

不要直接 dot-source 主脚本做单元测试：其顶层会读取配置并调用网关。函数测试应通过 PowerShell AST 提取函数声明，端到端测试必须完全模拟配置和网络响应。

## 版本与变更

遵循 SemVer：修复提升修订号，新增功能提升次版本号，破坏性变更提升主版本号。同步维护：

1. `SKILL.md` 顶部与“版本管理”中的版本号。
2. `README.md` 顶部版本号。
3. `CHANGELOG.md` 对应版本、日期、具体变化及已实际执行的验证。
4. `scripts/query-sub2api-usage.ps1` 中 `$script:ScriptVersion`（请求头自动复用）。

提交前检查 `git status --short --ignored` 和暂存差异，确认没有密钥、真实端点、用量报告、价格快照、日志或临时截图。新增测试应覆盖异常输入和边界条件，不以修改预期结果掩盖缺陷。

贡献按本项目 [MIT 许可证](./LICENSE) 分发。

## 自动发布

推送到 `main` 后，本次 CI 成功才启动自动发布；每个新增 commit 对应一个 `commit-<完整 SHA>` Release，多 commit 推送按历史顺序逐个创建。其他分支、PR、手动 CI 不发布；已存在的 Release 跳过，失败后可重跑原 Actions。只在发布 job 授予 `contents: write`，使用 GitHub 提供的临时 `GITHUB_TOKEN`，无需另设 PAT 或仓库 Secret。

不要改写 `main` 历史或删除已有 commit 标签。自动 Release 不替代 SemVer：修改仍按上面的规则同步项目版本和更新日志；发布前检查整个提交范围不含私有文件。
