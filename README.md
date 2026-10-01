# query-sub2api-usage

当前版本：**1.5.3**（2026-10-01）｜更新记录见 [CHANGELOG.md](./CHANGELOG.md)

查询 Sub2API / OpenAI-compatible 网关 API key 用量的 OpenCode skill：通过 `GET /v1/usage` 返回余额、配额模式、今日与累计用量、逐模型用量与花费，并可选显示模型单价。

核心脚本 `scripts/query-sub2api-usage.ps1` 只使用 Windows PowerShell 内置命令，不依赖 Python、Node.js、npm 或第三方模块。

仓库：https://github.com/lilixxs/query-sub2api-usage

## 功能

- 余额、配额模式（`unrestricted` / `quota_limited`）、今日及累计用量、模型明细。
- 三种输出：Markdown 报告（默认）、结构化 JSON（`-Json`，别名 `-Quiet`）、网关原始 JSON（`-RawJson`）。
- 配置读取优先级：命令参数 → 环境变量 → `config.json` → 交互式补全（key 隐藏输入）。
- 可选读取价格快照，为 Markdown 模型表增加“单价”列；不影响 `-Json` / `-RawJson` 输出。

## 环境要求

- Windows PowerShell 5.1+（仅内置命令；PowerShell 7 及其他平台未经验证）。
- 可访问网关端点的网络连接。
- 可选，仅刷新价格快照时：`/sync-openai-mm-models` skill 及其 Python 环境；用量查询本身不需要。

## 安装

克隆到 OpenCode skills 目录：

```powershell
git clone https://github.com/lilixxs/query-sub2api-usage.git "$HOME/.config/opencode/skills/query-sub2api-usage"
```

目录结构：

```text
query-sub2api-usage/
├─ SKILL.md                          # OpenCode skill 定义（frontmatter + 调用规范）
├─ README.md
├─ CHANGELOG.md
├─ CONTRIBUTING.md
├─ CONTRIBUTORS.md                   # 维护者与 AI 开发协助署名
├─ SECURITY.md
├─ LICENSE                           # MIT
├─ config.example.json               # 空模板：base_url / api_key 为空，usage_path=/v1/usage
├─ scripts/
│  └─ query-sub2api-usage.ps1
└─ tests/
   └─ test-query-sub2api-usage.ps1
```

## 配置

配置文件默认位置：`~/.config/opencode/skills/query-sub2api-usage/config.json`。

| 字段 | 模板默认值 | 说明 |
|---|---|---|
| `base_url` | 空 | 网关 API 根地址，例如 `https://example.com` 或 `https://example.com/v1` |
| `api_key` | 空 | API key（明文保存，勿提交、勿分享） |
| `usage_path` | `/v1/usage` | 用量接口路径，可用 `-UsagePath` 覆盖 |

### 复制模板（不覆盖已有配置）

```powershell
$skillDir = "$HOME/.config/opencode/skills/query-sub2api-usage"
if (-not (Test-Path -LiteralPath "$skillDir/config.json")) {
    Copy-Item -LiteralPath "$skillDir/config.example.json" -Destination "$skillDir/config.json"
    Write-Output "已从模板创建 config.json"
} else {
    Write-Output "config.json 已存在，本次不覆盖"
}
```

也可以不复制：直接运行脚本，缺失的端点和 key 会以交互方式提示（key 走隐藏输入），并以 `[y/N]` 询问是否永久保存（默认不保存）。

### 读取优先级

1. 命令参数 `-BaseUrl` / `-ApiKey`
2. 环境变量 `SUB2API_BASE_URL` / `SUB2API_API_KEY`
3. `config.json` 中的 `base_url` / `api_key`
4. 交互式提示补全

`usage_path` 只从 `-UsagePath` 与 `config.json` 读取（无对应环境变量），缺省为 `/v1/usage`。端点自动规范化：`https://example.com/v1` 查询 `/v1/usage` 时不会拼成 `/v1/v1/usage`。

## OpenCode 中的发现与调用

- OpenCode 扫描 `~/.config/opencode/skills/` 下各目录的 `SKILL.md`；frontmatter 的 `name: query-sub2api-usage` 与 `description` 决定何时被选中。
- 新增或更新 skill 后需退出并重启 opencode 重新扫描。
- 自然语言触发示例：“查询 sub2api 用量”“查一下这个 key 的余额”“gateway quota 查询”。
- 配置为空时，skill 会先向用户询问端点和 key，并提供“是否写入配置文件（写入即永久配置）”选项；未经用户明确同意不持久化。

## 命令行用法

### 参数表

| 参数 | 类型 | 默认值 | 说明 |
|---|---|---|---|
| `-Config` | string | `~/.config/opencode/skills/query-sub2api-usage/config.json` | 配置文件路径 |
| `-BaseUrl` | string | 空 | API 根地址，优先级最高 |
| `-ApiKey` | string | 空 | API key，优先级最高 |
| `-UsagePath` | string | 配置中的 `usage_path`，否则 `/v1/usage` | 用量接口路径 |
| `-ModelPrices` | string | `~/.config/opencode/skills/sync-openai-mm-models/data/model-prices.json` | 价格快照路径（仅 Markdown 模式读取） |
| `-SaveConfig` | 开关 | 关 | 将当前生效的 `base_url`、`api_key`、`usage_path` 写入配置文件 |
| `-RawJson` | 开关 | 关 | 直接输出网关原始 JSON（**未脱敏**，见下） |
| `-Json` | 开关 | 关 | stdout 只输出一个 JSON 摘要对象；`-Quiet` 为其别名 |

### 直接运行

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$HOME/.config/opencode/skills/query-sub2api-usage/scripts/query-sub2api-usage.ps1"
```

### 临时环境变量（key 不以明文出现在命令历史）

未配置 key 时，脚本本身用隐藏输入提示（`Read-Host -AsSecureString`），且不落盘（除非确认保存）。若想预先注入 key，用一次性环境变量，避免把 key 写成命令行字面量而进入 PSReadLine 历史：

```powershell
$secure = Read-Host 'Sub2API API key' -AsSecureString   # 输入不回显
$pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
try {
    $env:SUB2API_BASE_URL = 'https://example.com'       # 替换为实际端点
    $env:SUB2API_API_KEY = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    powershell -NoProfile -ExecutionPolicy Bypass -File "$HOME/.config/opencode/skills/query-sub2api-usage/scripts/query-sub2api-usage.ps1" -Json
} finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
    $secure.Dispose()
    Remove-Item -Path Env:\SUB2API_API_KEY, Env:\SUB2API_BASE_URL -ErrorAction SilentlyContinue
}
```

### JSON 输出

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$HOME/.config/opencode/skills/query-sub2api-usage/scripts/query-sub2api-usage.ps1" -Json
```

字段：`schema`（固定 `sub2api-usage/1`）、`valid`、`balance`、`remaining`、`unit`、`mode`、`average_duration_ms`、`rpm`、`tpm`、`today`、`total`、`model_stats`；不含 API key。

**完整配置前提**：仅当端点与 key 已由参数、环境变量或配置文件提供、脚本无需交互时，`-Json` 的 stdout 才是一个 JSON 对象。配置缺失时脚本仍会交互提示（包括是否保存配置的 `[y/N]` 询问），会阻塞自动化或污染 stdout；交互式调用场景请预先补齐配置。

### 原始 JSON（-RawJson）

`-RawJson` 把网关返回体直接 `ConvertTo-Json` 输出，**不做任何脱敏**。仅在请求失败时对错误正文做 `sk-` 前缀片段替换（`sk-...` → `<redacted>`）并截断至 500 字符；非 `sk-` 格式的 key 及其他秘密不保证被移除。本项目不承诺全面的秘密保护，分享输出前请自行检查，详见 [SECURITY.md](./SECURITY.md)。

## 价格快照（可选）

- Markdown 模式只读取已有快照文件，不自动刷新、不触发模型同步、不改动 provider 配置；`-Json`、`-RawJson` 不读取快照。
- 默认快照为 `~/.config/opencode/skills/sync-openai-mm-models/data/model-prices.json`，可用 `-ModelPrices` 指定其他路径。
- 刷新快照需按 `/sync-openai-mm-models` skill 的价格查询流程执行（需要 Python 环境），且必须使用与本次用量查询相同的网关地址、按模型 ID 精确匹配。
- 快照缺失、解析失败、`schema_version`/`generated_at` 无效，或快照 `base_url` 与当前端点不一致时，单价列显示“未知”，用量与花费计算不受影响。
- `confirmed` 只代表同网关模型广场来源的公开分组价，不是当前 key 的实付价；`unverified` 显示“待核实”，未匹配显示“未知”；空价格不等于免费。
- 单价仅作参考，不重算接口返回的 `actual_cost`；“合计”行不汇总单价。

## 输出示例（合成数据）

```markdown
配额模式：无 Key 级限制(unrestricted)
充值额度：$100.0000 USD
剩余余额：$75.0000 USD · `███████████████░░░░░` **75.00%**
累计花费：$25.0000 USD

---

**今日及累计用量**
| 时段 | 请求 | 用量 | 花费（USD） |
|---|---:|---:|---:|
| 今日 | 1 | 1.0K | $1.00 |
| 累计 | **42** | **4.2K** | **$25.00** |

---

**各模型累计用量与花费**
| 模型 | 单价 | 输入/输出 | 缓存读/写 | 总量 | 命中率（%） | 花费（USD） |
|---|---:|---:|---:|---:|---:|---:|
| demo-model | 未知 | 1.0K / 200 | 3.0K / 0 | 4.2K | 75.00 | $25.00 |
| **合计** | **—** | **1.0K / 200** | **3.0K / 0** | **4.2K** | **75.00** | **$25.00** |

单价未知：快照文件缺失；模型用量与花费不受影响。
```

> 以上数值全部为合成示例，仅说明排版；实际输出必须来自本次查询结果。完整的输出格式规范见 [SKILL.md](./SKILL.md)。

## 计算规则

- `充值额度 = balance + total.actual_cost`。这是**展示用的计算值**，由当前余额与累计花费推算得出，**不是**网关财务系统的充值流水；赠送、人工额度调整、订阅额度等不在该式中体现，不能作为对账依据。
- `累计花费` 与各模型花费统一使用接口返回的 `actual_cost`，不由单价反推。
- `缓存命中率 = cache_read_tokens / (input_tokens + cache_read_tokens) × 100%`，保留两位小数；分母为 0 时记 `0.00`。

## 测试

仓库自带离线测试脚本：不依赖第三方库、不访问网络、不读取 `config.json`、只用合成数据与本地模拟响应。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$HOME/.config/opencode/skills/query-sub2api-usage/tests/test-query-sub2api-usage.ps1"
```

测试结果以本地运行或 CI 的实际输出为准。贡献前请先运行，参见 [CONTRIBUTING.md](./CONTRIBUTING.md)。

## 版本与许可

维护者与 AI 开发协助署名见 [CONTRIBUTORS.md](./CONTRIBUTORS.md)；贡献流程见 [CONTRIBUTING.md](./CONTRIBUTING.md)。

- [GitHub Releases](https://github.com/lilixxs/query-sub2api-usage/releases) 提供可下载源码；首次稳定发布为 `v1.5.1`。
- 以后推送到 `main` 且本次 CI 成功后，每个新增 commit 自动创建独立 Release，标签为 `commit-<完整 SHA>`，一次推送多个 commit 也逐个发布。重复运行不会重复创建；未推送的本地 commit、其他分支、PR 和手动 CI 不会发布。
- 自动 Release 的标题包含项目版本与短 SHA；commit 标签不是 SemVer 升版，版本号仍按贡献指南同步维护。源码包只包含 Git 已跟踪文件，不包含被忽略的本机 `config.json`。发布失败可重跑对应 Actions；避免改写 `main` 历史。

- 版本号在 `SKILL.md` 顶部、本文件顶部、`CHANGELOG.md` 与脚本 `$script:ScriptVersion`（请求头 `User-Agent: query-sub2api-usage/<版本>`）保持同步，遵循语义化版本；变更见 [CHANGELOG.md](./CHANGELOG.md)。
- 本项目采用 MIT 许可证，详见 [LICENSE](./LICENSE)。
