---
name: query-sub2api-usage
description: 查询 Sub2API/OpenAI-compatible 网关 API key 的余额、配额模式、今日用量和模型用量；当用户说查询 sub2api 用量、余额、配额、API key usage 或 gateway quota 时使用。
---

# 查询 Sub2API 用量

当前版本：**1.5.1**（2026-10-01）｜更新记录见同目录 [`CHANGELOG.md`](./CHANGELOG.md)

使用本 skill 查询网关的 `GET /v1/usage`。用量脚本只使用 Windows PowerShell 内置命令，不依赖 Python、Node.js、npm 或第三方模块；价格查询独立复用 `/sync-openai-mm-models` skill 的 Python 脚本，不触发模型同步。

## 启动配置检查

默认配置文件：

```text
~/.config/opencode/skills/query-sub2api-usage/config.json
```

公开库提供 `config.example.json` 空模板，其中 `base_url` 与 `api_key` 都为空。需要配置文件时，将模板复制为 `config.json`，不要覆盖已有配置；文件缺失时脚本同样从空值开始。本机 `config.json` 不纳入 Git，不得分享。启动时按以下优先级读取：

1. 命令参数 `-BaseUrl` / `-ApiKey`
2. 环境变量 `SUB2API_BASE_URL` / `SUB2API_API_KEY`
3. `config.json` 中的 `base_url` / `api_key`
4. 交互式提问补全缺失值

如果端点或 key 为空，必须先通过 `question` 工具向用户询问缺失配置，并增加“是否将当前配置写入配置文件（写入即永久配置）”选项；也可以直接执行脚本，让脚本用 `Read-Host` 逐项提示。不得编造默认端点，不得输出或复述用户输入的 API key。只有用户明确选择写入时，才可持久化当前配置。

问答提示建议：

- 缺少端点：`请输入 Sub2API API 根地址，例如 https://example.com`
- 缺少 key：`请输入 Sub2API API key；输入内容用于本次查询，稍后可选择是否永久保存`
- 持久化选择：`是否将当前配置写入配置文件？写入后将作为永久配置（包含 API key）`
  - `不写入（仅本次使用）`：默认选项
  - `写入（永久配置）`：将当前配置保存到 `config.json`

用户选择“写入”时，调用脚本并添加 `-SaveConfig`；选择“不写入”时不要添加该参数。脚本在直接交互运行且补全过配置时，也会以 `[y/N]` 方式询问是否永久保存，默认不保存。保存内容包括当前生效的 `base_url`、`api_key` 和 `usage_path`。

脚本会自动规范端点：传入 `https://example.com/v1` 时查询 `/v1/usage`；传入 `https://example.com` 时也会自动补 `/v1/usage`。如需其他路径可使用 `-UsagePath`。

## 使用方法

### 直接运行

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$HOME/.config/opencode/skills/query-sub2api-usage/scripts/query-sub2api-usage.ps1"
```

### 使用一次性参数

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$HOME/.config/opencode/skills/query-sub2api-usage/scripts/query-sub2api-usage.ps1" `
  -BaseUrl "https://your-sub2api.example.com/v1" `
  -ApiKey $env:SUB2API_API_KEY
```

### 写入永久配置

仅在用户明确同意后使用：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$HOME/.config/opencode/skills/query-sub2api-usage/scripts/query-sub2api-usage.ps1" `
  -BaseUrl "https://your-sub2api.example.com/v1" `
  -ApiKey $env:SUB2API_API_KEY `
  -SaveConfig
```

`-SaveConfig` 会把当前生效配置（包括 API key）写入 `config.json`。未指定该参数时，命令参数和环境变量不会被自动持久化。

### 使用环境变量

```powershell
$env:SUB2API_BASE_URL = "https://your-sub2api.example.com/v1"
$env:SUB2API_API_KEY = "<your-key>"
```

### JSON 输出（供 AI 模型解析）

默认输出文本；需要机器可读结果时加 `-Json`。完整提供端点与 key、无需交互时，stdout 只输出一个 JSON 对象，不混入其他提示文本：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$HOME/.config/opencode/skills/query-sub2api-usage/scripts/query-sub2api-usage.ps1" -Json
```

AI 模型/agent 查询时应显式添加 `-Json` 并按其解析；字段包括 `schema`（固定 `sub2api-usage/1`）、`valid`、`balance`、`remaining`、`unit`、`mode`、`average_duration_ms`、`rpm`、`tpm`、`today`、`total`、`model_stats`，不含 API key。`-Quiet` 仍兼容，作为 `-Json` 的别名。

配置缺失时，`-Json` 仍会触发交互补全和是否保存的询问，可能阻塞非交互自动化。agent 必须先检查缺失值并通过问答补齐，不能把 `-Json` 当作禁用交互的开关。

输出模式：

- 默认（Markdown，面向人类）：按下方“最终输出格式”展示配额模式、充值额度、余额进度条、累计花费、今日及累计用量，以及各模型累计用量与花费。
- `-Json`：结构化 JSON 摘要（见上）。
- `-RawJson`：网关原始返回直接转 JSON 输出，**未做任何脱敏**。分享前必须检查敏感字段。

请求失败时，错误正文中的 `sk-` 前缀片段会被替换并截断至 500 字符；非 `sk-` 格式的 key 及其他敏感字段不保证被移除。无 HTTP 状态时输出异常消息，不能承诺错误输出全面脱敏。

### 模型单价查询

模型表在模型名后新增“单价”列；将原“输入”“输出”合并为“输入/输出”列，值为 `<input_tokens> / <output_tokens>`。

AI 模型/agent 生成完整报告前，应加载 `/sync-openai-mm-models` skill，按其价格查询流程刷新快照，不执行模型同步、不修改 provider 配置。务必使用与本次用量查询相同的 API 根地址，按模型 ID 精确匹配，不用类似模型或官方价替代。

```powershell
& 'C:\ProgramData\miniforge3\shell\condabin\conda-hook.ps1'
conda activate vibe-coding
if (-not $?) { throw 'Could not activate vibe-coding' }
$env:PYTHONDONTWRITEBYTECODE = '1'
# effectiveBaseUrl 是本次用量查询实际生效的根地址；不得把 API key 放入参数。
python "$HOME/.config/opencode/skills/sync-openai-mm-models/scripts/query-model-prices.py" --base-url $effectiveBaseUrl --filter all
```

默认快照位置为 `~/.config/opencode/skills/sync-openai-mm-models/data/model-prices.json`。Markdown 用量脚本只读取已有快照，不自动刷新；可通过 `-ModelPrices <快照路径>` 指定其他快照。`-Json`、`-RawJson` 不读取价格快照，原始用量输出结构保持兼容。价格 skill 不可用时仍输出用量报告，单价显示“未知”。

价格展示规则：

- 先核对快照 `schema_version`、`generated_at`、`base_url`、接口 HTTP 状态和逐模型状态。网关不匹配、快照缺失或无效时不采纳单价；`model-plaza` 来源必须对应同网关的模型广场端点成功响应，其他接口成功不能替代价格来源成功。
- `confirmed` 只表示已核实单位的公开分组价，不能宣称是当前 Key 的实付价。`unverified` 显示“待核实”，`unknown` 或未匹配模型显示“未知”；空价格数组不是免费。
- 简单 Token 单价使用“输入 / 输出”顺序；原单位 `USD/token` 乘 1,000,000 后展示为 USD/百万 Token。按次单价显示 USD/次，不乘百万。只接受明确返回的合法数字，显式零价可展示，缺失价格不得补零。
- 单价不套用花费的两位小数规则：保留有效小数，极小非零值可用科学计数法，避免误显示为免费。
- 多分组或复杂条件价不得任选一组、合并量纲或静默省略条件；表格可显示“多分组价（见快照）”或“条件价（见快照）”，并提供快照路径以保留分组、长上下文、推理倍率及分时等条件。显式数值倍率 `1` 不改变基础价；非单位倍率或无法核实的倍率保守提示条件价。禁止将计费倍率当单价或自行与公开价混乘。
- 表格后补充价格快照 UTC 时间以及本次用量模型中的已确认、待核实、未知数量。使用旧快照须注明其时间，不称为本次实时价；刷新失败但旧文件仍在时，不当作刷新成功。
- 单价仅作参考，不重算已有 `actual_cost` 花费。“合计”的单价显示 `—`，不得汇总模型单价。动态单元格内容必须转义竖线及换行，避免破坏 Markdown 表格。

### 最终输出格式

AI 模型/agent 使用 `-Json` 查询后，必须按以下规则回复，不得改回旧版文本摘要：

- 首行在充值额度前展示“配额模式”，采用中文(英文)格式：`unrestricted` → `无 Key 级限制(unrestricted)`；`quota_limited` → `Key 限额/限速(quota_limited)`。未知非空值显示 `未知模式(原值)`，空值、缺失值及纯空白值显示 `未提供`。
- 模式语义依据 [Sub2API /v1/usage 实现](https://github.com/Wei-Shaw/sub2api/blob/main/backend/internal/handler/gateway_handler.go)：`quota_limited` 表示 API Key 配有总额度或速率限制；`unrestricted` 表示没有 Key 级限制，不代表无限余额，仍受钱包余额或订阅额度约束。中文映射只影响人类可读报告，JSON 的 `mode` 保持原始英文。
- `充值额度 = balance + total.actual_cost`。
- “充值额度”仅为当前余额与累计花费推算的展示值，不是财务充值流水，不能用作对账依据。
- `累计花费 = total.actual_cost`；模型花费同样使用各模型的 `actual_cost`。
- 只在“剩余余额”行显示 20 格等宽 Markdown 行内代码进度条；已填充格数按 `balance / 充值额度` 四舍五入，百分比保留两位小数。
- 充值额度和累计花费仅用文本显示，不使用图标或进度条。
- 两个表格的标题和列名使用简洁中文；标题紧贴表格，标题前用水平分隔线与上一内容区隔。
- 数量使用 `K`、`M`、`B` 紧凑表示；金额摘要保留四位小数，表格金额保留两位小数。
- 模型表列顺序固定为：模型、单价、输入/输出、缓存读/写、总量、命中率（%）、花费。单价使用上方独立价格查询结果，不从累计花费反推单价。
- “缓存读/写”合并为一列，格式为 `<cache_read_tokens> / <cache_creation_tokens>`。
- `缓存命中率 = cache_read_tokens / (input_tokens + cache_read_tokens) × 100%`，保留两位小数；分母为零时显示 `0.00`。
- 模型明细按 `actual_cost` 从高到低排列。
- “合计”行必须从总计字段计算，不得将已经舍入的展示值相加。

```markdown
配额模式：无 Key 级限制(unrestricted)
充值额度：$96.5949 USD
剩余余额：$9.9441 USD · `██░░░░░░░░░░░░░░░░░░` **10.29%**
累计花费：$86.6508 USD

---

**今日及累计用量**
| 时段 | 请求 | 用量 | 花费（USD） |
|---|---:|---:|---:|
| 今日 | 0 | 0 | $0.00 |
| 累计 | **348** | **47.3M** | **$86.65** |

---

**各模型累计用量与花费**
| 模型 | 单价 | 输入/输出 | 缓存读/写 | 总量 | 命中率（%） | 花费（USD） |
|---|---:|---:|---:|---:|---:|---:|
| gpt-6-astra | 未知 | 3.8M / 144K | 10.5M / 0 | 14.4M | 73.42 | $75.16 |
| **合计** | — | **8.8M / 315K** | **38.1M / 0** | **47.3M** | **81.21** | **$86.65** |

价格快照：<快照 UTC 时间>（UTC，非实时）；本表已确认 0、待核实 0、未知 1。
单价：输入/输出，USD/百万 Token；按次价为 USD/次。仅为公开分组价，不代表当前 Key 实付价；花费仍采用 actual_cost。
```

示例中的数值仅说明排版；实际回复必须使用本次查询结果。缓存命中率按 Token 计算。

## 安全约束

- 未经用户明确同意，不把 key 写入 skill、脚本、配置文件、命令文件或分享包。
- 用户选择永久配置后，`config.json` 会以明文保存 key；应限制文件访问并避免同步、提交或分享该文件。
- 不把 key 放入 URL 查询参数。
- 不在报告中打印 `Authorization` 请求头。
- 不把配置文件提交到仓库；分享前只分享空配置模板。
- 使用完成后建议删除当前 PowerShell 会话中的 `SUB2API_API_KEY` 环境变量。

## 分享方法

分享整个目录：

```text
query-sub2api-usage/
├─ SKILL.md
├─ README.md
├─ CHANGELOG.md
├─ config.example.json
└─ scripts/
   └─ query-sub2api-usage.ps1
```

分享包只包含空配置模板，不包含本机 `config.json`、终端截图、命令历史、报告或日志。接收方将目录复制到：

```text
~/.config/opencode/skills/query-sub2api-usage/
```

然后退出并重启 opencode，使 skill 被重新扫描。使用时说“查询 Sub2API 用量”；若配置为空，按问答提示提供端点和 key。需要文件配置时先复制 `config.example.json` 为 `config.json`，不要覆盖已有配置。分享源码时保留 `LICENSE`，无需打包其他本机配置。

脚本文件必须保持 UTF-8 带 BOM：Windows PowerShell 5.1 对无 BOM 的脚本按系统 ANSI 代码页读取，会导致脚本内中文提示乱码。

## 版本管理

- 当前版本：`1.5.1`；脚本内 `$script:ScriptVersion` 与请求头 `User-Agent` 使用同一版本号。
- 版本号遵循语义化版本（SemVer）：新增功能提升次版本号，修复提升修订号，破坏性变更提升主版本号。
- 任何改动都应同步更新：本文件顶部和版本管理版本行、`README.md` 顶部版本行、[`CHANGELOG.md`](./CHANGELOG.md) 对应条目、脚本 `$script:ScriptVersion`。
- `CHANGELOG.md` 记录每个版本的日期与具体变更，格式参考 Keep a Changelog。
