# VersionTag: 2604.B2.V1.2
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
<#
.SYNOPSIS
    Diagnoses, registers, and installs PowerShellGUI project modules for local use.

.DESCRIPTION
    Provides four operations:
      -Diagnose   : Scans execution policies, PSModulePath, repositories, manifests, and performs dual-pass load testing
      -Register   : Registers a LOCAL PSRepository pointing at the project modules folder
      -Install    : Copies project modules into a user or system module path for auto-discovery
      -Uninstall  : Removes installed module copies from the target path

.PARAMETER Action
    One of: Diagnose, Register, Install, Uninstall

.PARAMETER Scope
    Target scope for Install/Uninstall: CurrentUser (default) or AllUsers (requires elevation)

.PARAMETER WorkspacePath
    Root of the PowerShellGUI workspace. Defaults to grandparent of this script's directory.

.EXAMPLE
    .\Setup-ModuleEnvironment.ps1 -Action Diagnose
    .\Setup-ModuleEnvironment.ps1 -Action Register
    .\Setup-ModuleEnvironment.ps1 -Action Install -Scope CurrentUser
    .\Setup-ModuleEnvironment.ps1 -Action Uninstall -Scope CurrentUser
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Diagnose','Register','Install','Uninstall')]
    [string]$Action,

    [ValidateSet('CurrentUser','AllUsers')]
    [string]$Scope = 'CurrentUser',

    [string]$WorkspacePath = (Split-Path (Split-Path $PSScriptRoot -Parent) -ErrorAction SilentlyContinue)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $WorkspacePath -or -not (Test-Path $WorkspacePath)) {
    $WorkspacePath = 'C:\PowerShellGUI'
}
$modulesDir = Join-Path $WorkspacePath 'modules'
$logsDir    = Join-Path $WorkspacePath 'logs'

if (-not (Test-Path $logsDir)) { $null = New-Item -Path $logsDir -ItemType Directory -Force }

# ─── Logging ─────────────────────────────────────────────────────────
function Write-DiagLog {
    param([string]$Message, [string]$Level = 'INFO')
    $ts = Get-Date -Format 'HH:mm:ss.fff'
    $line = "[$ts][$Level] $Message"
    Write-Host $line -ForegroundColor $(switch ($Level) {
        'OK'    { 'Green'  }
        'WARN'  { 'Yellow' }
        'ERROR' { 'Red'    }
        'DEBUG' { 'DarkGray' }
        default { 'White'  }
    })
    return $line
}

# ═══════════════════════════════════════════════════════════════════════
#  ACTION: Diagnose
# ═══════════════════════════════════════════════════════════════════════
function Invoke-Diagnose {
    $logFile = Join-Path $logsDir "module-environment-diag-$(Get-Date -Format 'yyyyMMdd-HHmm').log"
    $log = [System.Collections.Generic.List[string]]::new()

    $log.Add("═══════════════════════════════════════════════════════════")
    $log.Add("  MODULE ENVIRONMENT DIAGNOSTIC")
    $log.Add("  Date:     $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    $log.Add("  PSVer:    $($PSVersionTable.PSVersion)")
    $log.Add("  Host:     $($Host.Name)")
    $log.Add("  OS:       $([System.Environment]::OSVersion.VersionString)")
    $log.Add("  User:     $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)")
    $log.Add("  Elevated: $(([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))")
    $log.Add("═══════════════════════════════════════════════════════════")
    $log | ForEach-Object { Write-Host $_ -ForegroundColor Cyan }

    # ── 1. Execution Policies ──
    Write-Host "`n── Execution Policies ──" -ForegroundColor Magenta
    $policies = Get-ExecutionPolicy -List
    foreach ($p in $policies) {
        $line = Write-DiagLog "  $($p.Scope.ToString().PadRight(15)) $($p.ExecutionPolicy)" -Level $(if($p.ExecutionPolicy -eq 'Restricted'){'WARN'}else{'INFO'})
        $log.Add($line)
    }

    # ── 2. PSModulePath ──
    Write-Host "`n── PSModulePath Entries ──" -ForegroundColor Magenta
    $paths = $env:PSModulePath -split ';'
    foreach ($p in $paths) {
        $exists = Test-Path $p
        $scope = if ($p -match [regex]::Escape($env:USERPROFILE)) { 'User' }
                 elseif ($p -match 'Program Files.*PowerShell') { 'AllUsers' }
                 elseif ($p -match 'system32') { 'System' }
                 elseif ($p -match 'PowerShellGUI') { 'Project' }
                 else { 'Other' }
        $level = if (-not $exists) { 'WARN' } elseif ($scope -eq 'Project') { 'OK' } else { 'INFO' }
        $line = Write-DiagLog "  [$scope] $p  (Exists: $exists)" -Level $level
        $log.Add($line)
    }

    $projectInPath = $paths -contains $modulesDir
    if ($projectInPath) {
        $log.Add((Write-DiagLog "  Project modules dir IS in PSModulePath" -Level 'OK'))
    } else {
        $log.Add((Write-DiagLog "  Project modules dir is NOT in PSModulePath" -Level 'WARN'))
    }

    # ── 3. Repositories ──
    Write-Host "`n── PS Repositories ──" -ForegroundColor Magenta
    $repos = Get-PSRepository -ErrorAction SilentlyContinue
    if (@($repos).Count -eq 0) {
        $log.Add((Write-DiagLog "  No repositories registered" -Level 'WARN'))
    } else {
        foreach ($r in $repos) {
            $line = Write-DiagLog "  $($r.Name.PadRight(15)) $($r.SourceLocation)  Policy=$($r.InstallationPolicy)  Trusted=$($r.Trusted)" -Level $(if($r.Trusted){'OK'}else{'WARN'})
            $log.Add($line)
        }
    }

    # ── 4. Module Manifests ──
    Write-Host "`n── Module Manifest Coverage ──" -ForegroundColor Magenta
    $psm1s = @(Get-ChildItem $modulesDir -Filter '*.psm1' | Where-Object { $_.Name -ne '_TEMPLATE-Module.psm1' })
    $psd1s = @(Get-ChildItem $modulesDir -Filter '*.psd1')
    $psd1Names = @($psd1s | ForEach-Object { $_.BaseName })
    $missing = @($psm1s | Where-Object { $_.BaseName -notin $psd1Names })

    $log.Add((Write-DiagLog "  Modules: $($psm1s.Count)  Manifests: $($psd1s.Count)  Missing: $($missing.Count)" -Level $(if($missing.Count -gt 0){'WARN'}else{'OK'})))
    foreach ($m in $missing) {
        $log.Add((Write-DiagLog "  MISSING manifest: $($m.BaseName)" -Level 'WARN'))
    }

    # ── 5. Dual-Pass Load Test ──
    Write-Host "`n── Load Test (Pass 1: cold, Pass 2: warm) ──" -ForegroundColor Magenta
    $results = @()
    foreach ($pass in 1..2) {
        foreach ($mod in ($psm1s | Sort-Object Name)) {
            Remove-Module $mod.BaseName -Force -ErrorAction SilentlyContinue
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            try {
                Import-Module $mod.FullName -Force -ErrorAction Stop
                $sw.Stop()
                $imported = Get-Module -Name $mod.BaseName -ErrorAction SilentlyContinue
                $funcs = if ($imported) { @($imported.ExportedFunctions.Keys).Count } else { 0 }
                $results += [PSCustomObject]@{ Pass=$pass; Module=$mod.BaseName; Status='OK'; Funcs=$funcs; Ms=$sw.ElapsedMilliseconds; Error='' }
            } catch {
                $sw.Stop()
                $results += [PSCustomObject]@{ Pass=$pass; Module=$mod.BaseName; Status='FAIL'; Funcs=0; Ms=$sw.ElapsedMilliseconds; Error=$_.Exception.Message -replace "`r?`n",' ' }
            }
        }
    }

    # Comparison output
    Write-Host "`n  Module                               P1(ms) P2(ms) Delta  Status" -ForegroundColor White
    Write-Host "  ────────────────────────────────────  ────── ────── ─────  ──────" -ForegroundColor DarkGray
    $moduleNames = @($results | Where-Object { $_.Pass -eq 1 } | ForEach-Object { $_.Module })
    foreach ($name in $moduleNames) {
        $p1 = $results | Where-Object { $_.Pass -eq 1 -and $_.Module -eq $name }
        $p2 = $results | Where-Object { $_.Pass -eq 2 -and $_.Module -eq $name }
        $delta = $p2.Ms - $p1.Ms
        $status = if ($p1.Status -eq 'OK' -and $p2.Status -eq 'OK') { 'OK' } else { 'FAIL' }
        $color = if ($status -eq 'OK') { 'Green' } else { 'Red' }
        $line = "  {0,-38} {1,6} {2,6} {3,5}  {4}" -f $name, $p1.Ms, $p2.Ms, $delta, $status
        Write-Host $line -ForegroundColor $color
        $log.Add($line)
    }

    $p1Total = ($results | Where-Object { $_.Pass -eq 1 } | Measure-Object -Property Ms -Sum).Sum
    $p2Total = ($results | Where-Object { $_.Pass -eq 2 } | Measure-Object -Property Ms -Sum).Sum
    $p1Fail  = @($results | Where-Object { $_.Pass -eq 1 -and $_.Status -eq 'FAIL' }).Count
    $p2Fail  = @($results | Where-Object { $_.Pass -eq 2 -and $_.Status -eq 'FAIL' }).Count

    Write-Host ""
    $log.Add((Write-DiagLog "  Pass 1: ${p1Total}ms total, $p1Fail failures" -Level $(if($p1Fail -gt 0){'ERROR'}else{'OK'})))
    $log.Add((Write-DiagLog "  Pass 2: ${p2Total}ms total, $p2Fail failures  (warm cache delta: $($p2Total - $p1Total)ms)" -Level $(if($p2Fail -gt 0){'ERROR'}else{'OK'})))

    # ── 6. Total exported functions ──
    $totalFuncs = ($results | Where-Object { $_.Pass -eq 2 -and $_.Status -eq 'OK' } | Measure-Object -Property Funcs -Sum).Sum
    $log.Add((Write-DiagLog "  Total exported functions: $totalFuncs across $($psm1s.Count) modules" -Level 'OK'))

    # Save log
    $log | Out-File -FilePath $logFile -Encoding UTF8
    Write-Host "`nDiagnostic log saved: $logFile" -ForegroundColor DarkGray
}

# ═══════════════════════════════════════════════════════════════════════
#  ACTION: Register
# ═══════════════════════════════════════════════════════════════════════
function Invoke-Register {
    $repoName = 'PwShGUI-Local'
    $publishDir = Join-Path $modulesDir 'Local'

    Write-DiagLog "Checking existing repositories..." -Level 'DEBUG'
    $existing = Get-PSRepository -ErrorAction SilentlyContinue

    # ── Ensure NuGet provider ──
    $nuget = Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue
    if (-not $nuget) {
        Write-DiagLog "Installing NuGet package provider..." -Level 'INFO'
        $null = Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser
        Write-DiagLog "NuGet provider installed" -Level 'OK'
    } else {
        Write-DiagLog "NuGet provider present: v$($nuget.Version)" -Level 'OK'
    }

    # ── Ensure publish directory ──
    if (-not (Test-Path $publishDir)) {
        $null = New-Item -Path $publishDir -ItemType Directory -Force
        Write-DiagLog "Created publish directory: $publishDir" -Level 'OK'
    }

    # ── Register or update repo ──
    $repo = $existing | Where-Object { $_.Name -eq $repoName }
    if ($repo) {
        Write-DiagLog "Repository '$repoName' already registered at $($repo.SourceLocation)" -Level 'OK'
        if (-not $repo.Trusted) {
            Set-PSRepository -Name $repoName -InstallationPolicy Trusted
            Write-DiagLog "Set '$repoName' to Trusted" -Level 'OK'
        }
    } else {
        Register-PSRepository -Name $repoName -SourceLocation $modulesDir -PublishLocation $publishDir -InstallationPolicy Trusted
        Write-DiagLog "Registered repository '$repoName' -> $modulesDir" -Level 'OK'
    }

    # ── Also ensure PSGallery is trusted ──
    $gallery = $existing | Where-Object { $_.Name -eq 'PSGallery' }
    if ($gallery -and -not $gallery.Trusted) {
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
        Write-DiagLog "Set PSGallery to Trusted" -Level 'OK'
    }

    # ── Report PSModulePath status ──
    $inPath = ($env:PSModulePath -split ';') -contains $modulesDir
    if ($inPath) {
        Write-DiagLog "Project modules dir already in PSModulePath" -Level 'OK'
    } else {
        Write-DiagLog "Project modules dir NOT in PSModulePath — adding for current session" -Level 'WARN'
        $env:PSModulePath = "$modulesDir;$env:PSModulePath"
        Write-DiagLog "Added to PSModulePath (session only). For permanent, add to user/system Environment Variables." -Level 'INFO'
    }

    # ── Summary ──
    Write-Host "`n── Registered Repositories ──" -ForegroundColor Cyan
    Get-PSRepository | Format-Table Name, SourceLocation, InstallationPolicy, Trusted -AutoSize

    Write-Host "── Module Paths (writable for installs) ──" -ForegroundColor Cyan
    $env:PSModulePath -split ';' | Where-Object { Test-Path $_ } | ForEach-Object {
        $scope = if ($_ -match [regex]::Escape($env:USERPROFILE)) { 'User' }
                 elseif ($_ -match 'Program Files') { 'AllUsers' }
                 elseif ($_ -match 'system32') { 'System' }
                 elseif ($_ -match 'PowerShellGUI') { 'Project' }
                 else { 'Other' }
        Write-Host "  [$scope] $_" -ForegroundColor $(if($scope -eq 'Project'){'Green'}else{'Gray'})
    }
}

# ═══════════════════════════════════════════════════════════════════════
#  ACTION: Install — Copy modules to a PSModulePath location
# ═══════════════════════════════════════════════════════════════════════
function Invoke-Install {
    # Determine target path
    $targetRoot = switch ($Scope) {
        'CurrentUser' {
            if ($PSVersionTable.PSVersion.Major -ge 6) {
                Join-Path $env:USERPROFILE (Join-Path 'OneDrive\Documents' (Join-Path 'PowerShell' 'Modules'))
            } else {
                Join-Path $env:USERPROFILE (Join-Path 'OneDrive\Documents' (Join-Path 'WindowsPowerShell' 'Modules'))
            }
        }
        'AllUsers' {
            $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
            if (-not $isAdmin) {
                Write-DiagLog "AllUsers scope requires elevation. Run as Administrator." -Level 'ERROR'
                return
            }
            if ($PSVersionTable.PSVersion.Major -ge 6) {
                Join-Path $env:ProgramFiles (Join-Path 'PowerShell' 'Modules')
            } else {
                Join-Path $env:ProgramFiles (Join-Path 'WindowsPowerShell' 'Modules')
            }
        }
    }

    if (-not (Test-Path $targetRoot)) {
        $null = New-Item -Path $targetRoot -ItemType Directory -Force
    }

    Write-DiagLog "Install target: $targetRoot  (Scope: $Scope)" -Level 'INFO'

    $psm1s = @(Get-ChildItem $modulesDir -Filter '*.psm1' | Where-Object { $_.Name -ne '_TEMPLATE-Module.psm1' })
    $installed = 0; $skipped = 0; $failed = 0

    foreach ($mod in $psm1s) {
        $modName = $mod.BaseName
        $targetDir = Join-Path $targetRoot $modName

        # Get version from manifest if available
        $psd1 = Join-Path $modulesDir "$modName.psd1"
        $version = '1.0.0'
        if (Test-Path $psd1) {
            try {
                $manifest = Import-PowerShellDataFile $psd1 -ErrorAction Stop
                if ($manifest.ModuleVersion) { $version = $manifest.ModuleVersion }
            } catch {
                Write-DiagLog "  Could not read manifest for $modName : $($_.Exception.Message)" -Level 'WARN'
            }
        }

        $versionDir = Join-Path $targetDir $version
        if (-not (Test-Path $versionDir)) {
            $null = New-Item -Path $versionDir -ItemType Directory -Force
        }

        try {
            # Copy .psm1 and .psd1
            Copy-Item $mod.FullName -Destination $versionDir -Force
            if (Test-Path $psd1) {
                Copy-Item $psd1 -Destination $versionDir -Force
            }
            Write-DiagLog "  Installed $modName v$version -> $versionDir" -Level 'OK'
            $installed++
        } catch {
            Write-DiagLog "  FAILED $modName : $($_.Exception.Message)" -Level 'ERROR'
            $failed++
        }
    }

    Write-DiagLog "`nInstall complete: $installed installed, $skipped skipped, $failed failed" -Level $(if($failed -gt 0){'WARN'}else{'OK'})
    Write-Host "`nModules are now auto-discoverable via:" -ForegroundColor Cyan
    Write-Host "  Get-Module -ListAvailable -Name PwShGUI*" -ForegroundColor White
    Write-Host "  Import-Module PwShGUICore  # no path needed" -ForegroundColor White
}

# ═══════════════════════════════════════════════════════════════════════
#  ACTION: Uninstall — Remove module copies from target path
# ═══════════════════════════════════════════════════════════════════════
function Invoke-Uninstall {
    $targetRoot = switch ($Scope) {
        'CurrentUser' {
            if ($PSVersionTable.PSVersion.Major -ge 6) {
                Join-Path $env:USERPROFILE (Join-Path 'OneDrive\Documents' (Join-Path 'PowerShell' 'Modules'))
            } else {
                Join-Path $env:USERPROFILE (Join-Path 'OneDrive\Documents' (Join-Path 'WindowsPowerShell' 'Modules'))
            }
        }
        'AllUsers' {
            $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
            if (-not $isAdmin) {
                Write-DiagLog "AllUsers scope requires elevation. Run as Administrator." -Level 'ERROR'
                return
            }
            if ($PSVersionTable.PSVersion.Major -ge 6) {
                Join-Path $env:ProgramFiles (Join-Path 'PowerShell' 'Modules')
            } else {
                Join-Path $env:ProgramFiles (Join-Path 'WindowsPowerShell' 'Modules')
            }
        }
    }

    Write-DiagLog "Uninstall target: $targetRoot  (Scope: $Scope)" -Level 'INFO'

    $psm1s = @(Get-ChildItem $modulesDir -Filter '*.psm1' | Where-Object { $_.Name -ne '_TEMPLATE-Module.psm1' })
    $removed = 0

    foreach ($mod in $psm1s) {
        $modName = $mod.BaseName
        $targetDir = Join-Path $targetRoot $modName
        if (Test-Path $targetDir) {
            # Unload first
            Remove-Module $modName -Force -ErrorAction SilentlyContinue
            Remove-Item $targetDir -Recurse -Force
            Write-DiagLog "  Removed $modName from $targetDir" -Level 'OK'
            $removed++
        }
    }

    Write-DiagLog "`nUninstall complete: $removed modules removed" -Level 'OK'
}

# ═══════════════════════════════════════════════════════════════════════
#  Dispatch
# ═══════════════════════════════════════════════════════════════════════
switch ($Action) {
    'Diagnose'  { Invoke-Diagnose }
    'Register'  { Invoke-Register }
    'Install'   { Invoke-Install }
    'Uninstall' { Invoke-Uninstall }
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




