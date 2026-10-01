[CmdletBinding()]
param(
    [string]$Config = "$HOME/.config/opencode/skills/query-sub2api-usage/config.json",
    [string]$BaseUrl,
    [string]$ApiKey,
    [string]$UsagePath,
    [string]$ModelPrices = "$HOME/.config/opencode/skills/sync-openai-mm-models/data/model-prices.json",
    [switch]$SaveConfig,
    [switch]$RawJson,
    [Alias('Quiet')]
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
$OutputEncoding = [Console]::OutputEncoding

$script:ScriptVersion = '1.5.3'

function Read-Settings {
    param([string]$Path)

    $settings = [ordered]@{
        base_url = ''
        api_key = ''
        usage_path = '/v1/usage'
    }
    if (Test-Path -LiteralPath $Path) {
        $fileSettings = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        foreach ($name in @('base_url', 'api_key', 'usage_path')) {
            if ($null -ne $fileSettings.$name) {
                $settings[$name] = [string]$fileSettings.$name
            }
        }
    }
    return $settings
}

function Prompt-RequiredValue {
    param(
        [string]$Prompt,
        [switch]$Secret
    )
    if ($Secret) {
        $secure = Read-Host -Prompt $Prompt -AsSecureString
        $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try {
            return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
        } finally {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
        }
    }
    return (Read-Host -Prompt $Prompt)
}

function Write-Settings {
    param(
        [string]$Path,
        [string]$Base,
        [string]$Key,
        [string]$UsagePath
    )

    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $content = [ordered]@{
        base_url = $Base
        api_key = $Key
        usage_path = $UsagePath
    } | ConvertTo-Json
    [IO.File]::WriteAllText($Path, $content + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
}

function Get-UsageUrl {
    param(
        [string]$Base,
        [string]$Path
    )
    $normalizedBase = $Base.Trim().TrimEnd('/')
    $normalizedPath = '/' + $Path.Trim().TrimStart('/')
    if ($normalizedBase.EndsWith('/v1', [StringComparison]::OrdinalIgnoreCase) -and $normalizedPath.StartsWith('/v1/', [StringComparison]::OrdinalIgnoreCase)) {
        $normalizedPath = $normalizedPath.Substring(3)
    }
    return $normalizedBase + $normalizedPath
}

function Get-Number {
    param($Object, [string]$Name)
    $value = $Object.$Name
    if ($null -eq $value) { return $null }
    return [double]$value
}

function Format-QuotaMode {
    param([AllowNull()][string]$Mode)
    if ([string]::IsNullOrWhiteSpace($Mode)) { return '未提供' }
    switch -CaseSensitive ($Mode) {
        'unrestricted' { return '无 Key 级限制(unrestricted)' }
        'quota_limited' { return 'Key 限额/限速(quota_limited)' }
        default { return "未知模式($Mode)" }
    }
}

function Format-CompactNumber {
    param($Value)
    $number = if ($null -eq $Value) { 0.0 } else { [double]$Value }
    $absolute = [math]::Abs($number)
    foreach ($unit in @(
        @{ Divisor = 1000000000.0; Suffix = 'B' },
        @{ Divisor = 1000000.0; Suffix = 'M' },
        @{ Divisor = 1000.0; Suffix = 'K' }
    )) {
        if ($absolute -ge $unit.Divisor) {
            $scaled = $number / $unit.Divisor
            $digits = if ([math]::Abs($scaled) -ge 100) { 0 } else { 1 }
            return $scaled.ToString("F$digits", [Globalization.CultureInfo]::InvariantCulture) + $unit.Suffix
        }
    }
    return ([math]::Truncate($number)).ToString([Globalization.CultureInfo]::InvariantCulture)
}

function Format-Money {
    param($Value, [string]$Unit, [int]$Decimals = 2)
    $number = if ($null -eq $Value) { 0.0 } else { [double]$Value }
    $amount = $number.ToString("F$Decimals", [Globalization.CultureInfo]::InvariantCulture)
    switch ($Unit.ToUpperInvariant()) {
        'USD' { return '$' + $amount }
        'CNY' { return '¥' + $amount }
        default { return $amount }
    }
}

function Get-CacheHitRate {
    param($InputTokens, $CacheReadTokens)
    $inputValue = if ($null -eq $InputTokens) { 0.0 } else { [double]$InputTokens }
    $cacheValue = if ($null -eq $CacheReadTokens) { 0.0 } else { [double]$CacheReadTokens }
    $denominator = $inputValue + $cacheValue
    if ($denominator -le 0) { return 0.0 }
    return 100.0 * $cacheValue / $denominator
}

function Escape-MarkdownCell {
    param([AllowNull()][string]$Value)
    if ($null -eq $Value) { return '' }
    $text = $Value -replace "`r`n", ' ' -replace "`n", ' ' -replace "`r", ' '
    return $text.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('`', '&#96;').Replace('|', '&#124;').Replace('*', '\*').Replace('_', '\_').Replace('[', '\[').Replace(']', '\]')
}

function Escape-MarkdownCode {
    param([AllowNull()][string]$Value)
    if ($null -eq $Value) { return '' }
    $text = $Value -replace "`r`n", ' ' -replace "`n", ' ' -replace "`r", ' '
    return $text.Replace('`', "'")
}

function Get-NormalizedBaseUrl {
    param([AllowNull()][string]$Value)
    if ($null -eq $Value) { return '' }
    $uri = $null
    if (-not [Uri]::TryCreate($Value.Trim(), [UriKind]::Absolute, [ref]$uri)) { return '' }
    if ($uri.Scheme -notin @('https', 'http') -or $uri.UserInfo -or $uri.Query -or $uri.Fragment) { return '' }
    $path = $uri.AbsolutePath.TrimEnd('/') -replace '(?i)/v1$', ''
    return ($uri.Scheme.ToLowerInvariant() + '://' + $uri.Authority.ToLowerInvariant() + $path.TrimEnd('/'))
}

function ConvertTo-PriceNumber {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [bool]) { return $null }
    $parsed = 0.0
    if (-not [double]::TryParse([string]$Value, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) { return $null }
    if ($parsed -lt 0 -or [double]::IsNaN($parsed) -or [double]::IsInfinity($parsed)) { return $null }
    return $parsed
}

function Format-UnitAmount {
    param($Value, [string]$Currency)
    $number = [double]$Value
    $text = $number.ToString('0.############', [Globalization.CultureInfo]::InvariantCulture)
    if ($number -ne 0.0) {
        $roundTrip = 0.0
        if ([double]::TryParse($text, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$roundTrip) -and $roundTrip -eq 0.0) {
            $text = $number.ToString('G6', [Globalization.CultureInfo]::InvariantCulture)
        }
    }
    if ([string]::IsNullOrWhiteSpace($Currency)) { return $text }
    switch ($Currency.ToUpperInvariant()) {
        'USD' { return '$' + $text }
        'CNY' { return '¥' + $text }
        default { return ($text + ' ' + $Currency) }
    }
}

function Test-PriceUnit {
    param($Units, [string]$Name, [string]$Expected)
    if ($null -eq $Units) { return $false }
    $value = [string]$Units.$Name
    if ([string]::IsNullOrWhiteSpace($value)) { return $false }
    return ($value.Trim() -ieq $Expected)
}

function Test-MultiplierCondition {
    param($Value)
    if ($null -eq $Value) { return $false }
    if ($Value -is [bool]) { return [bool]$Value }
    if ($Value -is [string] -and [string]::IsNullOrWhiteSpace($Value)) { return $false }
    if ($Value -is [string] -or $Value -is [ValueType]) {
        $parsed = 0.0
        if ([double]::TryParse([string]$Value, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) {
            return ($parsed -ne 1.0)
        }
        return $true
    }
    return $true
}

function Test-ConditionActive {
    param($Value)
    if ($null -eq $Value) { return $false }
    if ($Value -is [bool]) { return [bool]$Value }
    if ($Value -is [string]) { return (-not [string]::IsNullOrWhiteSpace($Value)) }
    if ($Value -is [System.Collections.IDictionary]) { return ($Value.Count -gt 0) }
    if ($Value -is [System.Management.Automation.PSCustomObject]) { return (@($Value.PSObject.Properties).Count -gt 0) }
    return (@($Value).Count -gt 0)
}

function Test-ConditionalPrice {
    param($Price)
    if ($null -eq $Price) { return $false }
    $pricing = $Price.pricing
    if ($null -eq $pricing) { return $false }
    if (Test-ConditionActive -Value $pricing.intervals) { return $true }
    if (Test-ConditionActive -Value $pricing.reasoning_effort_multipliers) { return $true }
    if (Test-ConditionActive -Value $Price.time_pricing) { return $true }
    if (Test-ConditionActive -Value $Price.long_context_basis) { return $true }
    # 不把混合 Token、按次及图像计费压缩成单一输入/输出价。
    $mode = [string]$pricing.billing_mode
    $extraFields = if ($mode -eq 'request') { @('input_price', 'output_price', 'image_input_price', 'image_output_price') } else { @('per_request_price', 'request_price', 'image_input_price', 'image_output_price') }
    foreach ($field in $extraFields) { if ($null -ne $pricing.$field) { return $true } }
    if ($null -ne $Price.group) {
        foreach ($property in $Price.group.PSObject.Properties) {
            if ($property.Name -in @('id', 'name')) { continue }
            if ($Price.group.peak_rate_enabled -is [bool] -and -not $Price.group.peak_rate_enabled -and $property.Name -match '^peak_') { continue }
            if ($property.Name -notmatch '(?i)multiplier|multipliers|rate|ratio|peak|discount|倍率') { continue }
            if (Test-MultiplierCondition -Value $property.Value) { return $true }
        }
    }
    return $false
}

function Get-SimpleTokenPriceText {
    param($Price, [string]$Currency)
    $pricing = $Price.pricing
    $inputPrice = ConvertTo-PriceNumber $pricing.input_price
    $outputPrice = ConvertTo-PriceNumber $pricing.output_price
    if ($null -eq $inputPrice -or $null -eq $outputPrice) { return $null }
    if ($inputPrice -lt 0.0 -or $outputPrice -lt 0.0) { return $null }
    if (-not (Test-PriceUnit -Units $Price.units -Name 'input_price' -Expected 'USD/token')) { return $null }
    if (-not (Test-PriceUnit -Units $Price.units -Name 'output_price' -Expected 'USD/token')) { return $null }
    $scaledInput = ConvertTo-PriceNumber ($inputPrice * 1000000.0)
    $scaledOutput = ConvertTo-PriceNumber ($outputPrice * 1000000.0)
    if ($null -eq $scaledInput -or $null -eq $scaledOutput) { return $null }
    $inText = Format-UnitAmount $scaledInput $Currency
    $outText = Format-UnitAmount $scaledOutput $Currency
    return ($inText + ' / ' + $outText)
}

function Get-SimpleRequestPriceText {
    param($Price, [string]$Currency)
    $pricing = $Price.pricing
    foreach ($candidate in @(
        @{ Field = 'per_request_price'; Unit = 'per_request_price' },
        @{ Field = 'request_price'; Unit = 'request_price' }
    )) {
        $value = ConvertTo-PriceNumber $pricing.($candidate.Field)
        if ($null -eq $value) { continue }
        if ($value -lt 0.0) { continue }
        if (-not (Test-PriceUnit -Units $Price.units -Name $candidate.Unit -Expected 'USD/request')) { continue }
        return ((Format-UnitAmount $value $Currency) + '/次')
    }
    return $null
}

function Resolve-ModelUnitPrice {
    param($Entry, $ValidatedSources)
    $unknown = [pscustomobject]@{ text = '未知'; verdict = 'unknown' }
    $unverified = [pscustomobject]@{ text = '待核实'; verdict = 'unverified' }
    $multiGroup = [pscustomobject]@{ text = '多分组价（见快照）'; verdict = 'confirmed' }
    $conditional = [pscustomobject]@{ text = '条件价（见快照）'; verdict = 'confirmed' }
    if ($null -eq $Entry) { return $unknown }

    $status = ([string]$Entry.status).Trim().ToLowerInvariant()
    if ($status -eq '' -or $status -eq 'unknown') { return $unknown }
    if ($status -eq 'unverified') { return $unverified }
    if ($status -ne 'confirmed') { return $unknown }

    $prices = @()
    if ($null -ne $Entry.prices) { $prices = @($Entry.prices | Where-Object { $null -ne $_ }) }
    if ($prices.Count -eq 0) { return $unverified }

    foreach ($price in $prices) {
        $source = ([string]$price.source).Trim()
        if ($source -cne 'model-plaza') { return $unverified }
        if ($null -eq $ValidatedSources -or -not $ValidatedSources.ContainsKey($source)) { return $unverified }
        if ([string]$price.currency -ine 'USD') { return $unverified }
    }

    $groupIds = @($prices | ForEach-Object { if ($null -ne $_.group -and -not [string]::IsNullOrWhiteSpace([string]$_.group.id)) { [string]$_.group.id } else { '' } } | Sort-Object -Unique)
    if ($prices.Count -gt 1 -and $groupIds.Count -gt 1) { return $multiGroup }
    if ($prices.Count -gt 1) { return $conditional }

    $price = $prices[0]
    if (Test-ConditionalPrice -Price $price) { return $conditional }
    $pricing = $price.pricing
    if ($null -eq $pricing) { return $unverified }

    $currency = [string]$price.currency
    $billingMode = ([string]$pricing.billing_mode).Trim().ToLowerInvariant()
    if ($billingMode -ne '' -and $billingMode -ne 'token' -and $billingMode -ne 'request') { return $conditional }

    $tokenText = Get-SimpleTokenPriceText -Price $price -Currency $currency
    if ($billingMode -eq 'token') {
        if ($tokenText) { return [pscustomobject]@{ text = $tokenText; verdict = 'confirmed' } }
        return $unverified
    }
    $requestText = Get-SimpleRequestPriceText -Price $price -Currency $currency
    if ($billingMode -eq 'request') {
        if ($requestText) { return [pscustomobject]@{ text = $requestText; verdict = 'confirmed' } }
        return $unverified
    }
    if ($tokenText) { return [pscustomobject]@{ text = $tokenText; verdict = 'confirmed' } }
    if ($requestText) { return [pscustomobject]@{ text = $requestText; verdict = 'confirmed' } }
    return $unverified
}

function Read-PriceSnapshot {
    param(
        [string]$Path,
        [string]$EffectiveBaseUrl
    )

    $result = [ordered]@{
        usable = $false
        reason = ''
        path = $Path
        base_url = ''
        generated_at = ''
        model_total = 0
        counts = [ordered]@{ confirmed = 0; unverified = 0; unknown = 0 }
        validated_sources = ([System.Collections.Hashtable]::new([System.StringComparer]::OrdinalIgnoreCase))
        models = ([System.Collections.Hashtable]::new([System.StringComparer]::Ordinal))
    }

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        $result.reason = '快照文件缺失'
        return [pscustomobject]$result
    }

    try {
        $text = [IO.File]::ReadAllText($Path, (New-Object Text.UTF8Encoding($false)))
        $snapshot = $text | ConvertFrom-Json
    } catch {
        $result.reason = '快照解析失败'
        return [pscustomobject]$result
    }
    if ($null -eq $snapshot) {
        $result.reason = '快照内容为空'
        return [pscustomobject]$result
    }

    $schemaVersion = $null
    if ($null -ne $snapshot.schema_version) {
        $parsedSchema = 0.0
        if ([double]::TryParse([string]$snapshot.schema_version, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$parsedSchema)) {
            $schemaVersion = $parsedSchema
        }
    }
    if ($null -eq $schemaVersion -or $schemaVersion -ne 1.0) {
        $result.reason = '快照 schema_version 无效'
        return [pscustomobject]$result
    }

    $generatedAt = ''
    $parsedTime = [datetimeoffset]::MinValue
    if (-not [string]::IsNullOrWhiteSpace([string]$snapshot.generated_at) -and
        [datetimeoffset]::TryParse([string]$snapshot.generated_at, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsedTime)) {
        $generatedAt = $parsedTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture)
    }
    if (-not $generatedAt) {
        $result.reason = '快照 generated_at 无效'
        return [pscustomobject]$result
    }
    $result.generated_at = $generatedAt

    $snapshotBase = [string]$snapshot.base_url
    $result.base_url = $snapshotBase
    if ([string]::IsNullOrWhiteSpace($snapshotBase)) {
        $result.reason = '快照 base_url 缺失'
        return [pscustomobject]$result
    }
    $normalizedSnapshot = Get-NormalizedBaseUrl $snapshotBase
    $normalizedEffective = Get-NormalizedBaseUrl $EffectiveBaseUrl
    if (-not $normalizedEffective -or $normalizedSnapshot -cne $normalizedEffective) {
        $result.reason = '快照 base_url 与当前端点不一致'
        return [pscustomobject]$result
    }

    if ($null -eq $snapshot.endpoints) {
        $result.reason = '快照来源端点缺失'
        return [pscustomobject]$result
    }
    $endpoints = @($snapshot.endpoints)
    if ($endpoints.Count -eq 0) {
        $result.reason = '快照来源端点缺失'
        return [pscustomobject]$result
    }
    foreach ($endpoint in $endpoints) {
        if ($null -eq $endpoint) { $result.reason = '快照来源端点无效'; return [pscustomobject]$result }
        if ([string]::IsNullOrWhiteSpace([string]$endpoint.url)) { $result.reason = '快照来源端点无效'; return [pscustomobject]$result }
        if ($null -eq $endpoint.http_status -and [string]::IsNullOrWhiteSpace([string]$endpoint.status)) { $result.reason = '快照来源端点无效'; return [pscustomobject]$result }
    }

    $sourcePaths = [ordered]@{
        'model-plaza' = '/api/v1/model-plaza'
    }
    $validatedSources = [System.Collections.Hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($sourceName in $sourcePaths.Keys) {
        $expectedUrl = $normalizedSnapshot + $sourcePaths[$sourceName]
        foreach ($endpoint in $endpoints) {
            if ($null -eq $endpoint) { continue }
            $endpointUrl = Get-NormalizedBaseUrl ([string]$endpoint.url)
            if ($endpointUrl -cne $expectedUrl) { continue }
            $statusOk = ([string]$endpoint.status).Trim().ToLowerInvariant() -eq 'ok'
            $httpOk = $false
            if ($null -ne $endpoint.http_status) {
                $httpValue = 0.0
                if ([double]::TryParse([string]$endpoint.http_status, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$httpValue)) {
                    $httpOk = ($httpValue -ge 200.0 -and $httpValue -lt 300.0)
                }
            }
            if ($httpOk -and $statusOk) { $validatedSources[$sourceName] = $true }
            break
        }
    }
    $result.validated_sources = $validatedSources

    if ($null -eq $snapshot.models) {
        $result.reason = '快照 models 缺失'
        return [pscustomobject]$result
    }

    $counts = [ordered]@{ confirmed = 0; unverified = 0; unknown = 0 }
    $modelCount = 0
    foreach ($model in @($snapshot.models)) {
        if ($null -eq $model) { continue }
        $modelId = [string]$model.model_id
        if ([string]::IsNullOrWhiteSpace($modelId)) { continue }
        $modelCount++
        if (-not $result.models.ContainsKey($modelId)) { $result.models[$modelId] = $model }
        $status = ([string]$model.status).Trim().ToLowerInvariant()
        if ($status -eq 'confirmed') { $counts['confirmed']++ }
        elseif ($status -eq 'unverified') { $counts['unverified']++ }
        else { $counts['unknown']++ }
    }
    $result.counts = $counts
    $result.model_total = $modelCount
    $result.usable = $true
    return [pscustomobject]$result
}

$settings = Read-Settings -Path $Config
$effectiveBaseUrl = if ($BaseUrl) { $BaseUrl } elseif ($env:SUB2API_BASE_URL) { $env:SUB2API_BASE_URL } else { $settings.base_url }
$effectiveApiKey = if ($ApiKey) { $ApiKey } elseif ($env:SUB2API_API_KEY) { $env:SUB2API_API_KEY } else { $settings.api_key }
$effectiveUsagePath = if ($UsagePath) { $UsagePath } elseif ($settings.usage_path) { $settings.usage_path } else { '/v1/usage' }
$promptedForConfiguration = $false

if ([string]::IsNullOrWhiteSpace($effectiveBaseUrl)) {
    $effectiveBaseUrl = Prompt-RequiredValue -Prompt '请输入 Sub2API API 根地址，例如 https://example.com 或 https://example.com/v1'
    $promptedForConfiguration = $true
}
if ([string]::IsNullOrWhiteSpace($effectiveApiKey)) {
    $effectiveApiKey = Prompt-RequiredValue -Prompt '请输入 Sub2API API key（稍后可选择是否永久保存）' -Secret
    $promptedForConfiguration = $true
}
if ([string]::IsNullOrWhiteSpace($effectiveBaseUrl) -or [string]::IsNullOrWhiteSpace($effectiveApiKey)) {
    throw 'base_url 和 api_key 都不能为空。'
}

if ($promptedForConfiguration -and -not $SaveConfig) {
    $persist = Read-Host -Prompt '是否将当前配置写入配置文件（写入即永久配置）？[y/N]'
    $SaveConfig = $persist -match '^(?i:y|yes|是)$'
}
if ($SaveConfig) {
    Write-Settings -Path $Config -Base $effectiveBaseUrl.Trim() -Key $effectiveApiKey.Trim() -UsagePath $effectiveUsagePath
    if (-not $Json) {
        Write-Output "配置已写入: $Config"
    }
}

$url = Get-UsageUrl -Base $effectiveBaseUrl -Path $effectiveUsagePath
$headers = @{ Authorization = "Bearer $effectiveApiKey"; 'User-Agent' = "query-sub2api-usage/$script:ScriptVersion" }

try {
    $response = Invoke-WebRequest -Uri $url -Headers $headers -Method Get -TimeoutSec 30 -UseBasicParsing
    $usage = $response.Content | ConvertFrom-Json
} catch {
    $status = $null
    $body = ''
    if ($_.Exception.Response) {
        $status = [int]$_.Exception.Response.StatusCode
        try {
            $reader = New-Object IO.StreamReader($_.Exception.Response.GetResponseStream())
            $body = $reader.ReadToEnd()
        } catch {
            $body = ''
        }
    }
    $body = [regex]::Replace($body, 'sk-[A-Za-z0-9_-]+', '<redacted>')
    if ($body.Length -gt 500) { $body = $body.Substring(0, 500) }
    if ($status) { throw "查询失败 HTTP $status：$body" }
    throw "查询失败：$($_.Exception.Message)"
}

if ($RawJson) {
    $usage | ConvertTo-Json -Depth 20
    exit 0
}

$today = $usage.usage.today
$total = $usage.usage.total
$summary = [ordered]@{
    schema = 'sub2api-usage/1'
    valid = $usage.isValid
    balance = $usage.balance
    remaining = $usage.remaining
    unit = $usage.unit
    mode = $usage.mode
    average_duration_ms = $usage.usage.average_duration_ms
    rpm = $usage.usage.rpm
    tpm = $usage.usage.tpm
    today = $today
    total = $total
    model_stats = $usage.model_stats
}

if ($Json) {
    $summary | ConvertTo-Json -Depth 20
    exit 0
}

$unit = if ([string]::IsNullOrWhiteSpace([string]$usage.unit)) { 'USD' } else { [string]$usage.unit }
$displayUnit = Escape-MarkdownCell $unit
$balance = if ($null -eq $usage.balance) { 0.0 } else { [double]$usage.balance }
$actualCost = if ($null -eq $total.actual_cost) { 0.0 } else { [double]$total.actual_cost }
$recharge = $balance + $actualCost
$remainingPercent = if ($recharge -gt 0) { 100.0 * $balance / $recharge } else { 0.0 }
$remainingPercent = [math]::Max(0.0, [math]::Min(100.0, $remainingPercent))
$filled = [math]::Max(0, [math]::Min(20, [int][math]::Round(20.0 * $remainingPercent / 100.0, 0, [MidpointRounding]::AwayFromZero)))
$progress = ([string][char]0x2588) * $filled + ([string][char]0x2591) * (20 - $filled)
$percentText = $remainingPercent.ToString('F2', [Globalization.CultureInfo]::InvariantCulture)

Write-Output ("配额模式：{0}  " -f (Escape-MarkdownCell (Format-QuotaMode $usage.mode)))
Write-Output ("充值额度：{0} {1}  " -f (Format-Money $recharge $unit 4), $displayUnit)
Write-Output ("剩余余额：{0} {1} · ``{2}`` **{3}%**  " -f (Format-Money $balance $unit 4), $displayUnit, $progress, $percentText)
Write-Output ("累计花费：{0} {1}" -f (Format-Money $actualCost $unit 4), $displayUnit)
Write-Output ''
Write-Output '---'
Write-Output ''
Write-Output '**今日及累计用量**'
Write-Output ("| 时段 | 请求 | 用量 | 花费（{0}） |" -f $displayUnit)
Write-Output '|---|---:|---:|---:|'
$todayRequests = if ($null -eq $today.requests) { 0 } else { $today.requests }
$todayTokens = if ($null -eq $today.total_tokens) { 0 } else { $today.total_tokens }
$todayActualCost = if ($null -eq $today.actual_cost) { 0.0 } else { $today.actual_cost }
$totalRequests = if ($null -eq $total.requests) { 0 } else { $total.requests }
$totalTokens = if ($null -eq $total.total_tokens) { 0 } else { $total.total_tokens }
Write-Output ("| 今日 | {0} | {1} | {2} |" -f $todayRequests, (Format-CompactNumber $todayTokens), (Format-Money $todayActualCost $unit 2))
Write-Output ("| 累计 | **{0}** | **{1}** | **{2}** |" -f $totalRequests, (Format-CompactNumber $totalTokens), (Format-Money $actualCost $unit 2))
Write-Output ''
Write-Output '---'
Write-Output ''
Write-Output '**各模型累计用量与花费**'
Write-Output ("| 模型 | 单价 | 输入/输出 | 缓存读/写 | 总量 | 命中率（%） | 花费（{0}） |" -f $displayUnit)
Write-Output '|---|---:|---:|---:|---:|---:|---:|'

$snapshot = Read-PriceSnapshot -Path $ModelPrices -EffectiveBaseUrl $effectiveBaseUrl
$priceVerdicts = [ordered]@{ confirmed = 0; unverified = 0; unknown = 0 }
if ($usage.model_stats) {
    foreach ($model in @($usage.model_stats | Sort-Object { [double]$_.actual_cost } -Descending)) {
        $cacheRate = Get-CacheHitRate $model.input_tokens $model.cache_read_tokens
        $priceDisplay = '未知'
        $verdict = 'unknown'
        if ($snapshot.usable) {
            $priceEntry = $null
            $modelId = [string]$model.model
            if ($snapshot.models.ContainsKey($modelId)) { $priceEntry = $snapshot.models[$modelId] }
            $resolved = Resolve-ModelUnitPrice -Entry $priceEntry -ValidatedSources $snapshot.validated_sources
            $priceDisplay = $resolved.text
            $verdict = $resolved.verdict
        }
        $priceVerdicts[$verdict] = $priceVerdicts[$verdict] + 1
        Write-Output ("| {0} | {1} | {2} / {3} | {4} / {5} | {6} | {7} | {8} |" -f `
            (Escape-MarkdownCell ([string]$model.model)),
            (Escape-MarkdownCell $priceDisplay),
            (Format-CompactNumber $model.input_tokens),
            (Format-CompactNumber $model.output_tokens),
            (Format-CompactNumber $model.cache_read_tokens),
            (Format-CompactNumber $model.cache_creation_tokens),
            (Format-CompactNumber $model.total_tokens),
            $cacheRate.ToString('F2', [Globalization.CultureInfo]::InvariantCulture),
            (Format-Money $model.actual_cost $unit 2))
    }
}
$totalCacheRate = Get-CacheHitRate $total.input_tokens $total.cache_read_tokens
Write-Output ("| **合计** | **—** | **{0} / {1}** | **{2} / {3}** | **{4}** | **{5}** | **{6}** |" -f `
    (Format-CompactNumber $total.input_tokens),
    (Format-CompactNumber $total.output_tokens),
    (Format-CompactNumber $total.cache_read_tokens),
    (Format-CompactNumber $total.cache_creation_tokens),
    (Format-CompactNumber $total.total_tokens),
    $totalCacheRate.ToString('F2', [Globalization.CultureInfo]::InvariantCulture),
    (Format-Money $actualCost $unit 2))
Write-Output ''
if ($snapshot.usable) {
    Write-Output ("价格快照：{0}（UTC，非实时）；本表已确认 {1}、待核实 {2}、未知 {3}。  " -f (Escape-MarkdownCell $snapshot.generated_at), $priceVerdicts['confirmed'], $priceVerdicts['unverified'], $priceVerdicts['unknown'])
    Write-Output '单价：输入/输出，USD/百万 Token；按次价为 USD/次。仅为公开分组价，不代表当前 Key 实付价；花费仍采用 actual_cost。'
    if (@($snapshot.models.Values | Where-Object { @($_.prices).Count -gt 1 -or (@($_.prices).Count -eq 1 -and (Test-ConditionalPrice $_.prices[0])) }).Count -gt 0) {
        Write-Output ("条件及分组详情：``{0}``。" -f (Escape-MarkdownCode $snapshot.path))
    }
} else {
    Write-Output ("单价未知：{0}；模型用量与花费不受影响。" -f (Escape-MarkdownCell $snapshot.reason))
}
