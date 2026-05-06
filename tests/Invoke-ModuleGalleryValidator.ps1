# VersionTag: 2604.B2.V31.3
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
#Requires -Version 5.1
<#
.SYNOPSIS
    Module Gallery Validator — tests workspace modules for accessibility across contexts,
    PSRepositories, and PowerShell versions (PS5.1 and PS7.6).
.DESCRIPTION
    Enumerates all *.psm1 and *.psd1 files under the Modules directory, then for each module:
      1. Manifest validity (Test-ModuleManifest or file existence)
      2. PSModulePath resolution (Get-Module -ListAvailable)
      3. LOCAL repository search (Find-Module -Repository LOCAL)
      4. PSGallery search (Find-Module -Repository PSGallery with 10s guard)
      5. User-context import (Import-Module -Force -PassThru)
      6. Background/system-context import (Start-Job isolation)
      7. PS5.1 accessibility (powershell.exe subprocess)
      8. PS7.6 accessibility (pwsh subprocess)
    Produces a formatted console report, cross-comparison table, and JSON output to
    temp/module-gallery-validation-<timestamp>.json.
.PARAMETER WorkspacePath
    Root of the PowerShellGUI workspace. Default: parent of script directory.
.PARAMETER TestPS51
    Run PS5.1 subprocess test per module. Default: $true.
.PARAMETER TestPS7
    Run PS7.x subprocess test per module. Default: $true.
.PARAMETER TestSystemContext
    Run background job (system-context simulation) test. Default: $true.
.PARAMETER TestGallery
    Run PSGallery online search per module (requires internet). Default: $false.
.PARAMETER OutputJson
    Path for JSON results. Default: <WorkspacePath>\temp\module-gallery-validation-<timestamp>.json.
.PARAMETER Quiet
    Suppress per-module progress lines.
#>
[CmdletBinding()]
param(
    [string]$WorkspacePath    = (Split-Path -Parent $PSScriptRoot),
    [switch]$TestPS51,
    [switch]$TestPS7,
    [switch]$TestSystemContext,
    [switch]$TestGallery,
    [string]$OutputJson       = '',
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'
$sw = [System.Diagnostics.Stopwatch]::StartNew()

# ---- Helpers ---------------------------------------------------------------
$stamp    = Get-Date -Format 'yyyyMMddHHmmss'
$logLines = [System.Collections.Generic.List[string]]::new()

function Write-Log {  # SIN-EXEMPT: P011 - cross-file duplicate (intentional fallback/stub)
    param([string]$Msg, [string]$Color = 'Gray')
    $logLines.Add($Msg)
    if (-not $Quiet) { Write-Host $Msg -ForegroundColor $Color }
}

function Write-Banner {  # SIN-EXEMPT: P011 - cross-file duplicate (intentional fallback/stub)
    param([string]$Text, [string]$Color = 'Cyan')
    $line = '=' * 70
    Write-Log $line $Color
    Write-Log "  $Text" $Color
    Write-Log $line $Color
}

function Write-Section {
    param([string]$Text)
    Write-Log ''
    Write-Log ('-' * 60) 'DarkCyan'
    Write-Log "  $Text" 'White'
    Write-Log ('-' * 60) 'DarkCyan'
}

# Icon states
$iOK   = 'OK'
$iWARN = 'WARN'
$iFAIL = 'FAIL'
$iSKIP = 'SKIP'
$iNONE = 'NONE'

function Test-IsNullOrWhiteSpace([string]$s) { [string]::IsNullOrWhiteSpace($s) }

# ---- Resolve key paths -----------------------------------------------------
$modulesDir = Join-Path $WorkspacePath 'modules'
$tempDir    = Join-Path $WorkspacePath 'temp'
if (-not (Test-Path $modulesDir)) {
    Write-Log "[ERROR] modules/ directory not found: $modulesDir" 'Red'; exit 1
}
if (-not (Test-Path $tempDir)) { $null = New-Item -ItemType Directory -Path $tempDir -Force }
if (Test-IsNullOrWhiteSpace $OutputJson) {
    $OutputJson = Join-Path $tempDir "module-gallery-validation-$stamp.json"
}

# ---- Detect pwsh executable ------------------------------------------------
$pwshExe = $null
foreach ($candidate in @('pwsh', 'pwsh.exe', 'C:\Program Files\PowerShell\7\pwsh.exe')) {
    try {
        $v = & $candidate --version 2>$null
        if ($v -match 'PowerShell 7') { $pwshExe = $candidate; break }
    } catch {
        <# Intentional: candidate may not be installed or not callable in this session. #>
    }
}

# ---- Detect PS5.1 executable -----------------------------------------------
$ps51Exe = 'powershell.exe'

# ---- Resolve PSRepositories ------------------------------------------------
$repos = @()
try {
    $repos = @(Get-PSRepository -ErrorAction SilentlyContinue)
} catch { $repos = @() }

$localRepo  = $repos | Where-Object { $_.Name -eq 'LOCAL' }
$galleryRepo = $repos | Where-Object { $_.Name -eq 'PSGallery' }

# ---- Collect workspace modules ---------------------------------------------
$psm1Files = @(Get-ChildItem -Path $modulesDir -Filter '*.psm1' -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notlike '_TEMPLATE*' })
$psd1Map = @{}
foreach ($psd in (Get-ChildItem -Path $modulesDir -Filter '*.psd1' -File -ErrorAction SilentlyContinue)) {
    $psd1Map[$psd.BaseName] = $psd.FullName
}

# Build canonical module list: one entry per module name
$moduleNames = [System.Collections.Generic.List[string]]::new()
$moduleMap   = @{}
foreach ($psm1 in $psm1Files) {
    $name = $psm1.BaseName
    if (-not $moduleMap.ContainsKey($name)) {
        $moduleMap[$name] = @{
            Name    = $name
            Psm1    = $psm1.FullName
            Psd1    = if ($psd1Map.ContainsKey($name)) { $psd1Map[$name] } else { $null }
            HasPsd1 = $psd1Map.ContainsKey($name)
        }
        $null = $moduleNames.Add($name)
    }
}

# ---- Print header ----------------------------------------------------------
Write-Banner "MODULE GALLERY VALIDATOR   [$stamp]"
Write-Log "Workspace : $WorkspacePath"
Write-Log "Modules   : $($moduleNames.Count) discovered in $modulesDir"
Write-Log "PS5.1 exe : $ps51Exe"
Write-Log "PS7 exe   : $(if ($null -ne $pwshExe) { $pwshExe } else { 'NOT FOUND' })"
$localStatus = if ($null -ne $localRepo) { "Trusted=$($localRepo.Trusted)  Source=$($localRepo.SourceLocation)" } else { 'NOT REGISTERED' }
Write-Log "LOCAL repo: $localStatus"
$galleryStatus = if ($null -ne $galleryRepo) { "Trusted=$($galleryRepo.Trusted)" } else { 'NOT REGISTERED' }
Write-Log "PSGallery : $galleryStatus"
Write-Log ''

# ---- Main validation loop --------------------------------------------------
$results = [System.Collections.Generic.List[object]]::new()

foreach ($name in $moduleNames) {
    $mod     = $moduleMap[$name]
    $psm1    = $mod.Psm1
    $psd1    = $mod.Psd1
    $hasPsd1 = $mod.HasPsd1

    if (-not $Quiet) { Write-Log "  Testing: $name ..." 'DarkGray' }

    $r = [ordered]@{
        ModuleName        = $name
        HasPsm1           = $true
        HasPsd1           = $hasPsd1
        ManifestValid     = $iSKIP
        ManifestVersion   = ''
        ManifestError     = ''
        PSModulePath      = $iNONE
        LocalGallery      = $iNONE
        PSGallery         = $iSKIP
        UserImport        = $iNONE
        UserImportCmds    = 0
        SystemJob         = $iSKIP
        PS51Test          = $iSKIP
        PS51Cmds          = 0
        PS7Test           = $iSKIP
        PS7Cmds           = 0
        Issues            = [System.Collections.Generic.List[string]]::new()
        Verdict           = 'UNKNOWN'
    }

    # 1. Manifest validity
    if ($hasPsd1) {
        try {
            $manifestData = Import-PowerShellDataFile -LiteralPath $psd1 -ErrorAction Stop
            $r.ManifestValid   = $iOK
            $r.ManifestVersion = if ($null -ne $manifestData -and $manifestData.ContainsKey('ModuleVersion')) {
                "$($manifestData['ModuleVersion'])" } else { 'unknown' }
        } catch {
            $r.ManifestValid  = $iFAIL
            $r.ManifestError  = "$_"
            $r.Issues.Add("Manifest parse failed: $_")
        }
    } else {
        $r.ManifestValid = $iSKIP
        $r.Issues.Add('No .psd1 manifest — module relies on direct .psm1 import only')
    }

    # 2. PSModulePath resolution
    try {
        $avail = @(Get-Module -ListAvailable -Name $name -ErrorAction SilentlyContinue)
        if (@($avail).Count -gt 0) {
            $r.PSModulePath = $iOK
        } else {
            $moduleDir = Join-Path $modulesDir $name
            $anyInDir  = Test-Path $moduleDir
            if (-not $anyInDir) {
                $r.PSModulePath = $iNONE
                $r.Issues.Add('Not in PSModulePath (flat-layout module without subfolder; needs module subfolder for auto-discovery)')
            } else {
                $r.PSModulePath = $iWARN
                $r.Issues.Add('Module subfolder exists but not visible via Get-Module -ListAvailable (missing .psd1 or name mismatch)')
            }
        }
    } catch {
        $r.PSModulePath = $iFAIL
        $r.Issues.Add("PSModulePath check threw: $_")
    }

    # 3. LOCAL repository search
    if ($null -ne $localRepo) {
        try {
            $found = @(Find-Module -Name $name -Repository 'LOCAL' -ErrorAction SilentlyContinue)
            $r.LocalGallery = if (@($found).Count -gt 0) { $iOK } else { $iNONE }
        } catch {
            $r.LocalGallery = $iFAIL
        }
    } else {
        $r.LocalGallery = $iSKIP
    }

    # 4. PSGallery search (optional, off by default)
    if ($TestGallery -and $null -ne $galleryRepo) {
        try {
            $job = Start-Job { Find-Module -Name $using:name -Repository 'PSGallery' -ErrorAction SilentlyContinue }
            $null = Wait-Job $job -Timeout 12
            if ($job.State -eq 'Completed') {
                $found = @(Receive-Job $job -ErrorAction SilentlyContinue)
                $r.PSGallery = if (@($found).Count -gt 0) { $iOK } else { $iNONE }
            } else {
                $r.PSGallery = $iWARN
                Stop-Job $job -ErrorAction SilentlyContinue
            }
            Remove-Job $job -Force -ErrorAction SilentlyContinue
        } catch { $r.PSGallery = $iFAIL }
    }

    # 5. User-context import (in this session)
    $loadPath = if ($hasPsd1) { $psd1 } else { $psm1 }
    try {
        Remove-Module -Name $name -Force -ErrorAction SilentlyContinue
        $imported = Import-Module -Name $loadPath -Force -PassThru -ErrorAction Stop
        if ($null -ne $imported) {
            $r.UserImport = $iOK
            $cmds = @($imported.ExportedCommands.Keys)
            $r.UserImportCmds = @($cmds).Count
        } else {
            $r.UserImport = $iWARN
            $r.Issues.Add('Import-Module returned $null (no exported commands?)')
        }
        Remove-Module -Name $name -Force -ErrorAction SilentlyContinue
    } catch {
        $r.UserImport = $iFAIL
        $r.Issues.Add("User import failed: $_")
    }

    # 6. Background job (system-context simulation)
    if ($TestSystemContext) {
        try {
            $job = Start-Job -ScriptBlock {
                param($path, $modName)
                try {
                    Import-Module $path -Force -ErrorAction Stop
                    $m = Get-Module -Name $modName
                    if ($null -ne $m) { @($m.ExportedCommands.Keys).Count } else { -1 }
                } catch { "ERR:$_" }
            } -ArgumentList $loadPath,$name
            $null = Wait-Job $job -Timeout 30
            if ($job.State -eq 'Completed') {
                $raw = Receive-Job $job -ErrorAction SilentlyContinue
                if ("$raw" -match '^ERR:') {
                    $r.SystemJob = $iFAIL
                    $r.Issues.Add("System-job import failed: $($raw -replace '^ERR:','')")
                } elseif ("$raw" -eq '-1') {
                    $r.SystemJob = $iWARN
                    $r.Issues.Add('System-job: imported but module not found via Get-Module')
                } else {
                    $r.SystemJob = $iOK
                }
            } else {
                $r.SystemJob = $iWARN
                $r.Issues.Add('System-job timed out after 30s')
                Stop-Job $job -ErrorAction SilentlyContinue
            }
            Remove-Job $job -Force -ErrorAction SilentlyContinue
        } catch {
            $r.SystemJob = $iFAIL
            $r.Issues.Add("System-job threw: $_")
        }
    }

    # 7. PS5.1 subprocess test
    if ($TestPS51) {
        try {
            $escapedPath = $loadPath -replace "'","''"
            $cmd = "Set-StrictMode -Off; try { Import-Module '$escapedPath' -Force -ErrorAction Stop; `$m = Get-Module -Name '$name'; if (`$null -ne `$m) { `$m.ExportedCommands.Count } else { -1 } } catch { 'ERR:' + `$_.Exception.Message }"
            $raw = & $ps51Exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command $cmd 2>&1
            $rawStr = ("$raw").Trim()
            $errRecs = @($raw | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] })
            if ($rawStr -match '^ERR:' -or @($errRecs).Count -gt 0) {
                $r.PS51Test = $iFAIL
                $detail = if ($rawStr -match '^ERR:') { $rawStr } else { "$($errRecs[0])" }
                $r.Issues.Add("PS5.1 import failed: $detail")
            } elseif ($rawStr -eq '-1') {
                $r.PS51Test = $iWARN
            } else {
                $r.PS51Test = $iOK
                $count = 0
                if ([int]::TryParse($rawStr, [ref]$count)) { $r.PS51Cmds = $count }
            }
        } catch {
            $r.PS51Test = $iFAIL
            $r.Issues.Add("PS5.1 subprocess threw: $_")
        }
    }

    # 8. PS7 subprocess test
    if ($TestPS7) {
        if ($null -ne $pwshExe) {
            try {
                $escapedPath = $loadPath -replace "'","''"
                $cmd = "Set-StrictMode -Off; try { Import-Module '$escapedPath' -Force -ErrorAction Stop; `$m = Get-Module -Name '$name'; if (`$null -ne `$m) { `$m.ExportedCommands.Count } else { -1 } } catch { 'ERR:' + `$_.Exception.Message }"
                $raw = & $pwshExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command $cmd 2>&1
                $rawStr = ("$raw").Trim()
                $errRecs = @($raw | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] })
                if ($rawStr -match '^ERR:' -or @($errRecs).Count -gt 0) {
                    $r.PS7Test = $iFAIL
                    $detail = if ($rawStr -match '^ERR:') { $rawStr } else { "$($errRecs[0])" }
                    $r.Issues.Add("PS7 import failed: $detail")
                } elseif ($rawStr -eq '-1') {
                    $r.PS7Test = $iWARN
                } else {
                    $r.PS7Test = $iOK
                    $count = 0
                    if ([int]::TryParse($rawStr, [ref]$count)) { $r.PS7Cmds = $count }
                }
            } catch {
                $r.PS7Test = $iFAIL
                $r.Issues.Add("PS7 subprocess threw: $_")
            }
        } else {
            $r.PS7Test = $iSKIP
            $r.Issues.Add('PS7 not found on this system (pwsh not in PATH)')
        }
    }

    # Determine overall verdict
    $critChecks = @($r.UserImport, $r.PS51Test) | Where-Object { $_ -eq $iFAIL }
    $warnChecks = @($r.UserImport, $r.PSModulePath, $r.ManifestValid) | Where-Object { $_ -in @($iWARN,$iFAIL,$iNONE) }
    $r.Verdict = if (@($critChecks).Count -gt 0) { 'FAIL' }
                 elseif (@($warnChecks).Count -gt 0) { 'WARN' }
                 elseif ($r.UserImport -eq $iOK) { 'OK' }
                 else { 'UNKNOWN' }

    $results.Add($r)
}

# ---- Summaries -------------------------------------------------------------
Write-Section 'PER-MODULE RESULTS'
$colW   = 30
$stateW = 6
$fmt = "{0,-$colW} {1,-8} {2,-8} {3,-$stateW} {4,-$stateW} {5,-$stateW} {6,-$stateW} {7,-$stateW} {8,-$stateW} {9,-$stateW} {10}"
Write-Log ($fmt -f 'Module','Version','Manifest','PSPath','LOCAL','UserImp','SysJob','PS51','PS7','Verdict','Issues') 'White'
Write-Log ($fmt -f ('-'*28),('-'*7),('-'*7),('-'*5),('-'*5),('-'*6),('-'*6),('-'*5),('-'*5),('-'*7),'') 'DarkGray'

foreach ($r in $results) {
    $ver   = if (Test-IsNullOrWhiteSpace $r.ManifestVersion) { 'n/a' } else { $r.ManifestVersion }
    $mnf   = $r.ManifestValid
    $color = switch ($r.Verdict) { 'OK' { 'Green' } 'WARN' { 'Yellow' } 'FAIL' { 'Red' } default { 'Gray' } }
    $issueStr = if (@($r.Issues).Count -gt 0) { "[$(@($r.Issues).Count) issues]" } else { '' }
    Write-Log ($fmt -f $r.ModuleName,$ver,$mnf,$r.PSModulePath,$r.LocalGallery,$r.UserImport,$r.SystemJob,$r.PS51Test,$r.PS7Test,$r.Verdict,$issueStr) $color
}

# ---- Issue Detail ----------------------------------------------------------
$withIssues = @($results | Where-Object { @($_.Issues).Count -gt 0 })
if (@($withIssues).Count -gt 0) {
    Write-Section 'ISSUE DETAIL'
    foreach ($r in $withIssues) {
        Write-Log "  [$($r.Verdict)] $($r.ModuleName)" $(if($r.Verdict -eq 'FAIL'){'Red'}elseif($r.Verdict -eq 'WARN'){'Yellow'}else{'Gray'})
        foreach ($issue in $r.Issues) {
            Write-Log "       - $issue" 'DarkYellow'
        }
    }
}

# ---- Cross-Comparison Summary Table ----------------------------------------
Write-Section 'CROSS-COMPARISON SUMMARY'

$okCount     = @($results | Where-Object { $_.Verdict -eq 'OK'   }).Count
$warnCount   = @($results | Where-Object { $_.Verdict -eq 'WARN' }).Count
$failCount   = @($results | Where-Object { $_.Verdict -eq 'FAIL' }).Count

$hasPsd1     = @($results | Where-Object { $_.HasPsd1 }).Count
$noPsd1      = @($results | Where-Object { -not $_.HasPsd1 }).Count
$inPSPath    = @($results | Where-Object { $_.PSModulePath -eq $iOK }).Count
$notInPSPath = @($results | Where-Object { $_.PSModulePath -ne $iOK }).Count
$inLocal     = @($results | Where-Object { $_.LocalGallery -eq $iOK }).Count
$notInLocal  = @($results | Where-Object { $_.LocalGallery -eq $iNONE }).Count
$userOK      = @($results | Where-Object { $_.UserImport -eq $iOK   }).Count
$userFail    = @($results | Where-Object { $_.UserImport -eq $iFAIL }).Count
$sysOK       = @($results | Where-Object { $_.SystemJob -eq $iOK    }).Count
$ps51OK      = @($results | Where-Object { $_.PS51Test -eq $iOK     }).Count
$ps51Fail    = @($results | Where-Object { $_.PS51Test -eq $iFAIL   }).Count
$ps7OK       = @($results | Where-Object { $_.PS7Test -eq $iOK      }).Count
$ps7Fail     = @($results | Where-Object { $_.PS7Test -eq $iFAIL    }).Count
$total       = @($results).Count

$fmtS = "{0,-42} {1,10} {2,10}"
Write-Log ($fmtS -f 'Metric','Count',"/ $total") 'White'
Write-Log ($fmtS -f ('-'*41),('-'*9),('-'*9)) 'DarkGray'
Write-Log ($fmtS -f 'Verdict — OK',$okCount,'') 'Green'
Write-Log ($fmtS -f 'Verdict — WARN',$warnCount,'') 'Yellow'
Write-Log ($fmtS -f 'Verdict — FAIL',$failCount,'') $(if($failCount -gt 0){'Red'}else{'Gray'})
Write-Log ''
Write-Log ($fmtS -f 'Has .psd1 manifest',$hasPsd1,'') 'Gray'
Write-Log ($fmtS -f 'Missing .psd1 (psm1-only)',$noPsd1,'') $(if($noPsd1 -gt 0){'Yellow'}else{'Gray'})
Write-Log ''
Write-Log ($fmtS -f 'In PSModulePath (Get-Module -ListAvailable)',$inPSPath,'') 'Gray'
Write-Log ($fmtS -f 'NOT in PSModulePath',$notInPSPath,'') $(if($notInPSPath -gt 0){'Yellow'}else{'Gray'})
Write-Log ''
Write-Log ($fmtS -f 'Published to LOCAL gallery',$inLocal,'') $(if($inLocal -gt 0){'Green'}else{'Yellow'})
Write-Log ($fmtS -f 'NOT published to LOCAL gallery',$notInLocal,'') 'DarkGray'
Write-Log ''
Write-Log ($fmtS -f 'User-context import OK',$userOK,'') 'Gray'
Write-Log ($fmtS -f 'User-context import FAIL',$userFail,'') $(if($userFail -gt 0){'Red'}else{'Gray'})
Write-Log ''
Write-Log ($fmtS -f 'Background-job (system-ctx) OK',$sysOK,'') 'Gray'
Write-Log ''
Write-Log ($fmtS -f 'PS5.1 subprocess import OK',$ps51OK,'') 'Gray'
Write-Log ($fmtS -f 'PS5.1 subprocess import FAIL',$ps51Fail,'') $(if($ps51Fail -gt 0){'Red'}else{'Gray'})
Write-Log ''
Write-Log ($fmtS -f 'PS7 subprocess import OK',$ps7OK,'') 'Gray'
Write-Log ($fmtS -f 'PS7 subprocess import FAIL',$ps7Fail,'') $(if($ps7Fail -gt 0){'Red'}else{'Gray'})

# ---- Repository accessibility summary --------------------------------------
Write-Section 'REPOSITORY STATUS'
$repoGallery = if ($null -ne $galleryRepo) { "REGISTERED  Trusted=$($galleryRepo.Trusted)  URL=$($galleryRepo.SourceLocation)" } else { 'NOT REGISTERED' }
$repoLocal   = if ($null -ne $localRepo)   { "REGISTERED  Trusted=$($localRepo.Trusted)  Path=$($localRepo.SourceLocation)" } else { 'NOT REGISTERED' }
Write-Log "  PSGallery   : $repoGallery" 'Gray'
Write-Log "  LOCAL       : $repoLocal" 'Gray'
$localDir  = Join-Path $modulesDir 'LOCAL'
$nupkgCnt  = if (Test-Path $localDir) { @(Get-ChildItem -Path $localDir -Filter '*.nupkg' -ErrorAction SilentlyContinue).Count } else { 0 }
$nuspecCnt = if (Test-Path $localDir) { @(Get-ChildItem -Path $localDir -Filter '*.nuspec' -ErrorAction SilentlyContinue).Count } else { 0 }
Write-Log "  LOCAL path  : $localDir" 'Gray'
Write-Log "  .nupkg files: $nupkgCnt  (.nuspec files: $nuspecCnt)" $(if($nupkgCnt -eq 0){'Yellow'}else{'Green'})
if ($nupkgCnt -eq 0) {
    Write-Log "  NOTE: LOCAL gallery is empty -- no modules are published as NuGet packages." 'Yellow'
    Write-Log "        Modules are accessible directly via PSModulePath (C:\PowerShellGUI\modules)" 'DarkYellow'
    Write-Log "        but cannot be installed via Install-Module -Repository LOCAL." 'DarkYellow'
}

# ---- Final summary ---------------------------------------------------------
$sw.Stop()
$elapsedSec  = [math]::Round($sw.Elapsed.TotalSeconds)
$sectionTitle = 'VALIDATION COMPLETE  (' + $elapsedSec + 's)'
Write-Section $sectionTitle
if ($failCount -gt 0) {
    Write-Log "  RESULT: $failCount module(s) FAILED import tests." 'Red'
} elseif ($warnCount -gt 0) {
    Write-Log "  RESULT: $warnCount module(s) have warnings (missing manifest or not in PSModulePath)." 'Yellow'
} else {
    Write-Log "  RESULT: All $total modules passed accessibility tests." 'Green'
}
Write-Log "  Output : $OutputJson" 'Gray'

# ---- JSON output -----------------------------------------------------------
$jsonResults = @($results | ForEach-Object {
    $copy = [ordered]@{}
    foreach ($k in $_.Keys) {
        $v = $_[$k]
        $copy[$k] = if ($v -is [System.Collections.Generic.List[string]]) { @($v) } else { $v }
    }
    $copy
})

$outputObj = [ordered]@{
    timestamp      = (Get-Date -Format 'o')
    workspacePath  = $WorkspacePath
    totalModules   = $total
    verdictOK      = $okCount
    verdictWARN    = $warnCount
    verdictFAIL    = $failCount
    hasPsd1        = $hasPsd1
    inPSModulePath = $inPSPath
    inLocalGallery = $inLocal
    ps51OK         = $ps51OK
    ps7OK          = $ps7OK
    userImportOK   = $userOK
    modules        = $jsonResults
}

try {
    $outputObj | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $OutputJson -Encoding UTF8 -Force
    if (-not $Quiet) { Write-Host "  [JSON] Written to $OutputJson" -ForegroundColor DarkGray }
} catch {
    Write-Host "[ERROR] Failed to write JSON: $_" -ForegroundColor Red
}

<# Outline:
    Stub: describe module/script purpose here.
#>

<# Problems:
    Stub: list known issues here.
#>

<# ToDo:
    Stub: list pending work here.
#>




