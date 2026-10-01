# =====================================================================
# query-sub2api-usage 离线回归测试
# 目标脚本: scripts/query-sub2api-usage.ps1
# 约束:
#   - 仅使用 Windows PowerShell 5.1 内置能力，无 Pester / 第三方模块
#   - 全程离线：不触网、不读取真实 config.json、不使用真实密钥
#   - 函数级测试通过 AST 提取顶层函数定义后 Invoke-Expression 加载
#     （不能 dot-source 整个脚本：顶层逻辑会读取配置并发起真实网络请求）
#   - 端到端用例在子 PowerShell 进程中运行：加载 AST 全文后，
#     注入桩函数 Read-Settings / Invoke-WebRequest 再执行主逻辑；
#     业务脚本中的 exit 0 只退出子进程，不会终止本测试父进程
#   - 合成快照/配置仅写入独立随机 TEMP 目录，finally 统一清理
# 运行:
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests/test-query-sub2api-usage.ps1
# 退出码: 0 = 全部通过；非 0 = 存在失败
# =====================================================================

$ErrorActionPreference = 'Stop'
try {
    [Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
    $OutputEncoding = [Console]::OutputEncoding
} catch {
    # 某些宿主下设置控制台编码可能失败，不影响测试本身
}

# 防御：本测试会话绝不使用真实环境变量配置
Remove-Item Env:SUB2API_BASE_URL -ErrorAction SilentlyContinue
Remove-Item Env:SUB2API_API_KEY -ErrorAction SilentlyContinue

# 定位目标脚本（tests/ 的上级即 skill 根目录）
$script:TestRoot = Split-Path -Parent $PSCommandPath
$script:SkillRoot = Split-Path -Parent $script:TestRoot
$script:ScriptPath = Join-Path $script:SkillRoot 'scripts\query-sub2api-usage.ps1'

$script:UTF8NoBom = New-Object Text.UTF8Encoding($false)
$script:UTF8Bom = New-Object Text.UTF8Encoding($true)
$script:PassCount = 0
$script:FailCount = 0
$script:FailureDetails = New-Object System.Collections.Generic.List[string]

# ---------------------------------------------------------------------
# 断言助手（英文标识，中文注释）
# ---------------------------------------------------------------------
function Format-TestValue {
    param($Value)
    if ($null -eq $Value) { return '<null>' }
    $text = [string]$Value
    if ($text.Length -gt 120) { $text = $text.Substring(0, 120) + '...' }
    return ('"{0}" ({1})' -f $text, $Value.GetType().Name)
}

function Tst-True {
    param([bool]$Condition, [string]$Name)
    if ($Condition) {
        $script:PassCount++
    } else {
        $script:FailCount++
        $script:FailureDetails.Add(('FAIL: {0}' -f $Name))
    }
}

function Tst-False {
    param($Condition, [string]$Name)
    Tst-True (-not [bool]$Condition) $Name
}

function Tst-Equal {
    param($Expected, $Actual, [string]$Name)
    $equal = $false
    if ($null -eq $Expected) {
        $equal = ($null -eq $Actual)
    } elseif ($Expected -is [string]) {
        # 字符串一律按序数大小写敏感比较，避免 -eq 默认忽略大小写掩盖大小写缺陷
        $equal = ([string]::CompareOrdinal($Expected, [string]$Actual) -eq 0)
    } else {
        $equal = ($Expected -eq $Actual)
    }
    if ($equal) {
        $script:PassCount++
    } else {
        $script:FailCount++
        $script:FailureDetails.Add(('FAIL: {0}' -f $Name))
        $script:FailureDetails.Add(('     expected: {0}' -f (Format-TestValue $Expected)))
        $script:FailureDetails.Add(('     actual:   {0}' -f (Format-TestValue $Actual)))
    }
}

function Tst-Null {
    param($Actual, [string]$Name)
    Tst-Equal $null $Actual $Name
}

function Tst-ContainsText {
    param([string]$Text, [string]$Needle, [string]$Name)
    Tst-True ($null -ne $Text -and $Text.IndexOf($Needle, [StringComparison]::Ordinal) -ge 0) $Name
}

function Tst-NotContainsText {
    param([string]$Text, [string]$Needle, [string]$Name)
    Tst-True ($null -eq $Text -or $Text.IndexOf($Needle, [StringComparison]::Ordinal) -lt 0) $Name
}

function Write-TestFile {
    param([string]$Path, [string]$Text)
    [IO.File]::WriteAllText($Path, $Text, $script:UTF8NoBom)
}

function New-TestDirectory {
    # 每组测试使用独立随机 TEMP 目录，绝不触碰项目目录
    $tempRoot = [IO.Path]::GetTempPath()
    $preferredRoot = Join-Path $tempRoot 'opencode'
    if (Test-Path -LiteralPath $preferredRoot -PathType Container) { $tempRoot = $preferredRoot }
    $dir = Join-Path $tempRoot ('sub2api-usage-test-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    return $dir
}

function Test-JsonToObject {
    # 用 JSON 字面量构造 PSCustomObject（保持对象语义，便于 PSObject.Properties 遍历）
    param([string]$Json)
    return (ConvertFrom-Json $Json)
}

# ---------------------------------------------------------------------
# 第 1 部分：目标脚本就位、静态检查（AST 解析、UTF-8 BOM）
# ---------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $script:ScriptPath)) {
    Write-Output ('FATAL: business script not found: {0}' -f $script:ScriptPath)
    exit 1
}

$parseTokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($script:ScriptPath, [ref]$parseTokens, [ref]$parseErrors)
Tst-True ((@($parseErrors)).Count -eq 0) ('AST parse: business script parses without syntax errors')

$scriptBytes = [IO.File]::ReadAllBytes($script:ScriptPath)
Tst-True ($scriptBytes.Length -ge 3 -and $scriptBytes[0] -eq 0xEF -and $scriptBytes[1] -eq 0xBB -and $scriptBytes[2] -eq 0xBF) 'BOM: business script is UTF-8 with BOM'

# 测试脚本自身也必须 UTF-8 带 BOM（中文注释在 5.1 下按 ANSI 读取会乱码）
$selfBytes = [IO.File]::ReadAllBytes($PSCommandPath)
Tst-True ($selfBytes.Length -ge 3 -and $selfBytes[0] -eq 0xEF -and $selfBytes[1] -eq 0xBB -and $selfBytes[2] -eq 0xBF) 'BOM: test script itself is UTF-8 with BOM'

# 版本号以 AST 静态提取，不执行主逻辑；仅校验 SemVer 格式（不固定具体版本，避免与主 agent 版本维护互相踩踏）
$versionAssignments = @($ast.FindAll({ $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] -and $args[0].Left.Extent.Text -eq '$script:ScriptVersion' }, $true))
Tst-True ($versionAssignments.Count -ge 1) 'AST: script defines $script:ScriptVersion'
if ($versionAssignments.Count -ge 1) {
    $versionText = [string]$versionAssignments[0].Right.Extent.Text -replace "^'|'$", ''
    Tst-True ($versionText -match '^\d+\.\d+\.\d+$') ('version: ScriptVersion uses semver format, got: {0}' -f $versionText)
}

# ---------------------------------------------------------------------
# 第 2 部分：AST 提取顶层函数定义并 Invoke-Expression 加载（绝不执行顶层主逻辑）
# ---------------------------------------------------------------------
if ($null -eq $ast.EndBlock) {
    Write-Output 'FATAL: unexpected AST shape (EndBlock missing)'
    exit 1
}
$functionAsts = @($ast.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.FunctionDefinitionAst] })
foreach ($fnAst in $functionAsts) {
    Invoke-Expression $fnAst.Extent.Text
}
Tst-True ($functionAsts.Count -ge 20) ('AST load: extracted top-level function definitions (count={0})' -f $functionAsts.Count)

# ---------------------------------------------------------------------
# 第 3 部分：Get-UsageUrl 端点拼接（/v1 去重、自定义路径）
# ---------------------------------------------------------------------
Tst-Equal 'https://example.com/v1/usage' (Get-UsageUrl -Base 'https://example.com' -Path '/v1/usage') 'Get-UsageUrl: base without /v1 auto-appends /v1/usage'
Tst-Equal 'https://example.com/v1/usage' (Get-UsageUrl -Base 'https://example.com/v1' -Path '/v1/usage') 'Get-UsageUrl: dedups /v1 between base and path'
Tst-Equal 'https://example.com/v1/usage' (Get-UsageUrl -Base 'https://example.com/v1/' -Path 'v1/usage') 'Get-UsageUrl: trims slashes then dedups /v1'
Tst-Equal 'https://example.com/usage' (Get-UsageUrl -Base 'https://example.com' -Path 'usage') 'Get-UsageUrl: custom path without /v1 is preserved'
Tst-Equal 'https://example.com/v1/usage' (Get-UsageUrl -Base 'https://example.com/v1' -Path '/usage') 'Get-UsageUrl: custom path appended after base ending with /v1'
Tst-Equal 'https://example.com/V1/usage' (Get-UsageUrl -Base 'https://example.com/V1' -Path '/V1/usage') 'Get-UsageUrl: case-insensitive /v1 dedup preserves original path case'
Tst-Equal 'https://example.com/v1/usage' (Get-UsageUrl -Base '  https://example.com/v1  ' -Path ' /v1/usage ') 'Get-UsageUrl: surrounding whitespace trimmed'

# ---------------------------------------------------------------------
# 第 4 部分：Format-QuotaMode 六类取值
# 已知两类、大小写敏感未知值、任意未知值、null、空串、纯空白
# ---------------------------------------------------------------------
Tst-Equal '无 Key 级限制(unrestricted)' (Format-QuotaMode 'unrestricted') 'quota mode: unrestricted mapped'
Tst-Equal 'Key 限额/限速(quota_limited)' (Format-QuotaMode 'quota_limited') 'quota mode: quota_limited mapped'
Tst-Equal '未知模式(UNRESTRICTED)' (Format-QuotaMode 'UNRESTRICTED') 'quota mode: switch is case-sensitive, uppercase value shows raw'
Tst-Equal '未知模式(hybrid)' (Format-QuotaMode 'hybrid') 'quota mode: unknown non-empty value shows raw'
Tst-Equal '未提供' (Format-QuotaMode $null) 'quota mode: null shows 未提供'
Tst-Equal '未提供' (Format-QuotaMode '') 'quota mode: empty string shows 未提供'
Tst-Equal '未提供' (Format-QuotaMode '   ') 'quota mode: whitespace-only shows 未提供'

# ---------------------------------------------------------------------
# 第 5 部分：紧凑数量与金额格式化
# ---------------------------------------------------------------------
Tst-Equal '0' (Format-CompactNumber $null) 'compact number: null renders as 0'
Tst-Equal '0' (Format-CompactNumber 0) 'compact number: zero renders as 0'
Tst-Equal '999' (Format-CompactNumber 999) 'compact number: below 1K stays plain'
Tst-Equal '1.0K' (Format-CompactNumber 1000) 'compact number: exactly 1K'
Tst-Equal '1.5K' (Format-CompactNumber 1500) 'compact number: 1.5K'
Tst-Equal '144K' (Format-CompactNumber 144000) 'compact number: >=100 scaled value drops decimals'
Tst-Equal '3.8M' (Format-CompactNumber 3800000) 'compact number: 3.8M'
Tst-Equal '47.3M' (Format-CompactNumber 47300000) 'compact number: 47.3M'
Tst-Equal '1.4B' (Format-CompactNumber 1443000000) 'compact number: 1.4B'
Tst-Equal '12.0B' (Format-CompactNumber 12000000000) 'compact number: 12.0B'
Tst-Equal '-1.5M' (Format-CompactNumber -1500000) 'compact number: negative value keeps sign'

Tst-Equal '$96.59' (Format-Money 96.5949 'USD' 2) 'money: two decimals with USD symbol'
Tst-Equal '$86.6508' (Format-Money 86.6508 'USD' 4) 'money: four decimals summary format'
Tst-Equal '¥12.00' (Format-Money 12 'CNY' 2) 'money: CNY symbol'
Tst-Equal '1.50' (Format-Money 1.5 'EUR' 2) 'money: unknown unit keeps plain amount (Format-Money 不附加未知币种后缀，与 Format-UnitAmount 行为不一致，已记录为观察项)'
Tst-Equal '$0.00' (Format-Money $null 'USD' 2) 'money: null treated as zero'
Tst-Equal '$5.10' (Format-Money 5.1 'usd' 2) 'money: lowercase unit still maps to symbol'

# ---------------------------------------------------------------------
# 第 6 部分：缓存命中率与零分母
# ---------------------------------------------------------------------
$cacheRate = Get-CacheHitRate 3800000 10500000
Tst-Equal 73.43 ([math]::Round($cacheRate, 2)) 'cache rate: normal computation rounds to two decimals'
Tst-Equal 0.0 (Get-CacheHitRate 0 0) 'cache rate: zero denominator returns 0'
Tst-Equal 0.0 (Get-CacheHitRate $null $null) 'cache rate: null tokens return 0'
$allCache = Get-CacheHitRate $null 5000
Tst-Equal 100.0 ([math]::Round($allCache, 2)) 'cache rate: all cache-read returns 100'

# ---------------------------------------------------------------------
# 第 7 部分：Markdown 转义
# ---------------------------------------------------------------------
Tst-Equal 'a&#124;b' (Escape-MarkdownCell 'a|b') 'markdown cell: pipe escaped'
Tst-Equal 'x&#96;y' (Escape-MarkdownCell 'x`y') 'markdown cell: backtick escaped'
Tst-Equal '&lt;&amp;&gt;' (Escape-MarkdownCell '<&>') 'markdown cell: html entities escaped'
Tst-Equal 'a\*b\_c' (Escape-MarkdownCell 'a*b_c') 'markdown cell: emphasis markers escaped'
Tst-Equal '\[x\]' (Escape-MarkdownCell '[x]') 'markdown cell: brackets escaped'
Tst-Equal 'l1 l2' (Escape-MarkdownCell "l1`nl2") 'markdown cell: newline flattened to space'
Tst-Equal 'l1 l2' (Escape-MarkdownCell "l1`r`nl2") 'markdown cell: CRLF flattened to space'
Tst-Equal '' (Escape-MarkdownCell $null) 'markdown cell: null renders empty'

Tst-Equal "a'b" (Escape-MarkdownCode 'a`b') 'markdown code: backtick neutralized'
Tst-Equal 'x y' (Escape-MarkdownCode "x`r`ny") 'markdown code: CRLF flattened'
Tst-Equal '' (Escape-MarkdownCode $null) 'markdown code: null renders empty'

# ---------------------------------------------------------------------
# 第 8 部分：Get-NormalizedBaseUrl 规范化与拒绝规则
# 拒绝 query / userinfo / fragment / 非 http(s)；host 小写、路径大小写保留
# ---------------------------------------------------------------------
Tst-Equal 'https://example.com' (Get-NormalizedBaseUrl 'https://Example.com/v1') 'base url: host lowercased and /v1 suffix stripped'
Tst-Equal 'https://example.com' (Get-NormalizedBaseUrl 'https://example.com/v1/') 'base url: trailing slash stripped before /v1 removal'
Tst-Equal 'https://example.com/base' (Get-NormalizedBaseUrl 'https://example.com/base/v1') 'base url: non-root path preserved with /v1 suffix removed'
Tst-Equal 'https://example.com/base' (Get-NormalizedBaseUrl 'https://example.com/base') 'base url: plain path preserved'
Tst-Equal 'https://example.com/Gateway' (Get-NormalizedBaseUrl 'https://example.com/Gateway/V1') 'base url: path case preserved, /v1 removed case-insensitively'
Tst-Equal '' (Get-NormalizedBaseUrl 'https://user:pass@example.com/v1') 'base url: userinfo rejected'
Tst-Equal '' (Get-NormalizedBaseUrl 'https://example.com/?api=1') 'base url: query string rejected'
Tst-Equal '' (Get-NormalizedBaseUrl 'https://example.com/#frag') 'base url: fragment rejected'
Tst-Equal '' (Get-NormalizedBaseUrl 'ftp://example.com') 'base url: non-http(s) scheme rejected'
Tst-Equal '' (Get-NormalizedBaseUrl 'not a url') 'base url: garbage text rejected'
Tst-Equal '' (Get-NormalizedBaseUrl $null) 'base url: null rejected'
Tst-Equal '' (Get-NormalizedBaseUrl '   ') 'base url: whitespace rejected'

# ---------------------------------------------------------------------
# 第 9 部分：Get-Number 小助手
# ---------------------------------------------------------------------
$valueHolder = Test-JsonToObject '{"v":"2.5"}'
Tst-Equal 2.5 (Get-Number $valueHolder 'v') 'get number: string number converted to double'
Tst-Null (Get-Number $valueHolder 'missing') 'get number: missing field returns null'

# ---------------------------------------------------------------------
# 第 10 部分：价格数值与单位校验（非法 / 零 / 超小价格）
# ---------------------------------------------------------------------
Tst-Equal 0.00000015 (ConvertTo-PriceNumber '0.00000015') 'price number: tiny value parsed'
Tst-Equal 1.5e-7 (ConvertTo-PriceNumber '1.5e-7') 'price number: scientific notation parsed'
Tst-Equal 0 (ConvertTo-PriceNumber 0) 'price number: explicit zero accepted'
Tst-Equal 0 (ConvertTo-PriceNumber '0.0') 'price number: zero string accepted'
Tst-Equal 2.5 (ConvertTo-PriceNumber '2.5') 'price number: plain decimal parsed'
Tst-Null (ConvertTo-PriceNumber 'abc') 'price number: non-numeric rejected'
Tst-Null (ConvertTo-PriceNumber -1) 'price number: negative rejected'
Tst-Null (ConvertTo-PriceNumber '-0.5') 'price number: negative string rejected'
Tst-Null (ConvertTo-PriceNumber 'NaN') 'price number: NaN rejected'
Tst-Null (ConvertTo-PriceNumber 'Infinity') 'price number: Infinity rejected'
Tst-Null (ConvertTo-PriceNumber $true) 'price number: boolean rejected'
Tst-Null (ConvertTo-PriceNumber $null) 'price number: null rejected'

Tst-Equal '$0.00000015' (Format-UnitAmount 0.00000015 'USD') 'unit amount: tiny non-zero keeps decimals instead of showing free'
$tinyAmount = Format-UnitAmount 0.00000000000000015 'USD'
Tst-True ($tinyAmount -like '*E-16*') ('unit amount: ultra-tiny falls back to scientific notation, got: {0}' -f $tinyAmount)
Tst-Equal '$0' (Format-UnitAmount 0 'USD') 'unit amount: explicit zero shows 0'
Tst-Equal '$1.5' (Format-UnitAmount 1.5 'USD') 'unit amount: USD symbol'
Tst-Equal '¥6' (Format-UnitAmount 6 'CNY') 'unit amount: CNY symbol'
Tst-Equal '2.5 EUR' (Format-UnitAmount 2.5 'EUR') 'unit amount: other currency suffix'
Tst-Equal '1.5' (Format-UnitAmount 1.5 '') 'unit amount: empty currency renders bare number'

# ---------------------------------------------------------------------
# 第 11 部分：单位 / 倍率 / 条件旗标判定
# ---------------------------------------------------------------------
$tokenUnits = Test-JsonToObject '{"input_price":"USD/token","output_price":"USD/token"}'
Tst-True (Test-PriceUnit -Units $tokenUnits -Name 'input_price' -Expected 'USD/token') 'price unit: matching USD/token accepted'
Tst-True (Test-PriceUnit -Units $tokenUnits -Name 'input_price' -Expected 'usd/token') 'price unit: unit comparison case-insensitive'
Tst-False (Test-PriceUnit -Units $tokenUnits -Name 'missing' -Expected 'USD/token') 'price unit: missing unit rejected'
Tst-False (Test-PriceUnit -Units $tokenUnits -Name 'input_price' -Expected 'USD/request') 'price unit: mismatched dimension rejected'
Tst-False (Test-PriceUnit -Units $null -Name 'input_price' -Expected 'USD/token') 'price unit: null units rejected'

Tst-False (Test-MultiplierCondition 1) 'multiplier: exactly 1 is neutral'
Tst-False (Test-MultiplierCondition '1.0') 'multiplier: numeric string 1.0 is neutral'
Tst-True (Test-MultiplierCondition 1.5) 'multiplier: 1.5 is a condition'
Tst-True (Test-MultiplierCondition 'abc') 'multiplier: non-numeric value is a condition'
Tst-False (Test-MultiplierCondition $null) 'multiplier: null is neutral'
Tst-False (Test-MultiplierCondition $false) 'multiplier: bool false is neutral'
Tst-True (Test-MultiplierCondition $true) 'multiplier: bool true is a condition'

Tst-False (Test-ConditionActive $null) 'condition active: null inactive'
Tst-False (Test-ConditionActive '') 'condition active: empty string inactive'
Tst-False (Test-ConditionActive '   ') 'condition active: whitespace inactive'
Tst-True (Test-ConditionActive 'on') 'condition active: non-empty string active'
Tst-False (Test-ConditionActive $false) 'condition active: bool false inactive'
Tst-True (Test-ConditionActive $true) 'condition active: bool true active'
$emptyConditionObject = Test-JsonToObject '{}'
Tst-False (Test-ConditionActive $emptyConditionObject) 'condition active: empty object inactive'
$nonEmptyConditionObject = Test-JsonToObject '{"enabled":true}'
Tst-True (Test-ConditionActive $nonEmptyConditionObject) 'condition active: object with properties active'
Tst-False (Test-ConditionActive @{}) 'condition active: empty hashtable inactive'
Tst-True (Test-ConditionActive @{interval = '9:00-18:00'}) 'condition active: non-empty hashtable active'

# ---------------------------------------------------------------------
# 第 12 部分：Test-ConditionalPrice 条件价识别
# ---------------------------------------------------------------------
Tst-False (Test-ConditionalPrice $null) 'conditional: null price not conditional'
$plainTokenPrice = Test-JsonToObject '{"pricing":{"billing_mode":"token","input_price":0.0000015,"output_price":0.000006}}'
Tst-False (Test-ConditionalPrice $plainTokenPrice) 'conditional: plain token price not conditional'
$noPricingPrice = Test-JsonToObject '{"currency":"USD"}'
Tst-False (Test-ConditionalPrice $noPricingPrice) 'conditional: missing pricing object not conditional'

$intervalPrice = Test-JsonToObject '{"pricing":{"billing_mode":"token","intervals":["09:00-18:00"]}}'
Tst-True (Test-ConditionalPrice $intervalPrice) 'conditional: intervals active'
$reasoningPrice = Test-JsonToObject '{"pricing":{"reasoning_effort_multipliers":{"high":1.5}}}'
Tst-True (Test-ConditionalPrice $reasoningPrice) 'conditional: reasoning effort multipliers active'
# 注意：Test-ConditionalPrice 在 $Price.pricing 为 null 时提前返回 false，
# time_pricing / long_context_basis 检查仅在 pricing 对象存在时可达；
# 快照真实数据 pricing 恒存在，故用例带最小 pricing 对象（退化数据行为已记录为观察项）
$timePrice = Test-JsonToObject '{"pricing":{"billing_mode":"token","input_price":1,"output_price":2},"time_pricing":{"enabled":true}}'
Tst-True (Test-ConditionalPrice $timePrice) 'conditional: time pricing active'
$longContextPrice = Test-JsonToObject '{"pricing":{"billing_mode":"token","input_price":1,"output_price":2},"long_context_basis":"cache"}'
Tst-True (Test-ConditionalPrice $longContextPrice) 'conditional: long context basis active'

$mixedBillingPrice = Test-JsonToObject '{"pricing":{"billing_mode":"token","input_price":1,"output_price":2,"per_request_price":0.01}}'
Tst-True (Test-ConditionalPrice $mixedBillingPrice) 'conditional: mixed token+request billing kept conditional'
$imageRequestPrice = Test-JsonToObject '{"pricing":{"billing_mode":"request","per_request_price":0.02,"image_input_price":0.001}}'
Tst-True (Test-ConditionalPrice $imageRequestPrice) 'conditional: request billing with image price kept conditional'

$groupMultiplierPrice = Test-JsonToObject '{"pricing":{"billing_mode":"token","input_price":1,"output_price":2},"group":{"id":"g1","name":"default","scale_multiplier":1.5}}'
Tst-True (Test-ConditionalPrice $groupMultiplierPrice) 'conditional: non-unit group multiplier'
$neutralGroupPrice = Test-JsonToObject '{"pricing":{"billing_mode":"token","input_price":1,"output_price":2},"group":{"id":"g1","name":"default","scale_multiplier":1.0}}'
Tst-False (Test-ConditionalPrice $neutralGroupPrice) 'conditional: group multiplier exactly 1 is neutral'
$peakDisabledPrice = Test-JsonToObject '{"pricing":{"billing_mode":"token","input_price":1,"output_price":2},"group":{"id":"g1","peak_rate_enabled":false,"peak_input_multiplier":2}}'
Tst-False (Test-ConditionalPrice $peakDisabledPrice) 'conditional: disabled peak flag does not shadow base price'
$peakEnabledPrice = Test-JsonToObject '{"pricing":{"billing_mode":"token","input_price":1,"output_price":2},"group":{"id":"g1","peak_rate_enabled":true,"peak_input_multiplier":2}}'
Tst-True (Test-ConditionalPrice $peakEnabledPrice) 'conditional: enabled peak multiplier counts'
$discountPrice = Test-JsonToObject '{"pricing":{"billing_mode":"token","input_price":1,"output_price":2},"group":{"id":"g1","group_discount":0.8}}'
Tst-True (Test-ConditionalPrice $discountPrice) 'conditional: group discount counts as condition'

# ---------------------------------------------------------------------
# 第 13 部分：单组价格文本（token / request，单位非法则拒绝）
# ---------------------------------------------------------------------
$validTokenPrice = Test-JsonToObject '{"currency":"USD","pricing":{"billing_mode":"token","input_price":0.0000015,"output_price":0.000006},"units":{"input_price":"USD/token","output_price":"USD/token"}}'
Tst-Equal '$1.5 / $6' (Get-SimpleTokenPriceText $validTokenPrice 'USD') 'token price: scales USD/token to per-million display'
$zeroTokenPrice = Test-JsonToObject '{"currency":"USD","pricing":{"billing_mode":"token","input_price":0,"output_price":0},"units":{"input_price":"USD/token","output_price":"USD/token"}}'
Tst-Equal '$0 / $0' (Get-SimpleTokenPriceText $zeroTokenPrice 'USD') 'token price: explicit zero shown, not hidden as free'
$negativeTokenPrice = Test-JsonToObject '{"currency":"USD","pricing":{"billing_mode":"token","input_price":-1,"output_price":2},"units":{"input_price":"USD/token","output_price":"USD/token"}}'
Tst-Null (Get-SimpleTokenPriceText $negativeTokenPrice 'USD') 'token price: negative input rejected'
$missingOutputPrice = Test-JsonToObject '{"currency":"USD","pricing":{"billing_mode":"token","input_price":0.0000015},"units":{"input_price":"USD/token","output_price":"USD/token"}}'
Tst-Null (Get-SimpleTokenPriceText $missingOutputPrice 'USD') 'token price: missing output price rejected, not padded with zero'
$wrongUnitTokenPrice = Test-JsonToObject '{"currency":"USD","pricing":{"billing_mode":"token","input_price":0.0000015,"output_price":0.000006},"units":{"input_price":"CNY/token","output_price":"USD/token"}}'
Tst-Null (Get-SimpleTokenPriceText $wrongUnitTokenPrice 'USD') 'token price: mismatched unit rejected'

$validRequestPrice = Test-JsonToObject '{"currency":"USD","pricing":{"billing_mode":"request","per_request_price":0.02},"units":{"per_request_price":"USD/request"}}'
Tst-Equal '$0.02/次' (Get-SimpleRequestPriceText $validRequestPrice 'USD') 'request price: per-request price with /次 suffix'
$altRequestPrice = Test-JsonToObject '{"currency":"USD","pricing":{"request_price":0.05},"units":{"request_price":"USD/request"}}'
Tst-Equal '$0.05/次' (Get-SimpleRequestPriceText $altRequestPrice 'USD') 'request price: alternate request_price field accepted'
$wrongUnitRequestPrice = Test-JsonToObject '{"currency":"USD","pricing":{"per_request_price":0.02},"units":{"per_request_price":"USD/token"}}'
Tst-Null (Get-SimpleRequestPriceText $wrongUnitRequestPrice 'USD') 'request price: wrong unit rejected'

# ---------------------------------------------------------------------
# 第 14 部分：Resolve-ModelUnitPrice 状态判定
# confirmed / unverified / unknown / 无来源 / 来源大小写 / 多组 / 条件
# ---------------------------------------------------------------------
$validatedSources = [System.Collections.Hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
$validatedSources['model-plaza'] = $true

$confirmedTokenEntry = Test-JsonToObject '{"status":"confirmed","prices":[{"source":"model-plaza","currency":"USD","group":{"id":"g1","name":"default"},"pricing":{"billing_mode":"token","input_price":0.0000015,"output_price":0.000006},"units":{"input_price":"USD/token","output_price":"USD/token"}}]}'
$resolvedToken = Resolve-ModelUnitPrice $confirmedTokenEntry $validatedSources
Tst-Equal 'confirmed' $resolvedToken.verdict 'resolve: confirmed token price verdict'
Tst-Equal '$1.5 / $6' $resolvedToken.text 'resolve: confirmed token price text'

Tst-Equal '未知' ((Resolve-ModelUnitPrice $null $validatedSources).text) 'resolve: null entry unknown'
Tst-Equal 'unknown' ((Resolve-ModelUnitPrice (Test-JsonToObject '{"status":"unknown"}') $validatedSources).verdict) 'resolve: unknown status verdict'
Tst-Equal 'unknown' ((Resolve-ModelUnitPrice (Test-JsonToObject '{"status":""}') $validatedSources).verdict) 'resolve: empty status unknown'
Tst-Equal 'unknown' ((Resolve-ModelUnitPrice (Test-JsonToObject '{"status":"mystery"}') $validatedSources).verdict) 'resolve: unexpected status falls back to unknown'
$unverifiedEntry = Test-JsonToObject '{"status":"unverified"}'
Tst-Equal 'unverified' ((Resolve-ModelUnitPrice $unverifiedEntry $validatedSources).verdict) 'resolve: unverified status verdict'
Tst-Equal '待核实' ((Resolve-ModelUnitPrice $unverifiedEntry $validatedSources).text) 'resolve: unverified text'

$confirmedNoPrices = Test-JsonToObject '{"status":"confirmed"}'
Tst-Equal 'unverified' ((Resolve-ModelUnitPrice $confirmedNoPrices $validatedSources).verdict) 'resolve: confirmed with empty prices is not free, shows 待核实'

$noValidatedSources = Test-JsonToObject '{"status":"confirmed","prices":[{"source":"model-plaza","currency":"USD","pricing":{"billing_mode":"token","input_price":1,"output_price":2},"units":{"input_price":"USD/token","output_price":"USD/token"}}]}'
Tst-Equal 'unverified' ((Resolve-ModelUnitPrice $noValidatedSources $null).verdict) 'resolve: null validated sources forces unverified'
Tst-Equal 'unverified' ((Resolve-ModelUnitPrice $noValidatedSources ([System.Collections.Hashtable]::new())).verdict) 'resolve: missing source key forces unverified'

$wrongSourceCase = Test-JsonToObject '{"status":"confirmed","prices":[{"source":"Model-Plaza","currency":"USD","pricing":{"billing_mode":"token","input_price":1,"output_price":2},"units":{"input_price":"USD/token","output_price":"USD/token"}}]}'
Tst-Equal 'unverified' ((Resolve-ModelUnitPrice $wrongSourceCase $validatedSources).verdict) 'resolve: source name is case-sensitive, Model-Plaza rejected'
$missingSource = Test-JsonToObject '{"status":"confirmed","prices":[{"currency":"USD","pricing":{"billing_mode":"token","input_price":1,"output_price":2},"units":{"input_price":"USD/token","output_price":"USD/token"}}]}'
Tst-Equal 'unverified' ((Resolve-ModelUnitPrice $missingSource $validatedSources).verdict) 'resolve: missing source field rejected'

$cnyPrice = Test-JsonToObject '{"status":"confirmed","prices":[{"source":"model-plaza","currency":"CNY","pricing":{"billing_mode":"token","input_price":1,"output_price":2},"units":{"input_price":"USD/token","output_price":"USD/token"}}]}'
Tst-Equal 'unverified' ((Resolve-ModelUnitPrice $cnyPrice $validatedSources).verdict) 'resolve: non-USD currency rejected'
$lowerUsdPrice = Test-JsonToObject '{"status":"confirmed","prices":[{"source":"model-plaza","currency":"usd","pricing":{"billing_mode":"token","input_price":1,"output_price":2},"units":{"input_price":"USD/token","output_price":"USD/token"}}]}'
Tst-Equal 'confirmed' ((Resolve-ModelUnitPrice $lowerUsdPrice $validatedSources).verdict) 'resolve: currency comparison case-insensitive'

$multiGroupEntry = Test-JsonToObject '{"status":"confirmed","prices":[{"source":"model-plaza","currency":"USD","group":{"id":"g1","name":"default"},"pricing":{"billing_mode":"token","input_price":1,"output_price":2},"units":{"input_price":"USD/token","output_price":"USD/token"}},{"source":"model-plaza","currency":"USD","group":{"id":"g2","name":"tier2"},"pricing":{"billing_mode":"token","input_price":2,"output_price":4},"units":{"input_price":"USD/token","output_price":"USD/token"}}]}'
$resolvedMulti = Resolve-ModelUnitPrice $multiGroupEntry $validatedSources
Tst-Equal '多分组价（见快照）' $resolvedMulti.text 'resolve: multiple groups refuse single price pick'
Tst-Equal 'confirmed' $resolvedMulti.verdict 'resolve: multi-group verdict stays confirmed'

$sameGroupEntry = Test-JsonToObject '{"status":"confirmed","prices":[{"source":"model-plaza","currency":"USD","group":{"id":"g1"},"pricing":{"billing_mode":"token","input_price":1,"output_price":2},"units":{"input_price":"USD/token","output_price":"USD/token"}},{"source":"model-plaza","currency":"USD","group":{"id":"g1"},"pricing":{"billing_mode":"token","input_price":3,"output_price":6},"units":{"input_price":"USD/token","output_price":"USD/token"}}]}'
$resolvedSameGroup = Resolve-ModelUnitPrice $sameGroupEntry $validatedSources
Tst-Equal '条件价（见快照）' $resolvedSameGroup.text 'resolve: multiple entries in same group shown as conditional'

$conditionalEntry = Test-JsonToObject '{"status":"confirmed","prices":[{"source":"model-plaza","currency":"USD","group":{"id":"g1"},"pricing":{"billing_mode":"token","input_price":1,"output_price":2,"intervals":["09:00-18:00"]},"units":{"input_price":"USD/token","output_price":"USD/token"}}]}'
Tst-Equal '条件价（见快照）' ((Resolve-ModelUnitPrice $conditionalEntry $validatedSources).text) 'resolve: single price with intervals shown as conditional'

$imageBillingEntry = Test-JsonToObject '{"status":"confirmed","prices":[{"source":"model-plaza","currency":"USD","pricing":{"billing_mode":"image"}}]}'
Tst-Equal '条件价（见快照）' ((Resolve-ModelUnitPrice $imageBillingEntry $validatedSources).text) 'resolve: unsupported billing mode kept conditional'

$badUnitTokenEntry = Test-JsonToObject '{"status":"confirmed","prices":[{"source":"model-plaza","currency":"USD","pricing":{"billing_mode":"token","input_price":1,"output_price":2},"units":{"input_price":"USD/request","output_price":"USD/token"}}]}'
Tst-Equal 'unverified' ((Resolve-ModelUnitPrice $badUnitTokenEntry $validatedSources).verdict) 'resolve: token mode with wrong unit unverified'

$validRequestEntry = Test-JsonToObject '{"status":"confirmed","prices":[{"source":"model-plaza","currency":"USD","pricing":{"billing_mode":"request","per_request_price":0.02},"units":{"per_request_price":"USD/request"}}]}'
$resolvedRequest = Resolve-ModelUnitPrice $validRequestEntry $validatedSources
Tst-Equal 'confirmed' $resolvedRequest.verdict 'resolve: confirmed request price verdict'
Tst-Equal '$0.02/次' $resolvedRequest.text 'resolve: confirmed request price text'

# ---------------------------------------------------------------------
# 第 15 部分：Read-PriceSnapshot 快照校验
# missing / 解析失败 / schema / generated_at / base_url 缺失 / 跨网关 /
# host 大小写 / 路径大小写 / 来源端点 / 精确模型 ID / 计数
# 合成快照仅写入独立随机 TEMP 目录
# ---------------------------------------------------------------------
$snapshotDir = New-TestDirectory
try {
    $effectiveBase = 'https://gw.example.com/v1'

    $defaultEndpointsJson = @'
[
    { "url": "https://gw.example.com/api/v1/model-plaza", "http_status": 200, "status": "ok" }
]
'@
    $defaultModelsJson = @'
[
    { "model_id": "GPT-X", "status": "confirmed", "prices": [ { "source": "model-plaza", "currency": "USD", "group": { "id": "g1", "name": "default" }, "pricing": { "billing_mode": "token", "input_price": 0.0000015, "output_price": 0.000006 }, "units": { "input_price": "USD/token", "output_price": "USD/token" } } ] },
    { "model_id": "unv-model", "status": "unverified" },
    { "model_id": "unk-model", "status": "unknown" },
    { "model_id": "", "status": "confirmed" }
]
'@
    $snapshotTemplate = @"
{
  "schema_version": __SCHEMA__,
  "generated_at": "__GENERATED__",
  "base_url": "__BASE_URL__",
  "endpoints": __ENDPOINTS__,
  "models": __MODELS__
}
"@

    function New-SnapshotText {
        param(
            [string]$SchemaVersion = '1',
            [string]$GeneratedAt = '2026-10-01T08:00:00Z',
            [string]$BaseUrl = 'https://gw.example.com/v1',
            [string]$Endpoints = '',
            [string]$Models = ''
        )
        if ($Endpoints -eq '') { $Endpoints = $defaultEndpointsJson }
        if ($Models -eq '') { $Models = $defaultModelsJson }
        return $snapshotTemplate.Replace('__SCHEMA__', $SchemaVersion).Replace('__GENERATED__', $GeneratedAt).Replace('__BASE_URL__', $BaseUrl).Replace('__ENDPOINTS__', $Endpoints).Replace('__MODELS__', $Models)
    }

    function Test-WriteSnapshot {
        param([string]$Name, [string]$Text)
        $path = Join-Path $snapshotDir $Name
        Write-TestFile $path $Text
        return $path
    }

    # 15.1 快照缺失
    $missingResult = Read-PriceSnapshot -Path (Join-Path $snapshotDir 'does-not-exist.json') -EffectiveBaseUrl $effectiveBase
    Tst-False $missingResult.usable 'snapshot missing: not usable'
    Tst-Equal '快照文件缺失' $missingResult.reason 'snapshot missing: reason'

    # 15.2 解析失败
    $invalidPath = Test-WriteSnapshot 'invalid.json' '{oops not json'
    $invalidResult = Read-PriceSnapshot -Path $invalidPath -EffectiveBaseUrl $effectiveBase
    Tst-False $invalidResult.usable 'snapshot invalid json: not usable'
    Tst-Equal '快照解析失败' $invalidResult.reason 'snapshot invalid json: reason'

    # 15.3 schema_version 无效
    $schema2Path = Test-WriteSnapshot 'schema2.json' (New-SnapshotText -SchemaVersion '2')
    $schema2Result = Read-PriceSnapshot -Path $schema2Path -EffectiveBaseUrl $effectiveBase
    Tst-False $schema2Result.usable 'snapshot schema 2: not usable'
    Tst-Equal '快照 schema_version 无效' $schema2Result.reason 'snapshot schema 2: reason'
    $schemaTextPath = Test-WriteSnapshot 'schematext.json' (New-SnapshotText -SchemaVersion '"abc"')
    $schemaTextResult = Read-PriceSnapshot -Path $schemaTextPath -EffectiveBaseUrl $effectiveBase
    Tst-Equal '快照 schema_version 无效' $schemaTextResult.reason 'snapshot schema non-numeric: reason'

    # 15.4 generated_at 无效
    $badTimePath = Test-WriteSnapshot 'badtime.json' (New-SnapshotText -GeneratedAt 'not-a-date')
    $badTimeResult = Read-PriceSnapshot -Path $badTimePath -EffectiveBaseUrl $effectiveBase
    Tst-Equal '快照 generated_at 无效' $badTimeResult.reason 'snapshot generated_at invalid: reason'
    $noTimePath = Test-WriteSnapshot 'notime.json' (New-SnapshotText -GeneratedAt '')
    $noTimeResult = Read-PriceSnapshot -Path $noTimePath -EffectiveBaseUrl $effectiveBase
    Tst-Equal '快照 generated_at 无效' $noTimeResult.reason 'snapshot generated_at missing: reason'

    # 15.5 generated_at UTC 归一化（带偏移换算为 UTC）
    $offsetTimePath = Test-WriteSnapshot 'offsettime.json' (New-SnapshotText -GeneratedAt '2026-10-01T16:00:00+08:00')
    $offsetTimeResult = Read-PriceSnapshot -Path $offsetTimePath -EffectiveBaseUrl $effectiveBase
    Tst-True $offsetTimeResult.usable 'snapshot offset generated_at: usable'
    Tst-Equal '2026-10-01T08:00:00Z' $offsetTimeResult.generated_at 'snapshot offset generated_at: normalized to UTC'

    # 15.6 base_url 缺失
    $noBasePath = Test-WriteSnapshot 'nobase.json' (New-SnapshotText -BaseUrl '')
    $noBaseResult = Read-PriceSnapshot -Path $noBasePath -EffectiveBaseUrl $effectiveBase
    Tst-Equal '快照 base_url 缺失' $noBaseResult.reason 'snapshot base_url missing: reason'

    # 15.7 跨网关拒绝
    $crossPath = Test-WriteSnapshot 'cross.json' (New-SnapshotText -BaseUrl 'https://other.example.com/v1')
    $crossResult = Read-PriceSnapshot -Path $crossPath -EffectiveBaseUrl $effectiveBase
    Tst-False $crossResult.usable 'snapshot cross-gateway: not usable'
    Tst-Equal '快照 base_url 与当前端点不一致' $crossResult.reason 'snapshot cross-gateway: reason'

    # 15.8 相似域后缀欺骗拒绝
    $evilPath = Test-WriteSnapshot 'evil.json' (New-SnapshotText -BaseUrl 'https://gw.example.com.evil.com/v1')
    $evilResult = Read-PriceSnapshot -Path $evilPath -EffectiveBaseUrl $effectiveBase
    Tst-False $evilResult.usable 'snapshot lookalike domain: rejected'

    # 15.9 host 大小写不敏感匹配
    $upperPath = Test-WriteSnapshot 'upper.json' (New-SnapshotText -BaseUrl 'https://GW.Example.COM/v1')
    $upperResult = Read-PriceSnapshot -Path $upperPath -EffectiveBaseUrl $effectiveBase
    Tst-True $upperResult.usable 'snapshot uppercase host: matched after normalization'

    # 15.10 网关路径大小写敏感（保留大小写，大小写不同即跨网关）
    $pathCaseSnapshot = Test-WriteSnapshot 'pathcase.json' (New-SnapshotText -BaseUrl 'https://gw.example.com/Gateway')
    $pathCaseResult = Read-PriceSnapshot -Path $pathCaseSnapshot -EffectiveBaseUrl 'https://gw.example.com/gateway'
    Tst-False $pathCaseResult.usable 'snapshot path case mismatch: rejected (case-sensitive path compare)'
    $pathCaseOkPath = Test-WriteSnapshot 'pathcase-ok.json' (New-SnapshotText -BaseUrl 'https://gw.example.com/Gateway')
    $pathCaseOkResult = Read-PriceSnapshot -Path $pathCaseOkPath -EffectiveBaseUrl 'https://gw.example.com/Gateway'
    Tst-True $pathCaseOkResult.usable 'snapshot path case equal: accepted'

    # 15.11 来源端点缺失
    $noEndpointsPath = Test-WriteSnapshot 'noendpoints.json' (New-SnapshotText -Endpoints 'null')
    $noEndpointsResult = Read-PriceSnapshot -Path $noEndpointsPath -EffectiveBaseUrl $effectiveBase
    Tst-Equal '快照来源端点缺失' $noEndpointsResult.reason 'snapshot endpoints null: reason'
    $emptyEndpointsPath = Test-WriteSnapshot 'emptyendpoints.json' (New-SnapshotText -Endpoints '[]')
    $emptyEndpointsResult = Read-PriceSnapshot -Path $emptyEndpointsPath -EffectiveBaseUrl $effectiveBase
    Tst-Equal '快照来源端点缺失' $emptyEndpointsResult.reason 'snapshot endpoints empty: reason'

    # 15.12 来源端点条目无效（url 空 / status 与 http_status 双缺）
    $badEntryPath = Test-WriteSnapshot 'badentry.json' (New-SnapshotText -Endpoints '[{ "url": "https://gw.example.com/api/v1/model-plaza" }]')
    $badEntryResult = Read-PriceSnapshot -Path $badEntryPath -EffectiveBaseUrl $effectiveBase
    Tst-Equal '快照来源端点无效' $badEntryResult.reason 'snapshot endpoint missing both status fields: reason'
    $noUrlEntryPath = Test-WriteSnapshot 'nourl.json' (New-SnapshotText -Endpoints '[{ "http_status": 200, "status": "ok" }]')
    $noUrlEntryResult = Read-PriceSnapshot -Path $noUrlEntryPath -EffectiveBaseUrl $effectiveBase
    Tst-Equal '快照来源端点无效' $noUrlEntryResult.reason 'snapshot endpoint missing url: reason'

    # 15.13 来源验证：URL 必须精确到模型广场端点（路径大小写敏感）
    $wrongSourceUrl = '[{ "url": "https://gw.example.com/api/v1/plaza-list", "http_status": 200, "status": "ok" }]'
    $wrongSourcePath = Test-WriteSnapshot 'wrongsource.json' (New-SnapshotText -Endpoints $wrongSourceUrl)
    $wrongSourceResult = Read-PriceSnapshot -Path $wrongSourcePath -EffectiveBaseUrl $effectiveBase
    Tst-True $wrongSourceResult.usable 'snapshot wrong endpoint url: snapshot itself usable'
    Tst-Equal 0 @($wrongSourceResult.validated_sources.Keys).Count 'snapshot wrong endpoint url: source not validated'
    $upperSourceUrl = '[{ "url": "https://gw.example.com/API/v1/model-plaza", "http_status": 200, "status": "ok" }]'
    $upperSourcePath = Test-WriteSnapshot 'uppersource.json' (New-SnapshotText -Endpoints $upperSourceUrl)
    $upperSourceResult = Read-PriceSnapshot -Path $upperSourcePath -EffectiveBaseUrl $effectiveBase
    Tst-Equal 0 @($upperSourceResult.validated_sources.Keys).Count 'snapshot endpoint path case mismatch: source not validated'

    # 15.14 来源验证：HTTP 成功 + 状态 ok 才有效
    $http404Url = '[{ "url": "https://gw.example.com/api/v1/model-plaza", "http_status": 404, "status": "ok" }]'
    $http404Path = Test-WriteSnapshot 'http404.json' (New-SnapshotText -Endpoints $http404Url)
    $http404Result = Read-PriceSnapshot -Path $http404Path -EffectiveBaseUrl $effectiveBase
    Tst-True $http404Result.usable 'snapshot http 404: snapshot usable (counts still computed)'
    Tst-Equal 0 @($http404Result.validated_sources.Keys).Count 'snapshot http 404: model-plaza source not validated'
    $statusErrorUrl = '[{ "url": "https://gw.example.com/api/v1/model-plaza", "http_status": 200, "status": "error" }]'
    $statusErrorPath = Test-WriteSnapshot 'statuserror.json' (New-SnapshotText -Endpoints $statusErrorUrl)
    $statusErrorResult = Read-PriceSnapshot -Path $statusErrorPath -EffectiveBaseUrl $effectiveBase
    Tst-Equal 0 @($statusErrorResult.validated_sources.Keys).Count 'snapshot status error: source not validated despite http 200'

    # 15.15 models 缺失
    $noModelsPath = Test-WriteSnapshot 'nomodels.json' (New-SnapshotText -Models 'null')
    $noModelsResult = Read-PriceSnapshot -Path $noModelsPath -EffectiveBaseUrl $effectiveBase
    Tst-Equal '快照 models 缺失' $noModelsResult.reason 'snapshot models null: reason'

    # 15.16 有效快照：来源验证 + 计数 + generated_at 归一化
    $validPath = Test-WriteSnapshot 'valid.json' (New-SnapshotText)
    $validResult = Read-PriceSnapshot -Path $validPath -EffectiveBaseUrl $effectiveBase
    Tst-True $validResult.usable 'snapshot valid: usable'
    Tst-True $validResult.validated_sources.ContainsKey('model-plaza') 'snapshot valid: model-plaza source validated'
    Tst-Equal '2026-10-01T08:00:00Z' $validResult.generated_at 'snapshot valid: generated_at normalized'
    Tst-Equal 1 $validResult.counts['confirmed'] 'snapshot valid: confirmed count'
    Tst-Equal 1 $validResult.counts['unverified'] 'snapshot valid: unverified count'
    Tst-Equal 1 $validResult.counts['unknown'] 'snapshot valid: unknown count'
    Tst-Equal 3 $validResult.model_total 'snapshot valid: blank model_id skipped from total'

    # 15.17 精确模型 ID 匹配（大小写敏感 Ordinal）
    Tst-True $validResult.models.ContainsKey('GPT-X') 'snapshot model lookup: exact case found'
    Tst-False $validResult.models.ContainsKey('gpt-x') 'snapshot model lookup: different case not matched'
    Tst-False $validResult.models.ContainsKey('') 'snapshot model lookup: blank model_id not stored'

    # 15.18 重复 model_id 首条优先
    $dupModelsJson = @'
[
    { "model_id": "dup", "status": "unknown" },
    { "model_id": "dup", "status": "confirmed" }
]
'@
    $dupPath = Test-WriteSnapshot 'dup.json' (New-SnapshotText -Models $dupModelsJson)
    $dupResult = Read-PriceSnapshot -Path $dupPath -EffectiveBaseUrl $effectiveBase
    Tst-Equal 'unknown' ([string]$dupResult.models['dup'].status) 'snapshot duplicate model_id: first entry wins'
    Tst-Equal 2 $dupResult.model_total 'snapshot duplicate model_id: both counted in total'
} finally {
    Remove-Item -LiteralPath $snapshotDir -Recurse -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------
# 第 16 部分：端到端（子 PowerShell 进程 + AST 全文加载 + 桩注入）
# - 子进程屏蔽 SUB2API_* 环境变量，注入 Read-Settings 返回合成配置
# - 注入 Invoke-WebRequest 作为唯一网络出口：记录请求并返回合成 usage，绝不触网
# - 另注入 Invoke-RestMethod 守卫，业务若改用其他方式触网会立即失败
# - 合成 usage / 快照 / config 只写入随机 TEMP 目录，finally 清理
# - 业务脚本中的 exit 0 只退出子进程，父测试进程不受影响
# ---------------------------------------------------------------------
$e2eDir = New-TestDirectory
try {
    $e2eBase = 'https://gw.example.com/v1'

    # 合成配置（stub Read-Settings 实际不读它，写入仅为保持调用形态真实）
    $e2eConfigJson = @'
{
  "base_url": "https://gw.example.com/v1",
  "api_key": "sk-test-synthetic",
  "usage_path": "/v1/usage"
}
'@
    Write-TestFile (Join-Path $e2eDir 'config.json') $e2eConfigJson

    # 合成 usage 响应：含竖线/星号模型名，验证表格转义；req-model 覆盖按次价路径
    $e2eUsageJson = @'
{
  "isValid": true,
  "balance": 9.9441,
  "remaining": 9.9441,
  "unit": "USD",
  "mode": "unrestricted",
  "usage": {
    "average_duration_ms": 1234,
    "rpm": 5,
    "tpm": 5000,
    "today": { "requests": 2, "total_tokens": 1500, "actual_cost": 0.01 },
    "total": {
      "requests": 348,
      "total_tokens": 47300000,
      "actual_cost": 86.6508,
      "input_tokens": 8800000,
      "output_tokens": 315000,
      "cache_read_tokens": 38100000,
      "cache_creation_tokens": 0
    }
  },
  "model_stats": [
    { "model": "gpt-x-astra|weird*", "input_tokens": 3800000, "output_tokens": 144000, "cache_read_tokens": 10500000, "cache_creation_tokens": 0, "total_tokens": 14440000, "actual_cost": 75.16 },
    { "model": "req-model", "input_tokens": 0, "output_tokens": 0, "cache_read_tokens": 0, "cache_creation_tokens": 0, "total_tokens": 0, "actual_cost": 11.49 }
  ]
}
'@
    $e2eUsageFile = Join-Path $e2eDir 'usage.json'
    Write-TestFile $e2eUsageFile $e2eUsageJson

    # 合成价格快照：与 usage 同网关、来源端点成功、含 token 与 request 两种单价
    $e2eSnapshotJson = @'
{
  "schema_version": 1,
  "generated_at": "2026-10-01T08:00:00Z",
  "base_url": "https://gw.example.com/v1",
  "endpoints": [
    { "url": "https://gw.example.com/api/v1/model-plaza", "http_status": 200, "status": "ok" }
  ],
  "models": [
    { "model_id": "gpt-x-astra|weird*", "status": "confirmed", "prices": [ { "source": "model-plaza", "currency": "USD", "group": { "id": "g1", "name": "default" }, "pricing": { "billing_mode": "token", "input_price": 0.0000015, "output_price": 0.000006 }, "units": { "input_price": "USD/token", "output_price": "USD/token" } } ] },
    { "model_id": "req-model", "status": "confirmed", "prices": [ { "source": "model-plaza", "currency": "USD", "pricing": { "billing_mode": "request", "per_request_price": 0.02 }, "units": { "per_request_price": "USD/request" } } ] }
  ]
}
'@
    $e2eSnapshotFile = Join-Path $e2eDir 'model-prices.json'
    Write-TestFile $e2eSnapshotFile $e2eSnapshotJson

    # 子进程 runner：先加载业务函数，再注入桩，最后执行剔除函数定义后的顶层主逻辑
    $runnerTemplate = @'
# e2e 测试子进程：加载业务脚本 AST 全文，注入桩后运行主逻辑；绝不触网、不读真实配置。
param([string]$Mode, [string]$CapturePath)

$ErrorActionPreference = 'Stop'

# 屏蔽可能让脚本读到真实配置的环境变量（子进程内先移除）
Remove-Item Env:SUB2API_BASE_URL -ErrorAction SilentlyContinue
Remove-Item Env:SUB2API_API_KEY -ErrorAction SilentlyContinue

$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile('__SCRIPT_PATH__', [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw ('business script parse errors: ' + $parseErrors.Count) }

# 先加载业务脚本的全部顶层函数
foreach ($statement in $ast.EndBlock.Statements) {
    if ($statement -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
        Invoke-Expression $statement.Extent.Text
    }
}

# 注入桩：覆盖业务的 Read-Settings，返回合成配置（绝不读真实 config.json）
function Read-Settings {
    param([string]$Path)
    return [ordered]@{
        base_url = 'https://gw.example.com/v1'
        api_key = 'sk-test-synthetic'
        usage_path = '/v1/usage'
    }
}

# 注入桩：唯一网络出口；记录请求后返回合成 usage，绝不触网
$global:StubCalls = New-Object System.Collections.Generic.List[string]
function Invoke-WebRequest {
    param($Uri, $Headers, $Method, $TimeoutSec, [switch]$UseBasicParsing)
    $global:StubCalls.Add(([string]$Uri + "`t" + [string]$Headers['Authorization'] + "`t" + [string]$Headers['User-Agent']))
    if ($CapturePath) {
        try {
            [IO.File]::WriteAllLines($CapturePath, $global:StubCalls, (New-Object Text.UTF8Encoding($false)))
        } catch {
        }
    }
    if ($Mode -eq 'error') { throw 'MOCK-HTTP-ERROR-500' }
    return [pscustomobject]@{ Content = (Get-Content -LiteralPath '__USAGE_FILE__' -Raw) }
}

# 额外网络出口守卫：业务脚本若改用其他方式触网，测试立即失败
function Invoke-RestMethod { throw 'NETWORK BLOCKED: Invoke-RestMethod is not allowed in offline tests' }

# 显式绑定脚本参数（param 块未随 AST 加载执行）
$Config = '__CONFIG_FILE__'
$BaseUrl = ''
$ApiKey = ''
$UsagePath = ''
$ModelPrices = '__SNAPSHOT_FILE__'
$SaveConfig = $false
$RawJson = $false
$Json = ($Mode -eq 'json')

# 执行业务脚本顶层主逻辑（函数定义已单独加载，此处剔除以免覆盖桩）
$mainStatements = @($ast.EndBlock.Statements | Where-Object { $_ -isnot [System.Management.Automation.Language.FunctionDefinitionAst] })
$mainText = ($mainStatements | ForEach-Object { $_.Extent.Text }) -join "`r`n"
Invoke-Expression $mainText
'@

    $runnerPath = Join-Path $e2eDir 'e2e-runner.ps1'
    $runnerText = $runnerTemplate.Replace('__SCRIPT_PATH__', $script:ScriptPath).Replace('__CONFIG_FILE__', (Join-Path $e2eDir 'config.json')).Replace('__USAGE_FILE__', $e2eUsageFile).Replace('__SNAPSHOT_FILE__', $e2eSnapshotFile)
    # runner 含中文注释，写 UTF-8 BOM 保证 5.1 正确读取
    [IO.File]::WriteAllText($runnerPath, $runnerText, $script:UTF8Bom)

    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $psExe)) {
        Write-Output 'FATAL: Windows PowerShell 5.1 executable not found'
        exit 1
    }

    function Invoke-E2ERun {
        param([string]$Mode)
        $capturePath = Join-Path $e2eDir ('capture-{0}.txt' -f $Mode)
        $stdOutPath = Join-Path $e2eDir ('stdout-{0}.txt' -f $Mode)
        $stdErrPath = Join-Path $e2eDir ('stderr-{0}.txt' -f $Mode)
        $argString = '-NoProfile -ExecutionPolicy Bypass -File "{0}" {1} "{2}"' -f $runnerPath, $Mode, $capturePath
        $proc = Start-Process -FilePath $psExe -ArgumentList $argString -Wait -PassThru -NoNewWindow -RedirectStandardOutput $stdOutPath -RedirectStandardError $stdErrPath
        return @{
            ExitCode = $proc.ExitCode
            StdOut = [IO.File]::ReadAllText($stdOutPath, $script:UTF8NoBom)
            StdErr = [IO.File]::ReadAllText($stdErrPath, $script:UTF8NoBom)
            StdOutPath = $stdOutPath
            StdErrPath = $stdErrPath
            CapturePath = $capturePath
        }
    }

    function Test-AssertCapture {
        param([hashtable]$Run, [string]$Label)
        Tst-True (Test-Path -LiteralPath $Run.CapturePath) ('e2e {0}: stub request was captured' -f $Label)
        if (-not (Test-Path -LiteralPath $Run.CapturePath)) { return }
        $captureText = ([IO.File]::ReadAllText($Run.CapturePath, $script:UTF8NoBom)).Trim()
        $capturedLines = @($captureText -split "`r?`n" | Where-Object { $_.Trim().Length -gt 0 })
        Tst-Equal 1 $capturedLines.Count ('e2e {0}: exactly one stubbed request, no other network attempts' -f $Label)
        if ($capturedLines.Count -lt 1) { return }
        $parts = $capturedLines[0] -split "`t"
        Tst-Equal 'https://gw.example.com/v1/usage' $parts[0] ('e2e {0}: request URL is the synthetic /v1/usage endpoint' -f $Label)
        Tst-Equal 'Bearer sk-test-synthetic' $parts[1] ('e2e {0}: Authorization comes only from synthetic config' -f $Label)
        Tst-True ($parts[2] -match '^query-sub2api-usage/\d+\.\d+\.\d+$') ('e2e {0}: User-Agent carries semver version' -f $Label)
    }

    # ---- 16.1 Markdown 端到端 ----
    $mdRun = Invoke-E2ERun -Mode 'markdown'
    Tst-Equal 0 $mdRun.ExitCode 'e2e markdown: child process exits with 0'
    $mdLines = @($mdRun.StdOut -split "`r?`n" | ForEach-Object { $_.TrimEnd() })
    $nonEmptyLines = @($mdLines | Where-Object { $_.Trim().Length -gt 0 })
    Tst-True ($nonEmptyLines.Count -gt 0) 'e2e markdown: produced output'
    if ($nonEmptyLines.Count -gt 0) {
        Tst-Equal '配额模式：无 Key 级限制(unrestricted)' $nonEmptyLines[0] 'e2e markdown: quota mode is the first line, before recharge'
    }

    $mdBar = ([string][char]0x2588) * 2 + ([string][char]0x2591) * 18
    $mdExpectations = @(
        @{ Name = 'e2e markdown: recharge line'; Expected = '充值额度：$96.5949 USD' },
        # 业务脚本第 566 行格式串为双引号字符串，`` 被 PowerShell 转义为单个反引号，
        # 实际输出是单反引号代码段（与 SKILL.md 示例的双反引号排版存在外观差异，已记录为观察项）
        @{ Name = 'e2e markdown: balance line with progress bar and percent'; Expected = ('剩余余额：$9.9441 USD · `{0}` **10.29%**' -f $mdBar) },
        @{ Name = 'e2e markdown: total spend line'; Expected = '累计花费：$86.6508 USD' },
        @{ Name = 'e2e markdown: today table row'; Expected = '| 今日 | 2 | 1.5K | $0.01 |' },
        @{ Name = 'e2e markdown: total usage table row'; Expected = '| 累计 | **348** | **47.3M** | **$86.65** |' },
        @{ Name = 'e2e markdown: model row with token price and escaped name'; Expected = '| gpt-x-astra&#124;weird\* | $1.5 / $6 | 3.8M / 144K | 10.5M / 0 | 14.4M | 73.43 | $75.16 |' },
        @{ Name = 'e2e markdown: request-priced model row'; Expected = '| req-model | $0.02/次 | 0 / 0 | 0 / 0 | 0 | 0.00 | $11.49 |' },
        @{ Name = 'e2e markdown: grand total row computed from totals'; Expected = '| **合计** | **—** | **8.8M / 315K** | **38.1M / 0** | **47.3M** | **81.24** | **$86.65** |' },
        @{ Name = 'e2e markdown: snapshot footer with verdict counts'; Expected = '价格快照：2026-10-01T08:00:00Z（UTC，非实时）；本表已确认 2、待核实 0、未知 0。' },
        @{ Name = 'e2e markdown: price disclaimer footnote'; Expected = '单价：输入/输出，USD/百万 Token；按次价为 USD/次。仅为公开分组价，不代表当前 Key 实付价；花费仍采用 actual_cost。' }
    )
    foreach ($expectation in $mdExpectations) {
        Tst-True (@($mdLines | Where-Object { $_ -ceq $expectation.Expected }).Count -gt 0) $expectation.Name
    }
    Tst-NotContainsText $mdRun.StdOut '条件及分组详情' 'e2e markdown: no conditional detail line for simple prices'
    Tst-NotContainsText $mdRun.StdOut '单价未知' 'e2e markdown: snapshot accepted, no unknown-price fallback'
    Tst-NotContainsText $mdRun.StdOut 'sk-' 'e2e markdown: no api key leaked in report'
    Test-AssertCapture $mdRun 'markdown'

    # ---- 16.2 JSON 端到端 ----
    $jsonRun = Invoke-E2ERun -Mode 'json'
    Tst-Equal 0 $jsonRun.ExitCode 'e2e json: child exits 0 via script exit statement without killing parent'
    $jsonOut = $jsonRun.StdOut.Trim() | ConvertFrom-Json
    Tst-Equal 'sub2api-usage/1' ([string]$jsonOut.schema) 'e2e json: schema constant'
    Tst-Equal 'unrestricted' ([string]$jsonOut.mode) 'e2e json: mode keeps raw english value'
    Tst-Equal 9.9441 ([double]$jsonOut.balance) 'e2e json: balance passthrough'
    Tst-Equal 'USD' ([string]$jsonOut.unit) 'e2e json: unit passthrough'
    Tst-Equal 5 ([int]$jsonOut.rpm) 'e2e json: rpm passthrough'
    Tst-Equal 2 ([int]$jsonOut.today.requests) 'e2e json: today object passthrough'
    Tst-Equal 86.6508 ([double]$jsonOut.total.actual_cost) 'e2e json: total actual_cost passthrough'
    Tst-Equal 2 @($jsonOut.model_stats).Count 'e2e json: model_stats passthrough'
    Tst-False (@($jsonOut.PSObject.Properties.Name) -contains 'api_key') 'e2e json: no api_key property in summary'
    Tst-NotContainsText $jsonRun.StdOut 'sk-' 'e2e json: no api key leaked in stdout'
    Test-AssertCapture $jsonRun 'json'

    # ---- 16.3 网络失败端到端（桩抛错 → 非零退出码，错误信息不含密钥） ----
    $errRun = Invoke-E2ERun -Mode 'error'
    Tst-True ($errRun.ExitCode -ne 0) 'e2e error: query failure surfaces as non-zero child exit code'
    Tst-ContainsText $errRun.StdErr 'MOCK-HTTP-ERROR-500' 'e2e error: stubbed failure message surfaced'
    Tst-NotContainsText $errRun.StdOut 'sk-test-synthetic' 'e2e error: no api key leaked on failure'
    Test-AssertCapture $errRun 'error'
} finally {
    Remove-Item -LiteralPath $e2eDir -Recurse -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------
# 汇总输出：简洁测试数；失败时列出细节；退出码非 0 表示失败
# ---------------------------------------------------------------------
$totalCount = $script:PassCount + $script:FailCount
Write-Output ''
if ($script:FailCount -gt 0) {
    Write-Output ('PASSED: {0}  FAILED: {1}  TOTAL: {2}' -f $script:PassCount, $script:FailCount, $totalCount)
    foreach ($detail in $script:FailureDetails) {
        Write-Output $detail
    }
    exit 1
}
Write-Output ('PASSED: {0}  FAILED: {1}  TOTAL: {2}' -f $script:PassCount, $script:FailCount, $totalCount)
exit 0
