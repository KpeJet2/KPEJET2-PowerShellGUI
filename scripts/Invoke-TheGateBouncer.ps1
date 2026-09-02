# VersionTag: 2608.B0.V53.0
# SupportPS5.1: true
# SupportsPS7.6: true
# FileRole: Pipeline Gate
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$WorkspacePath,
    [Parameter(Mandatory)]
    [string]$TargetPath,
    [ValidateSet('PreRemediation', 'PostRemediation')]
    [string]$Phase = 'PreRemediation',
    [switch]$AllowDetour,
    [string]$CodeSignatureThumbprint = '',
    [string]$SubagentHash = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$workspaceFull = [System.IO.Path]::GetFullPath($WorkspacePath)
$configPath = Join-Path (Join-Path $workspaceFull 'config') 'the-gate-bouncer.json'
if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { throw "TheGateBouncer config not found: $configPath" }
$config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
$targetFull = if ([System.IO.Path]::IsPathRooted($TargetPath)) { [System.IO.Path]::GetFullPath($TargetPath) } else { [System.IO.Path]::GetFullPath((Join-Path $workspaceFull $TargetPath)) }
$relative = $targetFull.Substring($workspaceFull.Length).TrimStart('\', '/') -replace '\\', '/'
$rootName = ($relative -split '/')[0]
$extension = [System.IO.Path]::GetExtension($targetFull).ToLowerInvariant()
$protected = @($config.protectedPathPatterns | Where-Object { $relative -match $_ }).Count -gt 0
$routeKnown = (@($config.allowedRouteRoots) -contains $rootName) -and (@($config.allowedExtensions) -contains $extension)
$manifestKnown = @($config.trustedManifestPaths | ForEach-Object { $_ -replace '\\', '/' }) -contains $relative
$signature = $null
$signatureValid = $false
if ((Get-Command Get-AuthenticodeSignature -ErrorAction SilentlyContinue) -and (Test-Path -LiteralPath $targetFull -PathType Leaf) -and $extension -in @('.ps1', '.psm1', '.psd1', '.exe', '.dll')) {
    try {
        $signature = Get-AuthenticodeSignature -FilePath $targetFull -ErrorAction Stop
        $signatureValid = ($signature.Status -eq 'Valid' -and ([string]::IsNullOrWhiteSpace($CodeSignatureThumbprint) -or $signature.SignerCertificate.Thumbprint -eq $CodeSignatureThumbprint))
    }
    catch { $signatureValid = $false }
}
$hashValid = -not [string]::IsNullOrWhiteSpace($SubagentHash)
$relaxedNotice = ($config.validationMode -eq 'RELAXED_WITH_NOTICE')
$detourRequested = [bool]($AllowDetour -or $config.allowDetour)
$detourAllowed = [bool]($detourRequested -and $routeKnown -and -not $protected -and ($manifestKnown -or $relaxedNotice) -and (-not [bool]$config.requireCodeSignature -or $signatureValid) -and (-not [bool]$config.requireSubagentHash -or $hashValid))
$reason = if ($protected) { 'PROTECTED_PATH_KERNEL_OR_CACHE' } elseif (-not $routeKnown) { 'UNKNOWN_OR_UNBOUNDED_ROUTE' } elseif (-not $detourRequested) { 'DETOUR_NOT_REQUESTED' } elseif (-not $manifestKnown -and -not $relaxedNotice) { 'ROUTE_NOT_MANIFEST_TRUSTED' } else { 'SAFE_BOUNDED_ROUTE' }
Write-Host ("[TheGateBouncer][$Phase] target={0} validation={1} detour={2} reason={3}" -f $relative, $config.validationMode, $detourAllowed, $reason) -ForegroundColor $(if ($detourAllowed) { 'Yellow' } else { 'Red' })
if ($relaxedNotice) { Write-Host '[TheGateBouncer] NOTICE: relaxed validation enabled; route, extension, and protected-path checks remain mandatory.' -ForegroundColor Yellow }
[pscustomobject][ordered]@{
    gate                    = 'TheGateBouncer'
    phase                   = $Phase
    target                  = $relative
    validationMode          = [string]$config.validationMode
    relaxedValidationNotice = $relaxedNotice
    routeKnown              = $routeKnown
    manifestKnown           = $manifestKnown
    protectedPath           = $protected
    signatureRequired       = [bool]$config.requireCodeSignature
    signatureValid          = $signatureValid
    subagentHashRequired    = [bool]$config.requireSubagentHash
    subagentHashValid       = $hashValid
    detourRequested         = $detourRequested
    detourAllowed           = $detourAllowed
    reason                  = $reason
}
