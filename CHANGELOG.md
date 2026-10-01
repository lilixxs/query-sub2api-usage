# 更新日志

本文件记录 `query-sub2api-usage` skill 的版本变更。版本号在 `SKILL.md`、`README.md`、本文件与脚本 `$script:ScriptVersion`（请求头复用此版本）中必须保持一致。

版本号遵循[语义化版本](https://semver.org/lang/zh-CN/)；条目格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)。

## [1.5.1] - 2026-10-01

### 文档

- 新增面向公开仓库的 `README.md`：用途、Windows PowerShell 5.1+ 依赖、克隆安装、空模板 `config.example.json` 复制（不覆盖已有 `config.json`）、OpenCode 发现与调用、参数表、三种输出模式、价格快照可选依赖与限制、合成输出示例、计算规则、测试命令与 MIT 许可。
- 新增 `CONTRIBUTING.md`（PowerShell 脚本 UTF-8 BOM、语义版本同步、离线测试、禁用真实凭据）与 `SECURITY.md`（禁止提交 key、真实用量、个人端点与日志；泄露后先撤销轮换，通过 GitHub 私密漏洞报告联系维护者）。
- 修正 `-RawJson` 描述：实现为直接 `ConvertTo-Json` 输出网关返回体，**未做任何脱敏**；此前文档“脱敏原始 JSON”的表述有误，1.0.0 条目已加注。
- 补充安全边界：错误正文仅按 `sk-` 前缀替换为 `<redacted>` 并截断 500 字符，非 `sk-` 格式 key 不保证脱敏，不承诺全面的秘密保护。
- 补充 `-Json` 前提：配置缺失时脚本仍会交互提示（含 `[y/N]` 保存询问），仅完整配置、无需交互时 stdout 才只有一个 JSON 对象。
- 明确“充值额度 = balance + total.actual_cost”为展示用计算值，不是财务充值流水。
- `SKILL.md` 分享与配置模板说明改为复制空模板 `config.example.json`，本机 `config.json` 不分享；顶部版本行与“版本管理”同步为 1.5.1。

### 仓库

- 版本号同步至 1.5.1：`SKILL.md`、`README.md`、本文件、脚本 `$script:ScriptVersion`（`User-Agent: query-sub2api-usage/1.5.1`），脚本逻辑不变。
- 仓库配套：MIT `LICENSE`、空 `config.example.json`、`.gitignore`（忽略 `config.json`）、离线测试 `tests/test-query-sub2api-usage.ps1`（无第三方库、合成数据）与 CI 配置。

### 验证

- 文档与脚本实现逐条核对：`-RawJson` 直接输出路径、错误正文 `sk-` 正则与 500 字符截断、`-Json` 交互提示前提、配置读取优先级与参数默认值。
- Windows PowerShell 5.1 离线测试实际执行通过：238 个断言，涵盖 AST/BOM、纯函数、合成价格快照，以及模拟 Markdown/JSON/失败路径；不读取真实配置、不调用真实网关。
- `-RawJson`、交互补全、配置持久化与带真实 HTTP 响应对象的异常分支未进行端到端验证；本次不重复真实网关查询。

## [1.5.0] - 2026-10-01

### 新增

- 模型名后新增“单价”列，读取 `/sync-openai-mm-models` skill 的价格快照；支持 `-ModelPrices` 指定路径，不自动同步模型或改动 provider 配置。
- 单价按精确模型 ID 与同网关匹配，区分公开分组已确认价、待核实价和未知价；保留价格单位、快照时间与复杂条件提示，不把倍率或官方价误当实付价。

### 变更

- 将“输入”“输出”合并为“输入/输出”，与已有“缓存读/写”格式一致。
- 单价只作参考，花费继续使用 `actual_cost`；JSON、原始 JSON 及用量计算规则不变。

### 修复

- 单价采纳要求同网关模型广场来源端点成功；其他接口的成功不能替代价格来源校验。
- 拒绝负价、非法数值和币种/单位矛盾；单位倍率及关闭的条件旗标不遮蔽基础价，混合计费维度保留条件提示。
- URL 比较保留网关路径大小写，动态 Markdown 内容转义，价格说明压缩为简短脚注。

### 验证

- PowerShell AST 解析与 UTF-8 BOM 检查通过。
- 23 个合成快照离线回归场景、Markdown 转义及 URL 规范化检查通过；其中有价场景只使用合成数据。
- 真实 Markdown 查询确认模型表七列及输入/输出合并；真实 JSON 查询确认 schema 保持 `sub2api-usage/1`，不依赖价格快照。
- 本次价格查询返回 39 个未知模型，模型广场 HTTP 404；真实数值单价无法验证，报告明确显示“未知”，不猜价。

## [1.4.0] - 2026-10-01

### 新增

- Markdown 报告首行在充值额度前展示配额模式，使用中文(英文)形式。
- 根据 Sub2API 模式语义映射 `unrestricted` 和 `quota_limited`；未知值保留原值，缺失及空白值显示“未提供”。

### 兼容性

- JSON 的 `mode` 保留原始英文，两张用量表及现有计算规则不变。

### 验证

- PowerShell AST 解析和 UTF-8 BOM 检查通过。
- 两种已知模式、未知模式、null、空字符串及纯空白值共六个映射用例通过。
- 真实查询确认配额模式位于充值额度前，JSON 仍返回原始 `unrestricted`，schema 保持 `sub2api-usage/1`。

## [1.3.0] - 2026-10-01

### 新增

- 默认文本输出改为 Markdown 用量报告：充值额度、剩余余额进度条、累计花费、今日及累计用量表、模型明细表。
- 模型表新增缓存命中率，并将缓存读取和缓存写入合并为“缓存读/写”列。

### 变更

- 充值额度按“余额 + `actual_cost`”计算，累计及模型花费统一采用 `actual_cost`。
- 表格标题和列名改为简洁中文，区块使用水平分隔线，标题紧贴表格。
- JSON 与原始 JSON 输出结构保持不变。

### 验证

- PowerShell AST 解析、Markdown 默认输出、余额进度条及汇总计算均通过验证。

## [1.2.0] - 2026-09-24

### 新增

- 引入版本管理：`SKILL.md` 顶部记录当前版本号，详细变更独立记录到本文件。
- 脚本新增 `$script:ScriptVersion`，请求头 `User-Agent` 由固定值改为 `query-sub2api-usage/<版本号>`。

### 文档

- `SKILL.md` 新增“版本管理”小节，约定版本号同步更新规则。
- 分享清单与目录结构中补充 `CHANGELOG.md`。

## [1.1.0] - 2026-09-24

### 新增

- 脚本新增显式 JSON 输出开关 `-Json`：stdout 只输出结构化 JSON 摘要，供 AI 模型/脚本解析；`-Quiet` 保留为别名，旧调用不受影响。
- JSON 摘要新增 `schema`（固定 `sub2api-usage/1`）以及 `average_duration_ms`、`rpm`、`tpm` 字段。
- `SKILL.md` 新增“JSON 输出（供 AI 模型解析）”小节与输出模式说明。

### 修复

- 脚本改为 UTF-8 带 BOM：此前无 BOM 时 Windows PowerShell 5.1 按系统 ANSI 代码页（本机 ACP=936）读取脚本，导致脚本内中文提示及持久化确认中的“是”匹配失效；默认文本输出的中文乱码问题随之消除。

### 验证

- PowerShell AST 解析通过；`-Json` 输出以 `{` 开头且可被 `ConvertFrom-Json` 解析，`schema=sub2api-usage/1`。
- `-Quiet` 别名与默认文本输出均正常；对网关的真实查询成功。

## [1.0.0] - 2026-09-24

### 新增

- 初始版本，包含 `SKILL.md`、`config.json` 与 `scripts/query-sub2api-usage.ps1`。
- 配置读取优先级：命令参数 → 环境变量 → `config.json` → 交互式补全（key 隐藏输入）。
- 支持 `GET /v1/usage` 查询：默认文本摘要，`-RawJson` 输出完整 JSON（注：原文“脱敏”表述有误，实现未做脱敏，1.5.1 已修正文档），`-Quiet` 输出结构化 JSON 摘要。
- 支持 `-SaveConfig` 持久化配置；错误信息脱敏，未经用户明确同意不写入 API key。
