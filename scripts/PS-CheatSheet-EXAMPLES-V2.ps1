# VersionTag: 2604.B2.V31.2
# SupportPS5.1: null
# SupportsPS7.6: null
# SupportPS5.1TestedDate: null
# SupportsPS7.6TestedDate: null
# VersionBuildHistory:
#   2603.B0.v19  2026-03-24 03:28  (deduplicated from 4 entries)
<#
.SYNOPSIS
    PowerShell Cheat Sheet V2 -- Expanded Reference & Examples

.DESCRIPTION
    An in-depth, runnable reference that builds on V1 and adds:
      - String manipulation
      - Arrays & array operations
      - Error handling (try/catch/finally, $Error, trap)
      - Pipeline deep-dive (ForEach-Object, Select-Object, Tee-Object)
      - Output methods (Write-*, Format-*, Out-*, Export-*)
      - JSON & XML handling
      - Environment variables
      - Date & Time
      - Jobs (background jobs + thread jobs)
      - Processes & services
      - Registry access
      - Network utilities
      - Credential handling
      - Script blocks & closures
      - Splatting
      - Calculated properties
      - Custom objects ([PSCustomObject])
      - Enums
      - Generics / strongly-typed collections
      - SecureString & credential objects
      - Scheduled tasks (brief)
      - File parsing (CSV, JSON, XML)
      - Module authoring skeleton
      - Pester unit testing skeleton
      - WinForms GUI (every form element demonstrated)

.NOTES
    File    : PS-CheatSheet-EXAMPLES-V2.ps1
    Version : 2604.B2.V31.0
    Date    : 2026-02-28
    Requires: PowerShell 7+

.EXAMPLE
    .\PS-CheatSheet-EXAMPLES-V2.ps1
#>

#Requires -Version 7.0

###################################################
# SECTION HELPER
###################################################

function Show-Section ([string]$Title) {  # SIN-EXEMPT: P011 - cross-file duplicate (intentional fallback/stub)
    Write-Host ""
    Write-Host ("=" * 70) -ForegroundColor Cyan
    Write-Host "  $Title" -ForegroundColor Yellow
    Write-Host ("=" * 70) -ForegroundColor Cyan
}

function Show-Example ([string]$Label, [scriptblock]$Code) {
    # Runs a script block and wraps its output with a descriptive label
    Write-Host "  >> $Label" -ForegroundColor Magenta
    & $Code
    Write-Host ""
}

###################################################
# OUTPUT METHOD SELECTION
###################################################
# Dynamically discover every export cmdlet available on this host.
# Out-HtmlView (PSWriteHTML) is treated as a special "live viewer" -- it opens
# the output directly in the default browser and is enabled by DEFAULT.

$script:OutputMethods = @(
    [PSCustomObject]@{ Id = 1; Name = 'TXT';   Ext = 'txt';  Cmdlet = 'Out-File';       Default = $false; Description = 'Plain text          (Out-File)' }
    [PSCustomObject]@{ Id = 2; Name = 'CSV';   Ext = 'csv';  Cmdlet = 'Export-Csv';     Default = $false; Description = 'CSV rows            (Export-Csv)' }
    [PSCustomObject]@{ Id = 3; Name = 'JSON';  Ext = 'json'; Cmdlet = 'ConvertTo-Json'; Default = $false; Description = 'JSON structured     (ConvertTo-Json)' }
    [PSCustomObject]@{ Id = 4; Name = 'XML';   Ext = 'xml';  Cmdlet = 'Export-CliXml';  Default = $false; Description = 'XML / CliXml        (Export-CliXml)' }
    [PSCustomObject]@{ Id = 5; Name = 'HTML';  Ext = 'html'; Cmdlet = 'ConvertTo-Html'; Default = $false; Description = 'HTML report         (ConvertTo-Html)' }
    [PSCustomObject]@{ Id = 6; Name = 'HTMLV'; Ext = '';     Cmdlet = 'Out-HtmlView';   Default = $true;  Description = 'Live browser viewer (Out-HtmlView)  [DEFAULT]' }
) | Where-Object { [bool](Get-Command $_.Cmdlet -ErrorAction SilentlyContinue) }

# Separate the live viewer from file-based methods
$script:HtmlViewMethod  = $script:OutputMethods | Where-Object { $_.Name -eq 'HTMLV' }
$script:FileMethods     = $script:OutputMethods | Where-Object { $_.Name -ne 'HTMLV' }

# $script:RunHtmlView -- true by default whenever Out-HtmlView is available
$script:RunHtmlView    = [bool]$script:HtmlViewMethod
$script:SelectedMethods = @()

# Section 23 (WinForms GUI) is OFF by default -- user must opt-in
$script:RunSection23  = $false

if ($script:OutputMethods.Count -eq 0) {
    Write-Warning "No export cmdlets found on $env:COMPUTERNAME -- running console-only."
}
elseif (Get-Command 'Out-GridView' -ErrorAction SilentlyContinue) {
    # --- Graphical multi-select (Windows / GraphicalTools available) ----------
    Write-Host ""
    Write-Host ("=" * 68) -ForegroundColor Cyan
    Write-Host "  OUTPUT FORMAT SELECTION  --  $env:COMPUTERNAME" -ForegroundColor Yellow
    Write-Host ("=" * 68) -ForegroundColor Cyan
    if ($script:HtmlViewMethod) {
        Write-Host "  Out-HtmlView is AVAILABLE -- results will open in your browser by default." -ForegroundColor Green
        Write-Host "  Deselect 'HTMLV' in the grid below to disable it." -ForegroundColor DarkGray
    }
    Write-Host "  Ctrl+click / Shift+click to choose file export format(s), then OK." -ForegroundColor White
    Write-Host ""

    $gridInput = $script:OutputMethods | Select-Object Id, Name, Ext, Default, Description

    # Append the Section 23 pseudo-option so it appears in the same grid
    $sec23Row  = [PSCustomObject]@{ Id = 23; Name = 'S23-GUI'; Ext = ''; Default = $false
                                    Description = 'Run Section 23 -- WinForms GUI demo  [opt-in]' }
    $gridInput = @($gridInput) + $sec23Row

    $selected  = $gridInput | Out-GridView -Title "PScheatsheet-Examples -- Select output format(s) + options" -PassThru

    # Resolve RunHtmlView from the grid result; strip HTMLV from file-export list
    if ($script:HtmlViewMethod) {
        $script:RunHtmlView = [bool]($selected | Where-Object { $_.Name -eq 'HTMLV' })
    }
    # Resolve Section 23 opt-in
    $script:RunSection23 = [bool]($selected | Where-Object { $_.Name -eq 'S23-GUI' })
    $script:SelectedMethods = $script:FileMethods |
        Where-Object { $m = $_; ($selected | Where-Object { $_.Id -eq $m.Id }) }
}
else {
    # --- Console fallback (headless / SSH / no GUI) --------------------------
    $w = 68
    Write-Host ""
    Write-Host ("=" * $w) -ForegroundColor Cyan
    Write-Host "  OUTPUT FORMAT SELECTION  --  $env:COMPUTERNAME" -ForegroundColor Yellow
    Write-Host ("=" * $w) -ForegroundColor Cyan
    Write-Host "  Formats available on this host:" -ForegroundColor White
    $script:OutputMethods | ForEach-Object {
        $colour = if ($_.Default) { 'Yellow' } else { 'Gray' }
        Write-Host ("    [{0}] {1,-5}  {2}" -f $_.Id, $_.Name, $_.Description) -ForegroundColor $colour
    }
    Write-Host ""
    if ($script:HtmlViewMethod) {
        Write-Host "  [6] HTMLV is DEFAULT -- console output will open in your browser." -ForegroundColor Green
    }
    Write-Host "  Enter file-export numbers separated by commas (e.g. 1,3,5)." -ForegroundColor White
    Write-Host "  Include 6 to keep HTMLV | omit 6 to disable | ENTER = HTMLV only:" -ForegroundColor White
    Write-Host "  Add 23 to also run Section 23 -- WinForms GUI demo (opt-in)." -ForegroundColor White
    $raw = Read-Host "  >"
    if ($raw.Trim() -eq '') {
        # ENTER pressed -- enable only defaults (HTMLV if available, no file exports)
        $script:SelectedMethods = @()
        # $script:RunHtmlView stays $true
    } else {
        $chosen = $raw -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^\d+$' }
        # If user listed numbers but did NOT include 6, disable HTMLV
        if ($script:HtmlViewMethod -and '6' -notin $chosen) {
            $script:RunHtmlView = $false
        }
        # Opt-in to Section 23
        if ('23' -in $chosen) { $script:RunSection23 = $true }
        $script:SelectedMethods = $script:FileMethods | Where-Object { "$($_.Id)" -in $chosen }
    }
}

# Resolve / create output directory (Report/ folder alongside scripts/)
$script:OutputDir = Join-Path (Split-Path $PSCommandPath -Parent) '..\Report'
if (-not (Test-Path $script:OutputDir)) {
    New-Item -ItemType Directory -Path $script:OutputDir -Force | Out-Null
}
$script:OutputDir = (Resolve-Path $script:OutputDir).Path

# Base filename: Hostname-YYYYMMDD-HHMMSS-PScheatsheet-Examples
$script:Hostname  = $env:COMPUTERNAME
$script:Timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$script:BaseName  = "$($script:Hostname)-$($script:Timestamp)-PScheatsheet-Examples"

# Start transcript -- captures everything written to the host/console from this point
$script:TranscriptPath = Join-Path $env:TEMP "$($script:BaseName)-transcript.txt"
Start-Transcript -Path $script:TranscriptPath -Force | Out-Null

###################################################
# 1. STRING MANIPULATION
#   Commands: Write-Host
###################################################
Show-Section "1. String Manipulation"

Show-Example "Basic string operations" {
    $s = "  Hello, PowerShell World!  "
    Write-Host "Original     : '$s'"
    Write-Host "Trimmed      : '$($s.Trim())'"
    Write-Host "ToUpper      : $($s.Trim().ToUpper())"
    Write-Host "ToLower      : $($s.Trim().ToLower())"
    Write-Host "Replace      : $($s.Trim().Replace('World','Universe'))"
    Write-Host "StartsWith H : $($s.Trim().StartsWith('H'))"
    Write-Host "Contains Pow : $($s.Contains('PowerShell'))"
    Write-Host "IndexOf ,    : $($s.Trim().IndexOf(','))"
    Write-Host "Substring 7  : $($s.Trim().Substring(7, 10))"
    Write-Host "Length       : $($s.Trim().Length)"
}

Show-Example "String formatting" {
    $name = 'Alice'; $score = 98.6
    # -f format operator -- positional placeholders
    Write-Host ("Name: {0,-10} Score: {1:F2}" -f $name, $score)
    # String interpolation
    Write-Host "Name: $name  Score: $score"
    # Here-string (multi-line)
    $block = @"
Line 1: $name
Line 2: Score = $score
"@
    Write-Host $block
}

Show-Example "Split and Join" {
    $csv  = "alpha,beta,gamma,delta"
    $arr  = $csv -split ','                # Split on delimiter
    Write-Host "Split  : $($arr -join ' | ')"
    $back = $arr -join '::'               # Join with different delimiter
    Write-Host "Joined : $back"
}

Show-Example "Regex replace and extract" {
    $text   = "My phone is 555-1234 and backup is 555-9876"
    $masked = $text -replace '\d{3}-\d{4}', '***-****'
    Write-Host "Masked phones : $masked"

    $allPhones = [regex]::Matches($text, '\d{3}-\d{4}') | ForEach-Object { $_.Value }
    Write-Host "Extracted     : $($allPhones -join ', ')"
}

###################################################
# 2. ARRAYS & COLLECTIONS
#   Commands: ForEach-Object | Measure-Object | Where-Object | Write-Host
###################################################
Show-Section "2. Arrays & Collections"

Show-Example "Array basics" {
    $arr = @(10, 20, 30, 40, 50)
    Write-Host "Array        : $arr"
    Write-Host "Count        : $($arr.Count)"
    Write-Host "First        : $($arr[0])"
    Write-Host "Last         : $($arr[-1])"
    Write-Host "Slice [1..3] : $($arr[1..3])"
    $arr += 60                                   # Append element (creates new array)
    Write-Host "After append : $arr"
}

Show-Example "ArrayList (mutable, efficient)" {
    $list = [System.Collections.ArrayList]@()
    $null = $list.Add('Alpha')
    $null = $list.Add('Beta')
    $null = $list.Add('Gamma')
    $list.Remove('Beta')                         # Remove by value
    Write-Host "ArrayList: $($list -join ', ')"
}

Show-Example "Generic List[T] (strongly typed)" {
    $intList = [System.Collections.Generic.List[int]]::new()
    1..5 | ForEach-Object { $intList.Add($_) }
    $intList.Remove(3)                           # Remove value 3
    Write-Host "List[int]: $($intList -join ', ')"
}

Show-Example "Stack and Queue" {
    # Stack -- LIFO (Last-In, First-Out)
    $stack = [System.Collections.Generic.Stack[string]]::new()
    $stack.Push('First'); $stack.Push('Second'); $stack.Push('Third')
    Write-Host "Stack Pop: $($stack.Pop())"       # Third

    # Queue -- FIFO (First-In, First-Out)
    $queue = [System.Collections.Generic.Queue[string]]::new()
    $queue.Enqueue('A'); $queue.Enqueue('B'); $queue.Enqueue('C')
    Write-Host "Queue Dequeue: $($queue.Dequeue())"  # A
}

Show-Example "Array filtering, mapping, and reducing" {
    $nums = 1..10
    $even    = $nums | Where-Object { $_ % 2 -eq 0 }          # Filter
    $squared = $nums | ForEach-Object { $_ * $_ }              # Map
    $sum     = ($nums | Measure-Object -Sum).Sum               # Reduce
    Write-Host "Even    : $($even -join ', ')"
    Write-Host "Squared : $($squared -join ', ')"
    Write-Host "Sum 1-10: $sum"
}

###################################################
# 3. ERROR HANDLING
#   Commands: Get-Item | Write-Host
###################################################
Show-Section "3. Error Handling"

Show-Example "try / catch / finally" {
    try {
        $result = 10 / 0                          # Divide by zero -- throws in .NET
        Write-Host "Result: $result"
    }
    catch [System.DivideByZeroException] {
        Write-Host "Caught DivideByZeroException: $($_.Exception.Message)"
    }
    catch {
        # Catch-all for any other exception type
        Write-Host "Caught generic error: $($_.Exception.Message)"
    }
    finally {
        # Always runs -- ideal for resource clean-up
        Write-Host "finally block ran."
    }
}

Show-Example "Non-terminating error with ErrorAction" {
    # ErrorAction Stop converts a non-terminating error into a catchable exception
    try {
        Get-Item -Path 'C:\DoesNotExist\file.txt' -ErrorAction Stop
    }
    catch {
        Write-Host "Caught non-terminating (promoted to terminating): $($_.Exception.Message)"
    }
}

Show-Example "`$Error automatic variable" {
    # $Error[0] always holds the most recent error in the session
    Get-Item 'Z:\ghost\path' -ErrorAction SilentlyContinue
    if ($Error[0]) {
        Write-Host "Last error: $($Error[0].Exception.Message)"
    }
}

Show-Example "trap statement (legacy error handling)" {
    function Invoke-TrapDemo {
        trap {
            Write-Host "trap caught: $($_.Exception.Message)"
            continue                             # Resume after the erroring statement
        }
        [int]"not-a-number"                     # Throws; trap handles it
        Write-Host "Execution continued after trap."
    }
    Invoke-TrapDemo
}

###################################################
# 4. PIPELINE DEEP-DIVE
#   Commands: Format-Table | ForEach-Object | Get-Process | Group-Object | Measure-Object | Select-Object | Sort-Object | Tee-Object | Write-Host
###################################################
Show-Section "4. Pipeline Deep-Dive"

Show-Example "ForEach-Object with -Begin / -Process / -End" {
    1..5 | ForEach-Object -Begin   { Write-Host "[Begin]"                     } `
                          -Process { Write-Host "  Processing: $_"            } `
                          -End     { Write-Host "[End]"                       }
}

Show-Example "Select-Object -- property projection & computed properties" {
    Get-Process | Select-Object -First 4 `
        Name,
        Id,
        @{ Name = 'MemMB';   Expression = { [math]::Round($_.WorkingSet64 / 1MB, 1) } },
        @{ Name = 'NameLen'; Expression = { $_.Name.Length } } |
    Format-Table -AutoSize
}

Show-Example "Tee-Object -- branch the pipeline without interrupting it" {
    $captured = @()
    Get-Process | Select-Object -First 5 |
        Tee-Object -Variable captured |         # Capture into $captured AND pass through
        Select-Object Name | Format-Table -AutoSize
    Write-Host "Tee captured $($captured.Count) objects."
}

Show-Example "Measure-Object" {
    $stats = Get-Process | Measure-Object -Property WorkingSet64 -Sum -Average -Maximum -Minimum
    Write-Host "Process WorkingSet stats:"
    Write-Host "  Count  : $($stats.Count)"
    Write-Host "  Sum MB : $([math]::Round($stats.Sum / 1MB, 1))"
    Write-Host "  Avg MB : $([math]::Round($stats.Average / 1MB, 1))"
    Write-Host "  Max MB : $([math]::Round($stats.Maximum / 1MB, 1))"
}

Show-Example "Group-Object & Sort-Object" {
    Get-Process |
        Group-Object -Property Name |
        Sort-Object  -Property Count -Descending |
        Select-Object -First 5 |
        Format-Table Name, Count -AutoSize
}

###################################################
# 5. OUTPUT METHODS
#   Commands: ConvertTo-Json | Export-Csv | Format-List | Format-Table | Format-Wide | Get-Content | Get-Item | Get-Process | Out-File | Out-Null | Out-String | Remove-Item | Select-Object | Set-Content | Write-Debug | Write-Host | Write-Information | Write-Output | Write-Verbose | Write-Warning
###################################################
Show-Section "5. Output Methods"

Show-Example "Write-* family" {
    Write-Host    "Write-Host    -- displays to console (not pipeline)"
    Write-Output  "Write-Output  -- sends to pipeline (default behaviour)"
    Write-Verbose "Write-Verbose -- visible only when -Verbose switch is set" -Verbose
    Write-Warning "Write-Warning -- yellow warning stream"
    Write-Debug   "Write-Debug   -- visible only in debug mode" -Debug:$false
    Write-Information "Write-Information -- information stream (stream 6)" -InformationAction Continue
    # Write-Error   "Write-Error   -- non-terminating error to error stream"
}

Show-Example "Format-* cmdlets" {
    # Format-Table -- tabular output
    Get-Process | Select-Object -First 3 | Format-Table Name, Id, CPU -AutoSize

    # Format-List -- each property on its own line
    Get-Process | Select-Object -First 1 | Format-List Name, Id, Path

    # Format-Wide -- single property across multiple columns
    Get-Process | Select-Object -First 9 | Format-Wide -Property Name -Column 3
}

Show-Example "Out-* cmdlets" {
    $tmpFile = Join-Path $env:TEMP 'cheatsheet_out.txt'
    Get-Process | Select-Object -First 5 | Out-File   -FilePath $tmpFile -Encoding UTF8
    $content = Get-Content $tmpFile
    Write-Host "Out-File wrote $($content.Count) lines to $tmpFile"
    Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue

    # Out-String converts formatted output to a single string
    $str = Get-Process | Select-Object -First 3 | Format-Table -AutoSize | Out-String
    Write-Host "Out-String length: $($str.Length) chars"

    # Out-Null discards output efficiently
    Get-Process | Out-Null
}

Show-Example "Export-* cmdlets" {
    $tmpCSV  = Join-Path $env:TEMP 'cheatsheet_procs.csv'
    $tmpJSON = Join-Path $env:TEMP 'cheatsheet_procs.json'

    Get-Process | Select-Object -First 5 Name, Id | Export-Csv  -Path $tmpCSV  -NoTypeInformation
    Get-Process | Select-Object -First 5 Name, Id | ConvertTo-Json -Depth 5 | Set-Content $tmpJSON -Encoding UTF8

    Write-Host "CSV  written : $tmpCSV  ($((Get-Item $tmpCSV).Length) bytes)"
    Write-Host "JSON written : $tmpJSON ($((Get-Item $tmpJSON).Length) bytes)"

    Remove-Item $tmpCSV, $tmpJSON -Force -ErrorAction SilentlyContinue
}

###################################################
# 6. JSON & XML
#   Commands: ConvertFrom-Json | ConvertTo-Json | Export-Csv | ForEach-Object | Import-Csv | Remove-Item | Write-Host
###################################################
Show-Section "6. JSON & XML"

Show-Example "JSON -- ConvertTo/From" {
    $obj  = [PSCustomObject]@{ Name = 'PowerShell'; Version = 7; Tags = @('shell','scripting') }
    $json = $obj | ConvertTo-Json -Depth 5
    Write-Host "JSON output:`n$json"

    $back = $json | ConvertFrom-Json
    Write-Host "Round-trip Name: $($back.Name)  Tags: $($back.Tags -join ',')"
}

Show-Example "XML -- [xml] type accelerator" {
    [xml]$xmlDoc = @'
<servers>
  <server name="web01" ip="10.0.0.1" />
  <server name="db01"  ip="10.0.0.2" />
</servers>
'@
    foreach ($srv in $xmlDoc.servers.server) {
        Write-Host "Server: $($srv.name)  IP: $($srv.ip)"
    }

    # Add a new node
    $newNode       = $xmlDoc.CreateElement('server')
    $newNode.SetAttribute('name', 'cache01')
    $newNode.SetAttribute('ip',   '10.0.0.3')
    $null          = $xmlDoc.servers.AppendChild($newNode)
    Write-Host "After add: $($xmlDoc.servers.server.Count) servers"
}

Show-Example "Import/Export CSV" {
    $tmpCSV = Join-Path $env:TEMP 'cheatsheet_import.csv'
    @(
        [PSCustomObject]@{ City = 'London';   Pop = 9_000_000 }
        [PSCustomObject]@{ City = 'New York'; Pop = 8_300_000 }
        [PSCustomObject]@{ City = 'Tokyo';    Pop = 13_900_000 }
    ) | Export-Csv -Path $tmpCSV -NoTypeInformation

    $imported = Import-Csv -Path $tmpCSV
    $imported | ForEach-Object { Write-Host "City: $($_.City)  Pop: $($_.Pop)" }

    Remove-Item $tmpCSV -Force -ErrorAction SilentlyContinue
}

###################################################
# 7. ENVIRONMENT VARIABLES
#   Commands: Format-Table | Get-ChildItem | Remove-Item | Select-Object | Sort-Object | Write-Host
###################################################
Show-Section "7. Environment Variables"

Show-Example "Read, write, and remove env vars" {
    # Read
    Write-Host "PATH first entry : $(($env:PATH -split ';')[0])"
    Write-Host "USERNAME         : $env:USERNAME"
    Write-Host "COMPUTERNAME     : $env:COMPUTERNAME"
    Write-Host "OS               : $env:OS"

    # Write (session-scoped -- does NOT persist to registry)
    $env:CHEATSHEET_DEMO = 'HelloV2'
    Write-Host "Custom env var   : $env:CHEATSHEET_DEMO"

    # Remove
    Remove-Item Env:\CHEATSHEET_DEMO -ErrorAction SilentlyContinue
    Write-Host "After remove     : $(if ($null -eq $env:CHEATSHEET_DEMO) {'(gone)'} else {$env:CHEATSHEET_DEMO})"
}

Show-Example "Enumerate all env vars" {
    Get-ChildItem Env: | Sort-Object Name | Select-Object -First 8 | Format-Table Name, Value -AutoSize
}

###################################################
# 8. DATE & TIME
#   Commands: Get-Date | Measure-Command | Start-Sleep | Write-Host
###################################################
Show-Section "8. Date & Time"

Show-Example "DateTime basics" {
    $now = Get-Date
    Write-Host "Now              : $now"
    Write-Host "UTC              : $($now.ToUniversalTime())"
    Write-Host "ISO 8601         : $($now.ToString('yyyy-MM-ddTHH:mm:ssZ'))"
    Write-Host "Day of week      : $($now.DayOfWeek)"
    Write-Host "Day of year      : $($now.DayOfYear)"

    # Arithmetic
    $future = $now.AddDays(30)
    $delta  = $future - $now
    Write-Host "+30 days         : $($future.ToShortDateString())"
    Write-Host "TimeSpan days    : $($delta.Days)"
}

Show-Example "Measuring execution time" {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Start-Sleep -Milliseconds 150
    $sw.Stop()
    Write-Host "Elapsed: $($sw.ElapsedMilliseconds) ms"

    # Measure-Command alternative
    $result = Measure-Command { Start-Sleep -Milliseconds 100 }
    Write-Host "Measure-Command: $($result.TotalMilliseconds) ms"
}

###################################################
# 9. BACKGROUND JOBS
#   Commands: Format-Table | ForEach-Object | Receive-Job | Remove-Job | Start-Job | Start-ThreadJob | Wait-Job | Write-Host
###################################################
Show-Section "9. Background Jobs"

Show-Example "Start-Job / Receive-Job" {
    # Start a job in a separate PowerShell process
    $job = Start-Job -ScriptBlock {
        Start-Sleep -Milliseconds 500
        "Job result: $([System.Math]::PI)"
    }
    Write-Host "Job state (running): $($job.State)"
    Wait-Job  $job | Out-Null
    $output = Receive-Job $job
    Write-Host "Job state (done)   : $($job.State)"
    Write-Host "Output             : $output"
    Remove-Job $job
}

Show-Example "ForEach-Object -Parallel (thread-based, PS7+)" {
    $results = 1..5 | ForEach-Object -Parallel {
        # Each iteration runs in its own thread
        [PSCustomObject]@{ Input = $_; Square = $_ * $_; Thread = [Threading.Thread]::CurrentThread.ManagedThreadId }
    } -ThrottleLimit 4
    $results | Format-Table -AutoSize
}

Show-Example "Start-ThreadJob (lighter than Start-Job)" {
    $tj = Start-ThreadJob -ScriptBlock {
        $pid                                     # Returns PID of host process (same as caller)
    }
    Wait-Job $tj | Out-Null
    $tjResult = Receive-Job $tj
    Write-Host "ThreadJob returned PID: $tjResult"
    Remove-Job $tj
}

###################################################
# 10. PROCESSES & SERVICES
#   Commands: Format-Table | Get-Process | Get-Service | Select-Object | Sort-Object | Start-Process | Start-Sleep | Stop-Process | Where-Object | Write-Host
###################################################
Show-Section "10. Processes & Services"

Show-Example "Get-Process" {
    # Top 5 processes by working-set memory
    Get-Process |
        Sort-Object WorkingSet64 -Descending |
        Select-Object -First 5 |
        Format-Table Name, Id, @{N='MemMB'; E={[math]::Round($_.WorkingSet64/1MB,1)}} -AutoSize
}

Show-Example "Start and stop a process" {
    # Start notepad (Windows), wait a moment, then kill it
    if ($IsWindows) {
        $proc = Start-Process -FilePath 'notepad.exe' -PassThru
        Write-Host "Started Notepad PID: $($proc.Id)"
        Start-Sleep -Milliseconds 500
        Stop-Process -Id $proc.Id -Force
        Write-Host "Notepad stopped."
    } else {
        Write-Host "Process Start/Stop example is Windows-only (notepad)."
    }
}

Show-Example "Get-Service" {
    Get-Service |
        Where-Object Status -eq 'Running' |
        Select-Object -First 5 |
        Format-Table Name, DisplayName, Status -AutoSize
}

###################################################
# 11. REGISTRY (Windows only)
#   Commands: Get-ItemProperty | New-Item | Remove-Item | Set-ItemProperty | Write-Host
###################################################
Show-Section "11. Registry (Windows only)"

Show-Example "Read registry values" {
    if ($IsWindows) {
        $regPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
        $reg     = Get-ItemProperty -Path $regPath
        Write-Host "ProductName   : $($reg.ProductName)"
        Write-Host "CurrentBuild  : $($reg.CurrentBuild)"
        Write-Host "ReleaseId     : $($reg.ReleaseId)"
    } else {
        Write-Host "Registry access is Windows-only."
    }
}

Show-Example "Create, update, and delete registry values (HKCU)" {
    if ($IsWindows) {
        $testKey = 'HKCU:\Software\CheatsheetDemo'
        New-Item         -Path $testKey                           -Force | Out-Null
        Set-ItemProperty -Path $testKey -Name 'TestValue' -Value 42
        $val = (Get-ItemProperty -Path $testKey).TestValue
        Write-Host "Read back TestValue: $val"
        Remove-Item -Path $testKey -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "Test registry key removed."
    } else {
        Write-Host "Registry write example is Windows-only."
    }
}

###################################################
# 12. NETWORK UTILITIES
#   Commands: Invoke-WebRequest | Resolve-DnsName | Test-Connection | Test-NetConnection | Write-Host
###################################################
Show-Section "12. Network Utilities"

Show-Example "Test-Connection (ping)" {
    $result = Test-Connection -ComputerName '8.8.8.8' -Count 2 -Quiet
    Write-Host "8.8.8.8 reachable: $result"
}

Show-Example "DNS resolution" {
    try {
        $dns = Resolve-DnsName -Name 'github.com' -Type A -ErrorAction Stop |
                   Select-Object -First 3
        $dns | Format-Table Name, Type, IPAddress -AutoSize
    }
    catch {
        Write-Host "DNS resolution failed: $($_.Exception.Message)"
    }
}

Show-Example "Invoke-WebRequest -- parse a web page" {
    try {
        $resp = Invoke-WebRequest -Uri 'https://api.github.com' -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
        Write-Host "HTTP status  : $($resp.StatusCode)"
        Write-Host "Content-Type : $($resp.Headers['Content-Type'])"
        Write-Host "Body snippet : $(($resp.Content | ConvertFrom-Json | Get-Member -MemberType NoteProperty | Select-Object -First 3 Name).Name -join ', ')"
    }
    catch {
        Write-Host "Web request failed: $($_.Exception.Message)" -ForegroundColor Red
    }
}

Show-Example "Test-NetConnection (port check)" {
    $nc = Test-NetConnection -ComputerName 'github.com' -Port 443 -InformationLevel Quiet
    Write-Host "github.com:443 open: $nc"
}

###################################################
# 13. CREDENTIAL HANDLING
#   Commands: ConvertFrom-SecureString | ConvertTo-SecureString | Get-Content | Out-File | Remove-Item | Write-Host
###################################################
Show-Section "13. Credential Handling"

Show-Example "PSCredential -- build without a GUI prompt" {
    # Convert a plain-text password to SecureString (demo only -- never store plain-text in real scripts)
    $securePass = ConvertTo-SecureString 'P@ssw0rd!' -AsPlainText -Force
    $cred       = [System.Management.Automation.PSCredential]::new('DOMAIN\Alice', $securePass)

    Write-Host "Username : $($cred.UserName)"
    Write-Host "Password is SecureString: $($cred.Password -is [System.Security.SecureString])"

    # Convert SecureString back to plain-text (for display/debug only -- avoid in production)
    $plainBack = $cred.GetNetworkCredential().Password
    Write-Host "Plain-text (demo): $plainBack"
}

Show-Example "Export and import encrypted credentials (Windows DPAPI)" {
    if ($IsWindows) {
        $secPwd  = ConvertTo-SecureString 'Secret123!' -AsPlainText -Force
        $tmpFile = Join-Path $env:TEMP 'cheatsheet_cred.xml'

        # Export -- encrypts with current user's Windows DPAPI key
        $secPwd | ConvertFrom-SecureString | Out-File $tmpFile -Encoding UTF8

        # Import -- decrypts back (must be the same user on the same machine)
        $imported = (Get-Content $tmpFile) | ConvertTo-SecureString
        $plain    = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($imported))
        Write-Host "Round-trip password: $plain"
        Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue
    } else {
        Write-Host "DPAPI credential export/import is Windows-only."
    }
}

###################################################
# 14. SCRIPT BLOCKS & CLOSURES
#   Commands: Write-Host
###################################################
Show-Section "14. Script Blocks & Closures"

Show-Example "Script block basics" {
    $greet    = { param([string]$Name) "Hello, $Name!" }
    $message  = & $greet -Name 'World'       # & invocation operator
    Write-Host $message

    $add      = { param($x, $y) $x + $y }
    Write-Host "10 + 32 = $(& $add 10 32)"
}

Show-Example "Closure -- GetNewClosure() captures outer variables" {
    $multiplier = 5
    $multiplyBy = { param($n) $n * $multiplier }.GetNewClosure()   # Captures $multiplier

    $multiplier = 999                        # Change outer variable
    Write-Host "Closure still uses captured value: $(& $multiplyBy 7)"   # Should be 35
}

Show-Example "Passing script blocks to functions" {
    function Invoke-Repeatedly ([int]$Times, [scriptblock]$Action) {
        for ($i = 1; $i -le $Times; $i++) { & $Action $i }
    }
    Invoke-Repeatedly -Times 3 -Action { param($n) Write-Host "Iteration $n" }
}

###################################################
# 15. SPLATTING
#   Commands: Get-ChildItem | Write-Host
###################################################
Show-Section "15. Splatting"

Show-Example "HashTable splatting (@)" {
    $params = @{
        Path       = $env:TEMP
        Filter     = '*.tmp'
        ErrorAction = 'SilentlyContinue'
    }
    $tmpFiles = Get-ChildItem @params | Select-Object -First 5
    Write-Host "Found $($tmpFiles.Count) .tmp files in $env:TEMP (showing up to 5)."
}

Show-Example "Array splatting (@) for positional parameters" {
    function Show-Coords ($X, $Y, $Z) { Write-Host "X=$X  Y=$Y  Z=$Z" }
    $coords = @(10, 20, 30)
    Show-Coords @coords
}

###################################################
# 16. CUSTOM OBJECTS ([PSCustomObject])
#   Commands: Add-Member | Format-Table | Select-Object | Sort-Object | Where-Object | Write-Host
###################################################
Show-Section "16. Custom Objects"

Show-Example "Create and use PSCustomObject" {
    $server = [PSCustomObject]@{
        Name    = 'SRV-PROD-01'
        Role    = 'WebServer'
        IP      = '192.168.1.10'
        Online  = $true
    }
    Write-Host "Name  : $($server.Name)"
    Write-Host "Online: $($server.Online)"

    # Add a new property after creation
    $server | Add-Member -NotePropertyName 'OS' -NotePropertyValue 'Windows Server 2022'
    Write-Host "OS    : $($server.OS)"
}

Show-Example "Array of custom objects + pipeline" {
    $fleet = @(
        [PSCustomObject]@{ Name='SRV01'; CPU=45; MemGB=32 }
        [PSCustomObject]@{ Name='SRV02'; CPU=12; MemGB=64 }
        [PSCustomObject]@{ Name='SRV03'; CPU=88; MemGB=16 }
    )
    $fleet |
        Where-Object   CPU  -gt 40 |
        Sort-Object    CPU  -Descending |
        Format-Table   Name, CPU, MemGB -AutoSize
}

###################################################
# 17. ENUMS
#   Commands: ForEach-Object | Write-Host
###################################################
Show-Section "17. Enums"

Show-Example "Define and use a custom Enum" {
    enum Severity {
        Low    = 1
        Medium = 2
        High   = 3
        Critical = 4
    }

    $alert = [Severity]::High
    Write-Host "Alert severity : $alert ($([int]$alert))"
    Write-Host "Is Critical?   : $($alert -eq [Severity]::Critical)"

    # Iterate all enum values
    [Severity].GetEnumValues() | ForEach-Object {
        Write-Host "  $_ = $([int]$_)"
    }
}

###################################################
# 18. STRONGLY TYPED GENERICS
#   Commands: ForEach-Object | Write-Host
###################################################
Show-Section "18. Strongly Typed Generics"

Show-Example "Dictionary[K,V]" {
    $dict = [System.Collections.Generic.Dictionary[string, int]]::new()
    $dict['alpha'] = 1
    $dict['beta']  = 2
    $dict['gamma'] = 3
    Write-Host "Contains 'beta': $($dict.ContainsKey('beta'))"
    Write-Host "Value of alpha : $($dict['alpha'])"
    $dict.Remove('beta')
    Write-Host "After remove   : $($dict.Keys -join ', ')"
}

Show-Example "HashSet[T] -- unique values" {
    $set = [System.Collections.Generic.HashSet[string]]::new()
    @('red','green','blue','red','green') | ForEach-Object { $null = $set.Add($_) }
    Write-Host "HashSet (unique): $($set -join ', ')"
}

###################################################
# 19. FILE PARSING
#   Commands: Add-Content | Format-Table | Get-Content | Import-Csv | Measure-Object | Remove-Item | Set-Content | Write-Host
###################################################
Show-Section "19. File Parsing"

Show-Example "Read and write text files" {
    $tmpTxt = Join-Path $env:TEMP 'cheatsheet_lines.txt'
    # Write multiple lines
    Set-Content  -Path $tmpTxt -Value @('Line one', 'Line two', 'Line three') -Encoding UTF8
    Add-Content  -Path $tmpTxt -Value 'Line four' -Encoding UTF8   # Append without overwrite

    # Read line-by-line
    $lines = Get-Content -Path $tmpTxt
    $lines | ForEach-Object { Write-Host "  Read: $_" }
    Write-Host "Total lines: $($lines.Count)"
    Remove-Item $tmpTxt -Force
}

Show-Example "Get-Content -Raw vs line-by-line" {
    $tmpRaw = Join-Path $env:TEMP 'cheatsheet_raw.txt'
    Set-Content -Path $tmpRaw -Value "First`nSecond`nThird" -Encoding UTF8

    $asLines  = Get-Content $tmpRaw              # Returns string[]
    $asString = Get-Content $tmpRaw -Raw         # Returns one big string

    Write-Host "As lines  type: $($asLines.GetType().Name)  count: $($asLines.Count)"
    Write-Host "As string type: $($asString.GetType().Name) length: $($asString.Length)"
    Remove-Item $tmpRaw -Force
}

Show-Example "Import-Csv / ConvertFrom-Csv" {
    $tmpCsv = Join-Path $env:TEMP 'cs_parse.csv'
    @"
Name,Department,Salary
Alice,Engineering,95000
Bob,Marketing,72000
Carol,Engineering,105000
"@ | Set-Content -Path $tmpCsv -Encoding UTF8

    $data = Import-Csv $tmpCsv
    $data | Format-Table -AutoSize
    $avgSalary = ($data | Measure-Object -Property Salary -Average).Average
    Write-Host "Avg salary: $avgSalary"
    Remove-Item $tmpCsv -Force
}

###################################################
# 20. MODULE AUTHORING SKELETON
#   Commands: 
<# Outline:
    Stub: describe module/script purpose here.
#>

<# Problems:
    Stub: list known issues here.
#>

<# ToDo:
    Stub: list pending work here.
#>
Export-ModuleMember | Format-Table | New-ModuleManifest | Write-Host
###################################################
Show-Section "20. Module Authoring Skeleton"

Show-Example "Inline module with manifest-style comment" {
    # A real module lives in its own .psm1 file with an optional .psd1 manifest.
    # Below is the skeleton pattern you'd place in MyModule.psm1:

    $moduleCode = @'
# MyModule.psm1

function Get-Greeting {
    <#
    .SYNOPSIS  Returns a greeting string.
    .PARAMETER Name  The name to greet.
    #>
    [CmdletBinding()]
    param([string]$Name = 'World')
    "Hello, $Name!"
}

function Set-Greeting { Write-Host "Placeholder for a setter command." }

# Export only the functions you want consumers to see

<# Outline:
    Stub: describe module/script purpose here.
#>

<# Problems:
    Stub: list known issues here.
#>

<# ToDo:
    Stub: list pending work here.
#>
Export-ModuleMember -Function Get-Greeting, Set-Greeting
'@
    Write-Host "Module skeleton (would be saved as MyModule.psm1):"
    Write-Host $moduleCode
}

Show-Example "New-ModuleManifest fields" {
    # A module manifest (.psd1) declares metadata about the module.
    # Key fields:
    $manifestFields = @{
        RootModule        = 'MyModule.psm1'
        ModuleVersion     = '1.0.0'
        Author            = 'Your Name'
        Description       = 'A helpful module.'
        PowerShellVersion = '7.0'
        FunctionsToExport = @('Get-Greeting', 'Set-Greeting')
    }
    $manifestFields.GetEnumerator() | Sort-Object Name | Format-Table Name, Value -AutoSize
    Write-Host "Use: New-ModuleManifest -Path .\MyModule.psd1 @manifestFields"
}

###################################################
# 21. PESTER UNIT TESTING SKELETON
#   Commands: Import-Module | Invoke-Pester | Remove-Module | Write-Host
###################################################
Show-Section "21. Pester Testing Skeleton"

Show-Example "Pester test structure" {
    $pesterSkeleton = @'
# tests/MyModule.Tests.ps1
# Run with: Invoke-Pester -Path .\tests\ -Output Detailed

Describe 'Get-Greeting' {

    BeforeAll {
        Import-Module "$PSScriptRoot\..\MyModule.psm1" -Force
    }

    It 'returns a string' {
        Get-Greeting | Should -BeOfType [string]
    }

    It 'uses default name "World"' {
        Get-Greeting | Should -Be 'Hello, World!'
    }

    It 'accepts a custom name' {
        Get-Greeting -Name 'Alice' | Should -Be 'Hello, Alice!'
    }

    AfterAll {
        Remove-Module MyModule -ErrorAction SilentlyContinue
    }
}
'@
    Write-Host "Pester skeleton (save as tests\MyModule.Tests.ps1):"
    Write-Host $pesterSkeleton
}

###################################################
# 22. MISCELLANEOUS TIPS
#   Commands: Invoke-Expression | Start-Sleep | Write-Host | Write-Progress
###################################################
Show-Section "22. Miscellaneous Tips"

Show-Example "Null coalescing (??) and null conditional (?.) -- PS7+" {
    if ($PSVersionTable.PSVersion.Major -ge 7) {
        Invoke-Expression '$val = $null; $result = $val ?? "default value"; Write-Host "Null coalesce: $result"'
        Invoke-Expression '$obj = [PSCustomObject]@{ Name = "Test" }; $safe = $obj?.Name; Write-Host "Null conditional: $safe"'
    } else {
        Write-Host "(Skipped -- requires PowerShell 7+)"
    }
}

Show-Example "Fully qualified .NET type names vs type accelerators" {
    # PowerShell type accelerators let you use short names like [hashtable], [int], [string].
    # For types without an accelerator, use the full .NET name:
    $nl = [System.Collections.Generic.List[string]]::new()
    $nl.Add('Hello'); $nl.Add('World')
    Write-Host "Full-name List[string]: $($nl -join ' ')"

    # NOTE: 'using namespace' is valid at the TOP of a .ps1 file (outside functions/blocks).
    # Example (top-of-file only):
    #   using namespace System.Collections.Generic
    #   $list = [List[string]]::new()
}

Show-Example "Write-Progress -- progress bar" {
    $items = 1..5
    foreach ($i in $items) {
        Write-Progress -Activity "Processing items" `
                       -Status  "Item $i of $($items.Count)" `
                       -PercentComplete (($i / $items.Count) * 100)
        Start-Sleep -Milliseconds 80
    }
    Write-Progress -Activity "Processing items" -Completed
    Write-Host "Progress bar demo complete."
}

Show-Example "Invoke-Expression (use with caution)" {
    $cmd    = 'Get-Date -Format "yyyy-MM-dd"'
    $output = Invoke-Expression $cmd
    Write-Host "Invoke-Expression result: $output"
    # WARNING: Never pass untrusted user input to Invoke-Expression -- code injection risk!
}

Show-Example "Here-String types (@' ' vs `"` `")" {
    # Single-quoted here-string -- no variable expansion
    $raw = @'
Path: $env:TEMP
No expansion here.
'@
    Write-Host "Single-quoted here-string:`n$raw"

    # Double-quoted here-string -- variables ARE expanded
    $expanded = @"
Path: $env:TEMP
Variables ARE expanded here.
"@
    Write-Host "Double-quoted here-string:`n$expanded"
}

Show-Example "Calculated sort & unique" {
    $words = 'banana', 'apple', 'cherry', 'apricot', 'blueberry'
    $words | Sort-Object { $_.Length } -Descending | Format-Wide -Column 5  # Sort by string length
    $words | Sort-Object -Unique | Format-Wide -Column 5                    # Alphabetical + deduplicate
}

###################################################
# DONE
###################################################
Show-Section "Cheat Sheet V2 Complete"
Write-Host "All V2 sections executed successfully." -ForegroundColor Green
Write-Host "Sections covered:" -ForegroundColor DarkGray
@(
    "1. String Manipulation",            "2. Arrays & Collections",
    "3. Error Handling",                 "4. Pipeline Deep-Dive",
    "5. Output Methods",                 "6. JSON & XML",
    "7. Environment Variables",          "8. Date & Time",
    "9. Background Jobs",                "10. Processes & Services",
    "11. Registry (Windows)",            "12. Network Utilities",
    "13. Credential Handling",           "14. Script Blocks & Closures",
    "15. Splatting",                     "16. Custom Objects",
    "17. Enums",                         "18. Generics",
    "19. File Parsing",                  "20. Module Authoring",
    "21. Pester Testing Skeleton",       "22. Miscellaneous Tips",
    "23. WinForms GUI Elements"
) | ForEach-Object { Write-Host "   $_" -ForegroundColor DarkGray }

###################################################
# 23. WINFORMS GUI -- Every Form Element
#   Commands: Add-Type | Write-Host
###################################################
Show-Section "23. WinForms GUI -- Every Form Element"

if (-not $script:RunSection23) {
    Write-Host "  Section 23 skipped (not selected). Re-run and tick 'S23-GUI' / enter 23 to enable." -ForegroundColor DarkGray
}
else {

Show-Example "Launch full WinForms demo (Windows only)" {
    if (-not $IsWindows) {
        Write-Host "WinForms is Windows-only. Skipping on $($PSVersionTable.OS)." -ForegroundColor Yellow
        return
    }

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $demoItems = @('alpha','beta','delta','gamma','epsilon')

    #region ---- Code Snippets Dictionary ----------------------------------
    $snippets = [ordered]@{
        'Label' = @'
$lbl = [System.Windows.Forms.Label]@{
    Text      = 'Hello World'
    Location  = [System.Drawing.Point]::new(10, 10)
    AutoSize  = $true
    Font      = [System.Drawing.Font]::new('Segoe UI', 9, 'Bold')
    ForeColor = [System.Drawing.Color]::DarkSlateBlue
}
$form.Controls.Add($lbl)
'@
        'Button' = @'
$btn = [System.Windows.Forms.Button]@{
    Text     = 'Click Me'
    Location = [System.Drawing.Point]::new(10, 10)
    Size     = [System.Drawing.Size]::new(120, 28)
}
$btn.Add_Click({ [Windows.Forms.MessageBox]::Show('Clicked!') })
$form.Controls.Add($btn)
'@
        'RadioButton' = @'
$panel = [System.Windows.Forms.Panel]@{
    Location = [System.Drawing.Point]::new(10, 10)
    Size     = [System.Drawing.Size]::new(300, 26)
}
$rb1 = [System.Windows.Forms.RadioButton]@{
    Text = 'Option A'; Location = [Drawing.Point]::new(0,2)
    Size = [Drawing.Size]::new(80,20); Checked = $true
}
$panel.Controls.Add($rb1)
$form.Controls.Add($panel)
'@
        'NumericUpDown' = @'
$nud = [System.Windows.Forms.NumericUpDown]@{
    Minimum  = 1; Maximum = 100; Value = 42
    Location = [System.Drawing.Point]::new(10, 10)
    Size     = [System.Drawing.Size]::new(90, 24)
}
$form.Controls.Add($nud)
'@
        'TrackBar' = @'
$track = [System.Windows.Forms.TrackBar]@{
    Minimum = 0; Maximum = 100; Value = 60
    TickFrequency = 10
    Location = [System.Drawing.Point]::new(10, 10)
    Size     = [System.Drawing.Size]::new(260, 40)
}
$form.Controls.Add($track)
'@
        'ProgressBar' = @'
$prog = [System.Windows.Forms.ProgressBar]@{
    Minimum = 0; Maximum = 100; Value = 75
    Location = [System.Drawing.Point]::new(10, 10)
    Size     = [System.Drawing.Size]::new(260, 20)
    Style    = 'Continuous'
}
$form.Controls.Add($prog)
'@
        'DateTimePicker' = @'
$dtp = [System.Windows.Forms.DateTimePicker]@{
    Format   = 'Long'
    Value    = (Get-Date)
    Location = [System.Drawing.Point]::new(10, 10)
    Size     = [System.Drawing.Size]::new(260, 24)
}
$form.Controls.Add($dtp)
'@
        'ListView' = @'
$lv = [System.Windows.Forms.ListView]@{
    View = 'Details'; FullRowSelect = $true; GridLines = $true
    Location = [System.Drawing.Point]::new(10, 10)
    Size     = [System.Drawing.Size]::new(400, 80)
}
$null = $lv.Columns.Add('Item', 120)
$null = $lv.Columns.Add('Value', 120)
$row  = [Windows.Forms.ListViewItem]::new('alpha')
$null = $row.SubItems.Add('val-1')
$null = $lv.Items.Add($row)
$form.Controls.Add($lv)
'@
        'TreeView' = @'
$tv = [System.Windows.Forms.TreeView]@{
    Location = [System.Drawing.Point]::new(10, 10)
    Size     = [System.Drawing.Size]::new(220, 80)
}
$root = $tv.Nodes.Add('Root')
$null = $root.Nodes.Add('Child 1')
$root.Expand()
$form.Controls.Add($tv)
'@
        'TabControl' = @'
$tc = [System.Windows.Forms.TabControl]@{
    Location = [System.Drawing.Point]::new(10, 10)
    Size     = [System.Drawing.Size]::new(400, 70)
}
$tp = [System.Windows.Forms.TabPage]@{ Text = 'Tab 1' }
$tp.Controls.Add([Windows.Forms.Label]@{
    Text = 'Content'; Location = [Drawing.Point]::new(8,8)
    AutoSize = $true
})
$tc.TabPages.Add($tp)
$form.Controls.Add($tc)
'@
        'FlowLayoutPanel' = @'
$flow = [System.Windows.Forms.FlowLayoutPanel]@{
    Location      = [System.Drawing.Point]::new(10, 10)
    Size          = [System.Drawing.Size]::new(400, 36)
    FlowDirection = 'LeftToRight'
    BorderStyle   = 'FixedSingle'
}
$lbl = [Windows.Forms.Label]@{
    Text = '[item]'; AutoSize = $true
    Margin = [Windows.Forms.Padding]::new(4)
}
$flow.Controls.Add($lbl)
$form.Controls.Add($flow)
'@
        'TextBox' = @'
$txt = [System.Windows.Forms.TextBox]@{
    Text     = 'Hello'
    Location = [System.Drawing.Point]::new(10, 10)
    Size     = [System.Drawing.Size]::new(200, 24)
}
$form.Controls.Add($txt)
'@
        'MultiLine TextBox' = @'
$ml = [System.Windows.Forms.TextBox]@{
    Text       = "Line1`r`nLine2"
    Location   = [System.Drawing.Point]::new(10, 10)
    Size       = [System.Drawing.Size]::new(200, 80)
    Multiline  = $true
    ScrollBars = 'Vertical'
}
$form.Controls.Add($ml)
'@
        'RichTextBox' = @'
$rtb = [System.Windows.Forms.RichTextBox]@{
    Location = [System.Drawing.Point]::new(10, 10)
    Size     = [System.Drawing.Size]::new(340, 68)
}
$rtb.AppendText('Normal ')
$rtb.SelectionColor = [Drawing.Color]::DarkRed
$rtb.AppendText('Red text')
$form.Controls.Add($rtb)
'@
        'CheckBox' = @'
$cb = [System.Windows.Forms.CheckBox]@{
    Text     = 'Enable feature'
    Checked  = $true
    Location = [System.Drawing.Point]::new(10, 10)
    Size     = [System.Drawing.Size]::new(200, 22)
}
$form.Controls.Add($cb)
'@
        'ComboBox' = @'
$combo = [System.Windows.Forms.ComboBox]@{
    DropDownStyle = 'DropDownList'
    Location = [System.Drawing.Point]::new(10, 10)
    Size     = [System.Drawing.Size]::new(180, 24)
}
@('alpha','beta','gamma') | ForEach-Object {
    $null = $combo.Items.Add($_)
}
$combo.SelectedIndex = 0
$form.Controls.Add($combo)
'@
        'ListBox' = @'
$lb = [System.Windows.Forms.ListBox]@{
    Location      = [System.Drawing.Point]::new(10, 10)
    Size          = [System.Drawing.Size]::new(180, 80)
    SelectionMode = 'MultiExtended'
}
@('alpha','beta') | ForEach-Object { $null = $lb.Items.Add($_) }
$form.Controls.Add($lb)
'@
        'CheckedListBox' = @'
$clb = [System.Windows.Forms.CheckedListBox]@{
    Location     = [System.Drawing.Point]::new(10, 10)
    Size         = [System.Drawing.Size]::new(180, 80)
    CheckOnClick = $true
}
$null = $clb.Items.Add('alpha', $true)
$null = $clb.Items.Add('beta', $false)
$form.Controls.Add($clb)
'@
        'MaskedTextBox' = @'
$mtb = [System.Windows.Forms.MaskedTextBox]@{
    Mask     = '(999) 000-0000'
    Text     = '5551234567'
    Location = [System.Drawing.Point]::new(10, 10)
    Size     = [System.Drawing.Size]::new(160, 24)
}
$form.Controls.Add($mtb)
'@
        'PictureBox' = @'
$pic = [System.Windows.Forms.PictureBox]@{
    Location    = [System.Drawing.Point]::new(10, 10)
    Size        = [System.Drawing.Size]::new(80, 50)
    BorderStyle = 'FixedSingle'
    SizeMode    = 'StretchImage'
}
$bmp = [System.Drawing.Bitmap]::new(80, 50)
$g = [Drawing.Graphics]::FromImage($bmp)
$g.Clear([Drawing.Color]::SteelBlue)
$g.Dispose()
$pic.Image = $bmp
$form.Controls.Add($pic)
'@
        'GroupBox' = @'
$gb = [System.Windows.Forms.GroupBox]@{
    Text     = 'Options'
    Location = [System.Drawing.Point]::new(10, 10)
    Size     = [System.Drawing.Size]::new(300, 52)
}
$gb.Controls.Add([Windows.Forms.Label]@{
    Text = 'Content'; Location = [Drawing.Point]::new(10,22)
    AutoSize = $true
})
$form.Controls.Add($gb)
'@
    }
    #endregion

    #region ---- Form -------------------------------------------------------
    $form = [System.Windows.Forms.Form]@{
        Text            = 'PS CheatSheet V2  --  Section 23: WinForms Elements'
        Size            = [System.Drawing.Size]::new(960, 840)
        StartPosition   = 'CenterScreen'
        FormBorderStyle = 'Sizable'
        MinimumSize     = [System.Drawing.Size]::new(800, 600)
        Font            = [System.Drawing.Font]::new('Segoe UI', 9)
        BackColor       = [System.Drawing.Color]::FromArgb(245, 245, 250)
    }
    #endregion

    #region ---- helper: label factory ------------------------------------
    function New-Label ($text, $x, $y, $w=160, $h=20) {
        [System.Windows.Forms.Label]@{
            Text     = $text
            Location = [System.Drawing.Point]::new($x, $y)
            Size     = [System.Drawing.Size]::new($w, $h)
            Font     = [System.Drawing.Font]::new('Segoe UI', 8, [System.Drawing.FontStyle]::Italic)
            ForeColor= [System.Drawing.Color]::SlateGray
        }
    }
    #endregion

    $lx = 14; $cx = 185; $gap = 6

    #region ---- Code Viewer Panel (form bottom, initially hidden) --------
    $codePanel = [System.Windows.Forms.Panel]@{
        Dock      = 'Bottom'
        Height    = 200
        Visible   = $false
        BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
        Padding   = [System.Windows.Forms.Padding]::new(4)
    }
    $codeHeaderPanel = [System.Windows.Forms.Panel]@{
        Dock      = 'Top'
        Height    = 30
        BackColor = [System.Drawing.Color]::FromArgb(40, 40, 40)
    }
    $codeLbl = [System.Windows.Forms.Label]@{
        Text      = '  Code Snippet'
        Dock      = 'Fill'
        ForeColor = [System.Drawing.Color]::FromArgb(86, 156, 214)
        Font      = [System.Drawing.Font]::new('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
        TextAlign = 'MiddleLeft'
    }
    $copyBtn = [System.Windows.Forms.Button]@{
        Text      = 'Copy'
        Dock      = 'Right'
        Width     = 80
        FlatStyle = 'Flat'
        ForeColor = [System.Drawing.Color]::White
        BackColor = [System.Drawing.Color]::FromArgb(60, 60, 60)
        Font      = [System.Drawing.Font]::new('Segoe UI', 8)
        Cursor    = 'Hand'
    }
    $closeCodeBtn = [System.Windows.Forms.Button]@{
        Text      = 'X'
        Dock      = 'Right'
        Width     = 32
        FlatStyle = 'Flat'
        ForeColor = [System.Drawing.Color]::Salmon
        BackColor = [System.Drawing.Color]::FromArgb(60, 60, 60)
        Font      = [System.Drawing.Font]::new('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
        Cursor    = 'Hand'
    }
    $codeBox = [System.Windows.Forms.RichTextBox]@{
        Dock        = 'Fill'
        ReadOnly    = $true
        BackColor   = [System.Drawing.Color]::FromArgb(30, 30, 30)
        ForeColor   = [System.Drawing.Color]::FromArgb(212, 212, 212)
        Font        = [System.Drawing.Font]::new('Consolas', 9)
        BorderStyle = 'None'
        WordWrap    = $false
    }
    $codeHeaderPanel.Controls.Add($codeLbl)
    $codeHeaderPanel.Controls.Add($copyBtn)
    $codeHeaderPanel.Controls.Add($closeCodeBtn)
    $codePanel.Controls.Add($codeBox)
    $codePanel.Controls.Add($codeHeaderPanel)
    #endregion

    #region ---- Snippet [+] button factory --------------------------------
    $statusBar = $null   # forward-declare; assigned below
    $script:activeSnippetBtn = $null

    function New-SnippetBtn ($snippetKey, $x, $y) {
        $b = [System.Windows.Forms.Button]@{
            Text      = '+'
            Tag       = $snippetKey
            Location  = [System.Drawing.Point]::new($x, $y)
            Size      = [System.Drawing.Size]::new(24, 22)
            FlatStyle = 'Flat'
            Font      = [System.Drawing.Font]::new('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
            ForeColor = [System.Drawing.Color]::SteelBlue
            BackColor = [System.Drawing.Color]::FromArgb(235, 235, 240)
            Cursor    = 'Hand'
        }
        $b.FlatAppearance.BorderColor = [System.Drawing.Color]::LightSteelBlue
        $b.Add_Click({
            $key = $this.Tag
            if ($snippets.ContainsKey($key)) {
                if ($codePanel.Visible -and $script:activeSnippetBtn -eq $this) {
                    $codePanel.Visible = $false
                    $this.Text = '+'
                    $script:activeSnippetBtn = $null
                    return
                }
                if ($script:activeSnippetBtn) { $script:activeSnippetBtn.Text = '+' }
                $codeBox.Text = $snippets[$key]
                $codeLbl.Text = "  Code Snippet: $key"
                $codePanel.Visible = $true
                $this.Text = [string][char]0x2212
                $script:activeSnippetBtn = $this
            }
        })
        return $b
    }
    #endregion

    #region ---- MenuStrip (top of form) -----------------------------------
    $menu = [System.Windows.Forms.MenuStrip]::new()
    $fileMenu = [System.Windows.Forms.ToolStripMenuItem]::new('&File')
    $null = $fileMenu.DropDownItems.Add([System.Windows.Forms.ToolStripMenuItem]::new(
                '&Close', $null, [System.EventHandler]{ $form.Close() }))
    $helpMenu = [System.Windows.Forms.ToolStripMenuItem]::new('&Help')
    $null = $helpMenu.DropDownItems.Add([System.Windows.Forms.ToolStripMenuItem]::new(
                'About Section 23', $null,
                [System.EventHandler]{ [System.Windows.Forms.MessageBox]::Show(
                    "WinForms demo`nSection 23: alpha, beta, delta, gamma, epsilon",
                    'PS CheatSheet V2', 'OK', 'Information') | Out-Null }))
    $null = $menu.Items.Add($fileMenu)
    $null = $menu.Items.Add($helpMenu)
    $form.MainMenuStrip = $menu
    #endregion

    #region ---- ToolStrip -------------------------------------------------
    $ts = [System.Windows.Forms.ToolStrip]::new()
    $ts.Dock = 'Top'
    foreach ($item in $demoItems) {
        $tsBtn = [System.Windows.Forms.ToolStripButton]::new($item)
        $tsBtn.Add_Click([System.EventHandler]{ param($s,$e)
            $statusBar.Text = "ToolStrip: $($s.Text)  --  $(Get-Date -f HH:mm:ss)"
        })
        $null = $ts.Items.Add($tsBtn)
    }
    #endregion

    #region ---- StatusStrip -----------------------------------------------
    $ss  = [System.Windows.Forms.StatusStrip]@{ SizingGrip = $false }
    $statusBar = [System.Windows.Forms.ToolStripStatusLabel]@{
        Text      = 'Section 23 -- click [+] next to any element to view its code snippet.'
        Spring    = $true
        TextAlign = 'MiddleLeft'
    }
    $null = $ss.Items.Add($statusBar)
    #endregion

    #region ---- Main TabControl (2 tabs) ----------------------------------
    $mainTab = [System.Windows.Forms.TabControl]@{
        Dock = 'Fill'
        Font = [System.Drawing.Font]::new('Segoe UI', 9)
    }
    $tab1 = [System.Windows.Forms.TabPage]@{
        Text      = 'Controls'
        BackColor = [System.Drawing.Color]::FromArgb(245, 245, 250)
        Padding   = [System.Windows.Forms.Padding]::new(4)
    }
    $tab2 = [System.Windows.Forms.TabPage]@{
        Text      = 'Box Controls'
        BackColor = [System.Drawing.Color]::FromArgb(245, 245, 250)
        Padding   = [System.Windows.Forms.Padding]::new(4)
    }
    $panel1 = [System.Windows.Forms.Panel]@{ Dock = 'Fill'; AutoScroll = $true }
    $panel2 = [System.Windows.Forms.Panel]@{ Dock = 'Fill'; AutoScroll = $true }
    $tab1.Controls.Add($panel1)
    $tab2.Controls.Add($panel2)
    $mainTab.TabPages.Add($tab1)
    $mainTab.TabPages.Add($tab2)
    #endregion

    # ====================== TAB 1 : Controls ==============================
    $y = 8

    # ---- Label -----------------------------------------------------------
    $panel1.Controls.Add((New-Label 'Label' $lx $y))
    $lblDemo = [System.Windows.Forms.Label]@{
        Text      = 'alpha  beta  delta  gamma  epsilon'
        Location  = [System.Drawing.Point]::new($cx, $y)
        Size      = [System.Drawing.Size]::new(500, 22)
        Font      = [System.Drawing.Font]::new('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
        ForeColor = [System.Drawing.Color]::DarkSlateBlue
        AutoSize  = $false
    }
    $panel1.Controls.Add($lblDemo)
    $panel1.Controls.Add((New-SnippetBtn 'Label' 640 $y))
    $y += 30 + $gap

    # ---- Button ----------------------------------------------------------
    $panel1.Controls.Add((New-Label 'Button' $lx $y))
    $btn = [System.Windows.Forms.Button]@{
        Text     = 'Click Me (Button)'
        Location = [System.Drawing.Point]::new($cx, $y)
        Size     = [System.Drawing.Size]::new(160, 28)
    }
    $btn.Add_Click({ $statusBar.Text = "Button clicked  --  $(Get-Date -f HH:mm:ss)" })
    $panel1.Controls.Add($btn)
    $panel1.Controls.Add((New-SnippetBtn 'Button' 640 $y))
    $y += 36 + $gap

    # ---- RadioButton -----------------------------------------------------
    $panel1.Controls.Add((New-Label 'RadioButton' $lx $y 160 20))
    $rbPanel = [System.Windows.Forms.Panel]@{
        Location  = [System.Drawing.Point]::new($cx, $y)
        Size      = [System.Drawing.Size]::new(380, 26)
        BackColor = [System.Drawing.Color]::Transparent
    }
    $rbX = 0
    foreach ($item in $demoItems) {
        $rb = [System.Windows.Forms.RadioButton]@{
            Text     = $item
            Location = [System.Drawing.Point]::new($rbX, 2)
            Size     = [System.Drawing.Size]::new(70, 20)
            Checked  = ($item -eq 'alpha')
        }
        $rbPanel.Controls.Add($rb)
        $rbX += 72
    }
    $panel1.Controls.Add($rbPanel)
    $panel1.Controls.Add((New-SnippetBtn 'RadioButton' 640 $y))
    $y += 32 + $gap

    # ---- NumericUpDown ---------------------------------------------------
    $panel1.Controls.Add((New-Label 'NumericUpDown' $lx $y))
    $nud = [System.Windows.Forms.NumericUpDown]@{
        Minimum  = 1
        Maximum  = 100
        Value    = 42
        Location = [System.Drawing.Point]::new($cx, $y)
        Size     = [System.Drawing.Size]::new(90, 24)
    }
    $panel1.Controls.Add($nud)
    $panel1.Controls.Add((New-SnippetBtn 'NumericUpDown' 640 $y))
    $y += 32 + $gap

    # ---- TrackBar --------------------------------------------------------
    $panel1.Controls.Add((New-Label 'TrackBar' $lx $y))
    $track = [System.Windows.Forms.TrackBar]@{
        Minimum       = 0
        Maximum       = 100
        Value         = 60
        TickFrequency = 10
        Location      = [System.Drawing.Point]::new($cx, $y)
        Size          = [System.Drawing.Size]::new(260, 40)
    }
    $panel1.Controls.Add($track)
    $panel1.Controls.Add((New-SnippetBtn 'TrackBar' 640 $y))
    $y += 44 + $gap

    # ---- ProgressBar -----------------------------------------------------
    $panel1.Controls.Add((New-Label 'ProgressBar' $lx $y))
    $prog = [System.Windows.Forms.ProgressBar]@{
        Minimum  = 0
        Maximum  = 100
        Value    = 75
        Location = [System.Drawing.Point]::new($cx, $y)
        Size     = [System.Drawing.Size]::new(260, 20)
        Style    = 'Continuous'
    }
    $panel1.Controls.Add($prog)
    $panel1.Controls.Add((New-SnippetBtn 'ProgressBar' 640 $y))
    $y += 28 + $gap

    # ---- DateTimePicker --------------------------------------------------
    $panel1.Controls.Add((New-Label 'DateTimePicker' $lx $y))
    $dtp = [System.Windows.Forms.DateTimePicker]@{
        Format   = 'Long'
        Value    = (Get-Date)
        Location = [System.Drawing.Point]::new($cx, $y)
        Size     = [System.Drawing.Size]::new(260, 24)
    }
    $panel1.Controls.Add($dtp)
    $panel1.Controls.Add((New-SnippetBtn 'DateTimePicker' 640 $y))
    $y += 32 + $gap

    # ---- ListView --------------------------------------------------------
    $panel1.Controls.Add((New-Label 'ListView' $lx $y))
    $lv = [System.Windows.Forms.ListView]@{
        View          = 'Details'
        Location      = [System.Drawing.Point]::new($cx, $y)
        Size          = [System.Drawing.Size]::new(400, 80)
        FullRowSelect = $true
        GridLines     = $true
    }
    $null = $lv.Columns.Add('Item',   100)
    $null = $lv.Columns.Add('Value',  100)
    $null = $lv.Columns.Add('Status', 100)
    $ordinals = @{alpha=1;beta=2;delta=3;gamma=4;epsilon=5}
    foreach ($k in $demoItems) {
        $row = [System.Windows.Forms.ListViewItem]::new($k)
        $null = $row.SubItems.Add("val-$($ordinals[$k])")
        $null = $row.SubItems.Add($(if($ordinals[$k] -le 3){'active'}else{'idle'}))
        $null = $lv.Items.Add($row)
    }
    $panel1.Controls.Add($lv)
    $panel1.Controls.Add((New-SnippetBtn 'ListView' 640 $y))
    $y += 88 + $gap

    # ---- TreeView --------------------------------------------------------
    $panel1.Controls.Add((New-Label 'TreeView' $lx $y))
    $tv = [System.Windows.Forms.TreeView]@{
        Location  = [System.Drawing.Point]::new($cx, $y)
        Size      = [System.Drawing.Size]::new(220, 80)
        BackColor = [System.Drawing.Color]::White
    }
    $root = $tv.Nodes.Add('Root')
    $demoItems | ForEach-Object { $null = $root.Nodes.Add($_) }
    $root.Expand()
    $panel1.Controls.Add($tv)
    $panel1.Controls.Add((New-SnippetBtn 'TreeView' 640 $y))
    $y += 88 + $gap

    # ---- TabControl (inner demo) -----------------------------------------
    $panel1.Controls.Add((New-Label 'TabControl' $lx $y))
    $tc = [System.Windows.Forms.TabControl]@{
        Location = [System.Drawing.Point]::new($cx, $y)
        Size     = [System.Drawing.Size]::new(400, 70)
    }
    foreach ($item in $demoItems) {
        $tp = [System.Windows.Forms.TabPage]@{ Text = $item }
        $innerLbl = [System.Windows.Forms.Label]@{
            Text     = "Tab content: $item"
            Location = [System.Drawing.Point]::new(8, 8)
            AutoSize = $true
        }
        $tp.Controls.Add($innerLbl)
        $tc.TabPages.Add($tp)
    }
    $panel1.Controls.Add($tc)
    $panel1.Controls.Add((New-SnippetBtn 'TabControl' 640 $y))
    $y += 78 + $gap

    # ---- FlowLayoutPanel -------------------------------------------------
    $panel1.Controls.Add((New-Label ('Panel /' + [char]10 + 'FlowLayout') $lx $y 160 36))
    $flow = [System.Windows.Forms.FlowLayoutPanel]@{
        Location         = [System.Drawing.Point]::new($cx, $y)
        Size             = [System.Drawing.Size]::new(500, 36)
        FlowDirection    = 'LeftToRight'
        WrapContents     = $false
        BackColor        = [System.Drawing.Color]::AliceBlue
        BorderStyle      = 'FixedSingle'
        Padding          = [System.Windows.Forms.Padding]::new(4)
    }
    foreach ($item in $demoItems) {
        $flbl = [System.Windows.Forms.Label]@{
            Text      = "[■] $item"
            AutoSize  = $true
            Margin    = [System.Windows.Forms.Padding]::new(4, 4, 4, 0)
            ForeColor = [System.Drawing.Color]::DarkBlue
        }
        $flow.Controls.Add($flbl)
    }
    $panel1.Controls.Add($flow)
    $panel1.Controls.Add((New-SnippetBtn 'FlowLayoutPanel' 640 $y))
    $y += 44 + $gap

    # ====================== TAB 2 : Box Controls ==========================
    $y = 8

    # ---- TextBox (single-line) -------------------------------------------
    $panel2.Controls.Add((New-Label 'TextBox' $lx $y))
    $txt = [System.Windows.Forms.TextBox]@{
        Text     = 'alpha'
        Location = [System.Drawing.Point]::new($cx, $y)
        Size     = [System.Drawing.Size]::new(200, 24)
    }
    $panel2.Controls.Add($txt)
    $panel2.Controls.Add((New-SnippetBtn 'TextBox' 640 $y))
    $y += 32 + $gap

    # ---- MultiLine TextBox -----------------------------------------------
    $panel2.Controls.Add((New-Label 'MultiLine TextBox' $lx $y 160 18))
    $ml = [System.Windows.Forms.TextBox]@{
        Text      = ($demoItems -join [System.Environment]::NewLine)
        Location  = [System.Drawing.Point]::new($cx, $y)
        Size      = [System.Drawing.Size]::new(200, 80)
        Multiline = $true
        ScrollBars= 'Vertical'
    }
    $panel2.Controls.Add($ml)
    $panel2.Controls.Add((New-SnippetBtn 'MultiLine TextBox' 640 $y))
    $y += 88 + $gap

    # ---- RichTextBox -----------------------------------------------------
    $panel2.Controls.Add((New-Label 'RichTextBox' $lx $y))
    $rtb = [System.Windows.Forms.RichTextBox]@{
        Location  = [System.Drawing.Point]::new($cx, $y)
        Size      = [System.Drawing.Size]::new(340, 68)
        BackColor = [System.Drawing.Color]::White
    }
    $rtb.AppendText('alpha  ')
    $rtb.SelectionColor = [System.Drawing.Color]::DarkRed
    $rtb.AppendText("beta`n")
    $rtb.SelectionFont  = [System.Drawing.Font]::new('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    $rtb.AppendText('delta  gamma  epsilon')
    $panel2.Controls.Add($rtb)
    $panel2.Controls.Add((New-SnippetBtn 'RichTextBox' 640 $y))
    $y += 76 + $gap

    # ---- CheckBox --------------------------------------------------------
    $panel2.Controls.Add((New-Label 'CheckBox' $lx $y))
    $cb = [System.Windows.Forms.CheckBox]@{
        Text     = 'CheckBox  (alpha)'
        Checked  = $true
        Location = [System.Drawing.Point]::new($cx, $y)
        Size     = [System.Drawing.Size]::new(200, 22)
    }
    $panel2.Controls.Add($cb)
    $panel2.Controls.Add((New-SnippetBtn 'CheckBox' 640 $y))
    $y += 28 + $gap

    # ---- ComboBox (DropDownList) -----------------------------------------
    $panel2.Controls.Add((New-Label 'ComboBox' $lx $y))
    $combo = [System.Windows.Forms.ComboBox]@{
        DropDownStyle = 'DropDownList'
        Location      = [System.Drawing.Point]::new($cx, $y)
        Size          = [System.Drawing.Size]::new(180, 24)
    }
    $demoItems | ForEach-Object { $null = $combo.Items.Add($_) }
    $combo.SelectedIndex = 0
    $panel2.Controls.Add($combo)
    $panel2.Controls.Add((New-SnippetBtn 'ComboBox' 640 $y))
    $y += 32 + $gap

    # ---- ListBox ---------------------------------------------------------
    $panel2.Controls.Add((New-Label 'ListBox' $lx $y))
    $lb = [System.Windows.Forms.ListBox]@{
        Location      = [System.Drawing.Point]::new($cx, $y)
        Size          = [System.Drawing.Size]::new(180, 80)
        SelectionMode = 'MultiExtended'
    }
    $demoItems | ForEach-Object { $null = $lb.Items.Add($_) }
    $lb.SetSelected(0, $true)
    $panel2.Controls.Add($lb)
    $panel2.Controls.Add((New-SnippetBtn 'ListBox' 640 $y))
    $y += 88 + $gap

    # ---- CheckedListBox --------------------------------------------------
    $panel2.Controls.Add((New-Label 'CheckedListBox' $lx $y))
    $clb = [System.Windows.Forms.CheckedListBox]@{
        Location     = [System.Drawing.Point]::new($cx, $y)
        Size         = [System.Drawing.Size]::new(180, 80)
        CheckOnClick = $true
    }
    $i2 = 0
    $demoItems | ForEach-Object {
        $null = $clb.Items.Add($_, ($i2 % 2 -eq 0))    # alternating pre-checked
        $i2++
    }
    $panel2.Controls.Add($clb)
    $panel2.Controls.Add((New-SnippetBtn 'CheckedListBox' 640 $y))
    $y += 88 + $gap

    # ---- MaskedTextBox ---------------------------------------------------
    $panel2.Controls.Add((New-Label 'MaskedTextBox' $lx $y))
    $mtb = [System.Windows.Forms.MaskedTextBox]@{
        Mask     = '(999) 000-0000'
        Text     = '5551234567'
        Location = [System.Drawing.Point]::new($cx, $y)
        Size     = [System.Drawing.Size]::new(160, 24)
    }
    $panel2.Controls.Add($mtb)
    $panel2.Controls.Add((New-SnippetBtn 'MaskedTextBox' 640 $y))
    $y += 32 + $gap

    # ---- PictureBox ------------------------------------------------------
    $panel2.Controls.Add((New-Label 'PictureBox' $lx $y))
    $pic = [System.Windows.Forms.PictureBox]@{
        Location    = [System.Drawing.Point]::new($cx, $y)
        Size        = [System.Drawing.Size]::new(80, 50)
        BorderStyle = 'FixedSingle'
        BackColor   = [System.Drawing.Color]::LightSteelBlue
        SizeMode    = 'StretchImage'
    }
    # Draw a simple bitmap with "PS" text via GDI+
    $bmp = [System.Drawing.Bitmap]::new(80, 50)
    $g   = [System.Drawing.Graphics]::FromImage($bmp)
    $g.Clear([System.Drawing.Color]::SteelBlue)
    $g.DrawString('PS', [System.Drawing.Font]::new('Segoe UI',16,[System.Drawing.FontStyle]::Bold),
                  [System.Drawing.Brushes]::White, 12, 8)
    $g.Dispose()
    $pic.Image = $bmp
    $panel2.Controls.Add($pic)
    $panel2.Controls.Add((New-SnippetBtn 'PictureBox' 640 $y))
    $y += 58 + $gap

    # ---- GroupBox --------------------------------------------------------
    $panel2.Controls.Add((New-Label 'GroupBox' $lx $y))
    $gb = [System.Windows.Forms.GroupBox]@{
        Text     = 'GroupBox -- demo options'
        Location = [System.Drawing.Point]::new($cx, $y)
        Size     = [System.Drawing.Size]::new(400, 52)
    }
    $gbX = 10
    foreach ($item in $demoItems) {
        $gblbl = [System.Windows.Forms.Label]@{
            Text     = $item
            Location = [System.Drawing.Point]::new($gbX, 22)
            AutoSize = $true
        }
        $gb.Controls.Add($gblbl)
        $gbX += 72
    }
    $panel2.Controls.Add($gb)
    $panel2.Controls.Add((New-SnippetBtn 'GroupBox' 640 $y))
    $y += 60 + $gap

    # ---- ToolTip ---------------------------------------------------------
    $tip = [System.Windows.Forms.ToolTip]@{ InitialDelay = 400; ShowAlways = $true }
    $tip.SetToolTip($txt,   'TextBox -- type any value here')
    $tip.SetToolTip($combo, 'ComboBox -- pick one of the demo items')
    $tip.SetToolTip($nud,   'NumericUpDown -- range 1 – 100')
    $tip.SetToolTip($track, 'TrackBar -- drag to adjust value')
    $tip.SetToolTip($btn,   'Button -- click to update the StatusBar')

    # ---- ContextMenuStrip on the form ------------------------------------
    $cms = [System.Windows.Forms.ContextMenuStrip]::new()
    foreach ($item in $demoItems) {
        $cmi = [System.Windows.Forms.ToolStripMenuItem]::new($item)
        $cmi.Add_Click([System.EventHandler]{ param($s,$e)
            $statusBar.Text = "ContextMenu selected: $($s.Text)"
        })
        $null = $cms.Items.Add($cmi)
    }
    $form.ContextMenuStrip = $cms

    # ---- Wire-up live status updates for key controls --------------------
    $track.Add_ValueChanged({ $statusBar.Text = "TrackBar = $($track.Value)" })
    $combo.Add_SelectedIndexChanged({ $statusBar.Text = "ComboBox = $($combo.SelectedItem)" })
    $cb.Add_CheckedChanged({ $statusBar.Text = "CheckBox 'alpha' = $($cb.Checked)" })
    $nud.Add_ValueChanged({ $statusBar.Text = "NumericUpDown = $($nud.Value)" })
    $dtp.Add_ValueChanged({ $statusBar.Text = "DateTimePicker = $($dtp.Value.ToString('yyyy-MM-dd'))" })

    # ---- Code panel button handlers --------------------------------------
    $copyBtn.Add_Click({ [System.Windows.Forms.Clipboard]::SetText($codeBox.Text) })
    $closeCodeBtn.Add_Click({
        $codePanel.Visible = $false
        if ($script:activeSnippetBtn) {
            $script:activeSnippetBtn.Text = '+'
            $script:activeSnippetBtn = $null
        }
    })

    # ---- Form assembly (correct WinForms docking order) ------------------
    # WinForms docks controls back-to-front (highest index first).
    # Fill control at index 0 ⇒ docked LAST ⇒ fills remaining space.
    $form.SuspendLayout()
    $form.Controls.Add($mainTab)     # index 0 – Fill   (docked last)
    $form.Controls.Add($codePanel)   # index 1 – Bottom (code viewer)
    $form.Controls.Add($ss)          # index 2 – Bottom (status bar)
    $form.Controls.Add($ts)          # index 3 – Top    (toolbar)
    $form.Controls.Add($menu)        # index 4 – Top    (menu bar, docked first)
    $form.ResumeLayout($true)

    # ---- Show the form (modal, blocks until closed) ----------------------
    Write-Host "  Launching WinForms GUI -- close the window to continue." -ForegroundColor Cyan
    [void]$form.ShowDialog()
    Write-Host "  WinForms demo closed." -ForegroundColor Green
}

} # end if ($script:RunSection23)


###################################################

# Stop transcript first -- so the export process itself is not captured
Stop-Transcript | Out-Null

# Strip ANSI / VT escape codes that colour-output writes into raw text
function Remove-AnsiCodes ([string]$Text) {
    $Text -replace '(\x9B|\x1B\[)[0-?]*[ -\/]*[@-~]', '' `
          -replace '\x1b\[[0-9;]*m', ''
}

$script:DoExport = ($script:SelectedMethods.Count -gt 0) -or $script:RunHtmlView

if ($script:DoExport) {

    $rawLines   = Get-Content -Path $script:TranscriptPath
    $cleanLines = $rawLines | ForEach-Object { Remove-AnsiCodes $_ }

    # ---- Build shared HTML artefact once (used by both HTML file and HTMLV) --
    $htmlTitle = "PS Cheat Sheet V2 -- $($script:Hostname) -- $($script:Timestamp)"
    $i = 0
    $htmlRows = $cleanLines | ForEach-Object {
        $i++
        [PSCustomObject]@{ '#' = $i; Output = $_ }
    }
    $htmlCss = @'
<style>
  body  { font-family: Consolas,"Cascadia Code",monospace; background:#1e1e1e; color:#d4d4d4; margin:1rem 2rem; }
  h1    { color:#569cd6; margin-bottom:.2rem; }
  p.meta{ color:#888; font-size:.8rem; margin-top:0; }
  table { border-collapse:collapse; width:100%; font-size:.82rem; }
  th    { background:#252526; color:#9cdcfe; padding:4px 10px; text-align:left; border:1px solid #3c3c3c; }
  td    { padding:2px 10px; border:1px solid #3c3c3c; white-space:pre; vertical-align:top; }
  td:first-child { color:#666; width:4rem; text-align:right; }
  tr:nth-child(even){ background:#252526; }
</style>
'@
    $htmlPreContent = "$htmlCss<h1>PS Cheat Sheet V2 &mdash; Examples</h1>" +
                      "<p class='meta'>Host: <b>$($script:Hostname)</b> &nbsp;|&nbsp; " +
                      "Run: <b>$($script:Timestamp)</b></p>"
    # HTML file path -- used if HTML file export is selected, or shared with HTMLV when both are selected
    $script:HtmlFilePath = Join-Path $script:OutputDir "$($script:BaseName)-htmlview.html"

    # ---- File exports -------------------------------------------------------
    if ($script:SelectedMethods.Count -gt 0) {
        Write-Host ""
        Write-Host ("=" * 68) -ForegroundColor Cyan
        Write-Host "  EXPORTING OUTPUT  --  $($script:SelectedMethods.Count) FILE FORMAT(S)" -ForegroundColor Yellow
        Write-Host ("=" * 68) -ForegroundColor Cyan
        Write-Host "  Output directory : $($script:OutputDir)" -ForegroundColor White
        Write-Host ""

        $nn = 0
        foreach ($method in $script:SelectedMethods) {
            $nn++
            $nnStr   = $nn.ToString('00')
            $outFile = Join-Path $script:OutputDir "$($script:BaseName)-$nnStr.$($method.Ext)"

            switch ($method.Name) {

                'TXT' {
                    $cleanLines -join "`n" | Out-File -FilePath $outFile -Encoding UTF8 -Force
                }

                'CSV' {
                    $i = 0
                    $cleanLines | ForEach-Object {
                        $i++
                        [PSCustomObject]@{ LineNo = $i; Content = $_ }
                    } | Export-Csv -Path $outFile -NoTypeInformation -Encoding UTF8 -Force
                }

                'JSON' {
                    $i = 0
                    $cleanLines | ForEach-Object {
                        $i++
                        [PSCustomObject]@{ LineNo = $i; Content = $_ }
                    } | ConvertTo-Json -Depth 3 | Set-Content -Path $outFile -Encoding UTF8 -Force
                }

                'XML' {
                    $i = 0
                    $cleanLines | ForEach-Object {
                        $i++
                        [PSCustomObject]@{ LineNo = $i; Content = $_ }
                    } | Export-CliXml -Path $outFile -Depth 3 -Force
                }

                'HTML' {
                    $htmlRows | ConvertTo-Html `
                        -Title      $htmlTitle `
                        -PreContent $htmlPreContent `
                        -Property   '#', 'Output' |
                    Set-Content -Path $outFile -Encoding UTF8 -Force
                    # Track the saved path so HTMLV can reuse this file if also selected
                    $script:HtmlFilePath = $outFile
                }
            }

            Write-Host ("  [{0}] {1,-5}  ->  {2}" -f $nnStr, $method.Name, $outFile) -ForegroundColor Green
        }

        Write-Host ""
        Write-Host "  File exports complete." -ForegroundColor Cyan
        Write-Host ("=" * 68) -ForegroundColor Cyan
    }

    # ---- Out-HtmlView (live browser viewer, default-on) ---------------------
    if ($script:RunHtmlView) {
        Write-Host ""
        Write-Host ("=" * 68) -ForegroundColor Cyan
        Write-Host "  OUT-HTMLVIEW  --  opening in default browser..." -ForegroundColor Yellow
        Write-Host ("=" * 68) -ForegroundColor Cyan

        # If HTML file export was NOT selected, write the shared HTML artefact now
        if (-not ($script:SelectedMethods | Where-Object { $_.Name -eq 'HTML' })) {
            $htmlRows | ConvertTo-Html `
                -Title      $htmlTitle `
                -PreContent $htmlPreContent `
                -Property   '#', 'Output' |
            Set-Content -Path $script:HtmlFilePath -Encoding UTF8 -Force
        }

        # Open the single HTML file (already on disk) in the browser via Out-HtmlView
        $htmlRows | Out-HtmlView `
            -Title    $htmlTitle `
            -FilePath $script:HtmlFilePath `
            -Online

        Write-Host "  Launched in browser. File saved:" -ForegroundColor Green
        Write-Host "    $($script:HtmlFilePath)" -ForegroundColor DarkGray
        Write-Host ("=" * 68) -ForegroundColor Cyan
    }

    # Remove the temp transcript once all exports are done
    Remove-Item -Path $script:TranscriptPath -Force -ErrorAction SilentlyContinue
}











