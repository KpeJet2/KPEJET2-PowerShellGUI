#Requires -Version 5.1
# VersionTag: 2604.B2.V31.0
# VersionBuildHistory:
#   2603.B0.v19  2026-03-24 03:28  (deduplicated from 4 entries)
<#
.SYNOPSIS
    PowerShell Cheat Sheet - Examples & Reference Script (V1)

.DESCRIPTION
    A runnable reference covering core PowerShell concepts:
    operators, variables, functions, modules, filesystem,
    hashtables, WMI, events, PSDrives, data management, classes,
    and REST APIs.

    Original credit: Trevor Sullivan (pcgeek86)
    https://gist.github.com/pcgeek86/336e08d1a09e3dd1a8f0a30a9fe61c8a

.NOTES
    File    : PS-CheatSheet-EXAMPLES.ps1
    Version : 2604.B2.V31.0 (fixed + annotated)
    Date    : 2026-02-28

.EXAMPLE
    .\PS-CheatSheet-EXAMPLES.ps1
#>

# Helper: print a visible section divider to the console
function Show-Section ([string]$Title) {  # SIN-EXEMPT: P011 - cross-file duplicate (intentional fallback/stub)
    Write-Host ""
    Write-Host ("=" * 60) -ForegroundColor Cyan
    Write-Host "  $Title" -ForegroundColor Yellow
    Write-Host ("=" * 60) -ForegroundColor Cyan
}

###################################################
# Discovery Commands
###################################################
Show-Section "Discovery Commands"

# List every command available to PowerShell (cmdlets + native binaries in $env:PATH)
Get-Command | Select-Object -First 5 | Format-Table Name, CommandType -AutoSize

# Filter commands from modules whose name starts with "Microsoft"
Get-Command -Module Microsoft* | Select-Object -First 5 | Format-Table Name, Source -AutoSize

# Find all commands whose name ends with "item"
Get-Command -Name *item | Select-Object -First 5 | Format-Table Name, CommandType -AutoSize

# Show synopsis of an about_* help topic
Get-Help -Name about_Variables | Select-Object -ExpandProperty Synopsis
# Get brief help info for a specific cmdlet
Get-Help -Name Get-Command     | Select-Object Name, Synopsis
# Get help for a specific parameter
Get-Help -Name Get-Command -Parameter Module | Select-Object Name, Description


###################################################
# Operators
###################################################
Show-Section "Operators"

$a = 2                                         # Basic assignment
$a += 1                                        # Increment  ($a is now 3)
$a -= 1                                        # Decrement  ($a is now 2)
Write-Host "a = $a"

# Comparison operators return $true or $false
$a -eq 0 | Out-Null                            # Equality
$a -ne 5 | Out-Null                            # Not-equal
$a -gt 2 | Out-Null                            # Greater-than
$a -lt 3 | Out-Null                            # Less-than

$FirstName = 'Trevor'
$likeResult = $FirstName -like 'T*'            # Wildcard string match; returns $true
Write-Host "FirstName -like 'T*': $likeResult"

$BaconIsYummy = $true
# Ternary operator (PowerShell 7+): condition ? trueValue : falseValue
$FoodToEat = if ($BaconIsYummy) { 'bacon' } else { 'beets' }
Write-Host "Food to eat: $FoodToEat"

# -in / -notin: check whether a value exists in an array
$inResult    = 'Celery' -in    @('Bacon', 'Sausage', 'Steak', 'Chicken')  # $false
$notinResult = 'Celery' -notin @('Bacon', 'Sausage', 'Steak')             # $true
Write-Host "Celery -in list: $inResult | Celery -notin list: $notinResult"

# -is / -isnot: test the runtime type of a value
Write-Host "5  -is [string] : $(5 -is [string])"        # $false
Write-Host "5  -is [int32]  : $(5 -is [int32])"         # $true
Write-Host "5  -is [int64]  : $(5 -is [int64])"         # $false
Write-Host "'Trevor' -is [int64]   : $('Trevor' -is [int64])"   # $false
Write-Host "'Trevor' -isnot [string]: $('Trevor' -isnot [string])" # $false
Write-Host "'Trevor' -is [string]  : $('Trevor' -is [string])"  # $true
Write-Host "`$true  -is [bool]: $($true  -is [bool])"   # $true
Write-Host "`$false -is [bool]: $($false -is [bool])"   # $true
Write-Host "5 -is [bool]: $(5 -is [bool])"              # $false

###################################################
# Regular Expressions
###################################################
Show-Section "Regular Expressions"

# -match: test a string against a regex; populates the automatic $matches variable
$matchResult = 'Trevor' -match '^T\w*'
Write-Host "-match result : $matchResult"
Write-Host "Matched text  : $($matches[0])"           # Trevor

# -match against an array returns the elements that matched (not a boolean)
$arrayMatches = @('Trevor', 'Billy', 'Bobby') -match '^B'
Write-Host "Array -match '^B': $($arrayMatches -join ', ')"   # Billy, Bobby

# [regex] type accelerator for finding multiple matches inside a single string
$regex       = [regex]'(\w{3,8})'
$multiMatches = $regex.Matches('Trevor Bobby Dillon Joe Jacob').Value
Write-Host "Regex multi-match: $($multiMatches -join ', ')"   # Trevor, Bobby, Dillon, Joe, Jacob

###################################################
# Flow Control
###################################################
Show-Section "Flow Control"

# if / else -- basic conditional
if (1 -eq 1) { Write-Host "if (1 -eq 1) is TRUE" }

# do..while always executes the body at least once (body runs before condition is tested)
do { Write-Host "do..while ran once (condition is false)" } while ($false)

# while loop -- condition is checked BEFORE the body runs; may run 0 times
$counter = 0
while ($counter -lt 3) {
    Write-Host "while loop iteration: $counter"
    $counter++
}

# Infinite loop broken with a conditional break
while ($true) { if (1 -eq 1) { break } }
Write-Host "Escaped infinite while loop."

# for loop -- classic C-style loop with initialiser, condition, and incrementer
for ($i = 0; $i -le 5; $i++) { Write-Host "for loop i=$i" }

# foreach -- iterate over every item in a collection
foreach ($proc in (Get-Process | Select-Object -First 3)) {
    Write-Host "Process: $($proc.Name)"
}

# switch -- exact string match
switch ('test') {
    'test' { Write-Host "switch matched 'test'"; break }
}

# switch with -regex flag -- tests each array element against each pattern
switch -regex (@('Trevor', 'Daniel', 'Bobby')) {
    'o' { Write-Host "Regex switch matched 'o': $PSItem"; break }
}

# switch without break -- a single input can match multiple patterns
switch -regex (@('Trevor', 'Daniel', 'Bobby')) {
    'e' { Write-Host "Matched 'e': $PSItem" }
    'r' { Write-Host "Matched 'r': $PSItem" }
}

###################################################
# Variables
###################################################
Show-Section "Variables"

$a = 0                                         # Initialize variable as integer
[string]$a = 'Trevor'                          # Re-declare with explicit [string] type (valid cast)
Write-Host "String variable a = $a"

# Casting a non-numeric string to [int] THROWS an exception -- always use try/catch
try {
    [int]$b = 'Trevor'
}
catch {
    Write-Host "Expected error casting 'Trevor' to [int]: $($_.Exception.Message)"
}

# Inspect session variables filtered by their Options flags
Get-Variable | Where-Object { $PSItem.Options -contains 'constant' } |
    Select-Object -First 5 | Format-Table Name, Options -AutoSize

Get-Variable | Where-Object { $PSItem.Options -contains 'readonly' } |
    Select-Object -First 5 | Format-Table Name, Options -AutoSize

# Create named variables with SilentlyContinue so re-runs don't error if they already exist
New-Variable -Name CheatsheetFirstName -Value 'Trevor'                         -ErrorAction SilentlyContinue
New-Variable -Name CheatsheetROVar     -Value 'Trevor' -Option ReadOnly        -ErrorAction SilentlyContinue
New-Variable -Name CheatsheetConst     -Value 'Trevor' -Option Constant        -ErrorAction SilentlyContinue

# Remove a normal variable
Remove-Variable -Name CheatsheetFirstName -ErrorAction SilentlyContinue

# -Force is required to remove a ReadOnly variable
Remove-Variable -Name CheatsheetROVar -Force -ErrorAction SilentlyContinue

Write-Host "Variable section complete."

###################################################
# Functions
###################################################
Show-Section "Functions"

# Minimal function with positional parameters -- returns the sum of two numbers
function Add-Numbers ($a, $b) { $a + $b }
Write-Host "Add-Numbers 3 4 = $(Add-Numbers 3 4)"

# Advanced Function -- [CmdletBinding()] unlocks common parameters (-Verbose, -WhatIf, etc.)
# FIX: original had [CmdletBinding(add)] which is invalid syntax.
# FIX: original had begin/process/end closing braces inside comment text (parse error).
function Invoke-PipelineDemo {
    [CmdletBinding()]
    param (
        [Parameter(ValueFromPipeline)]
        [string]$InputItem
    )

    begin {
        # Runs ONCE before any pipeline input -- use for initialisation
        Write-Host "[BEGIN] Function started" -ForegroundColor DarkGray
    }

    process {
        # Runs ONCE PER pipeline object -- main processing logic goes here
        Write-Host "[PROCESS] Received: $InputItem" -ForegroundColor DarkGray
    }

    end {
        # Runs ONCE after all pipeline objects are processed -- use for cleanup/summary
        Write-Host "[END] Function finished" -ForegroundColor DarkGray
    }
}

# Pipe three strings through the advanced function to demonstrate each block
'Alpha', 'Beta', 'Gamma' | Invoke-PipelineDemo

###################################################
# Working with Modules
###################################################
Show-Section "Working with Modules"

# Find commands that deal with modules (from the core PowerShell module)
Get-Command -Name *module* -Module Mic*Core | Format-Table Name -AutoSize

# List all installed modules tracked in $env:PSModulePath
Get-Module -ListAvailable | Select-Object -First 5 | Format-Table Name, Version -AutoSize

# List modules already loaded into this session
Get-Module | Format-Table Name, Version -AutoSize

# Temporarily disable auto-loading of modules (reset by closing session)
# $PSModuleAutoLoadingPreference = 0

# Explicitly import a module by name (must exist in $env:PSModulePath)
# Import-Module -Name NameIT

# Remove a module from the current session
# Remove-Module -Name NameIT

# Create a lightweight in-memory module (no file required) then import it
$InMemMod = New-Module -Name CheatsheetModule -ScriptBlock {
    function Add-Inline ($a, $b) { $a + $b }
    Export-ModuleMember -Function Add-Inline
}
$InMemMod | Import-Module -Force
Write-Host "In-memory module: Add-Inline 10 20 = $(Add-Inline 10 20)"
Remove-Module -Name CheatsheetModule -ErrorAction SilentlyContinue

###################################################
# Module Management (PowerShellGet)
###################################################
Show-Section "Module Management (PowerShellGet)"

# Explore the PowerShellGet commands available for managing the Gallery
Get-Command -Module PowerShellGet | Select-Object -First 8 | Format-Table Name -AutoSize

# Search the PowerShell Gallery (informational -- commented out to avoid network dependency)
# Find-Module -Tag cloud
# Find-Module -Name ps*

# Install examples (commented out to avoid side-effects during the demo run)
# Install-Module -Name NameIT -Scope CurrentUser -Force   # Non-admin install
# Install-Module -Name NameIT -Force                      # Admin/root install
# Install-Module -Name NameIT -RequiredVersion 1.9.0      # Pin a specific version

# Uninstall (only works for modules installed via Install-Module)
# Uninstall-Module -Name NameIT

# Register/unregister a private repository
# Register-PSRepository   -Name <repo> -SourceLocation <uri>
# Unregister-PSRepository -Name <repo>

Write-Host "Module management examples shown (install/uninstall lines are commented-out for safety)."


###################################################
# Filesystem
###################################################
Show-Section "Filesystem"

# Use $env:TEMP so the path always exists on any Windows system
$testDir  = Join-Path $env:TEMP 'CheatsheetTest'
$testFile = Join-Path $testDir  'myrecipes.txt'

# Create a directory (-Force suppresses error if it already exists)
New-Item -Path $testDir -ItemType Directory -Force | Out-Null
Write-Host "Created directory : $testDir"

# Create files three different ways
New-Item     -Path $testFile              -ItemType File -Force | Out-Null
Set-Content  -Path "$testDir\file2.txt"  -Value '' -Encoding UTF8          # Using Set-Content
[System.IO.File]::WriteAllText("$testDir\file3.txt", '')    # Using .NET BCL
Write-Host "Created test files in $testDir"

# Delete files two different ways
Remove-Item               -Path $testFile          -Force -ErrorAction SilentlyContinue
[System.IO.File]::Delete("$testDir\file3.txt")
Write-Host "Deleted test files."

# Clean up the temp test directory
Remove-Item -Path $testDir -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "Cleaned up: $testDir"

###################################################
# Hashtables (Dictionary)
###################################################
Show-Section "Hashtables"

# @{} syntax creates a hashtable (ordered dictionary-like structure)
$Person = @{
  FirstName = 'Trevor'
  LastName  = 'Sullivan'
  Likes     = @(
    'Bacon',
    'Beer',
    'Software'
  )
}

Write-Host "FirstName        : $($Person.FirstName)"
Write-Host "Last Likes item  : $($Person.Likes[-1])"  # Negative index = last element = 'Software'

$Person.Age = 50                                       # Add a new key/value pair to an existing hashtable at runtime
Write-Host "Age added        : $($Person.Age)"

###################################################
# Windows Management Instrumentation (WMI) (Windows only)
###################################################
Show-Section "WMI / CIM (Windows only)"

# Get-CimInstance is the modern replacement for the deprecated Get-WmiObject
Get-CimInstance -ClassName Win32_BIOS            | Select-Object SMBIOSBIOSVersion, Manufacturer | Format-Table -AutoSize
Get-CimInstance -ClassName Win32_DiskDrive       | Select-Object Model, Size                     | Format-Table -AutoSize
Get-CimInstance -ClassName Win32_PhysicalMemory  | Select-Object BankLabel, Capacity             | Format-Table -AutoSize
Get-CimInstance -ClassName Win32_NetworkAdapter  | Select-Object -First 3 Name, MACAddress       | Format-Table -AutoSize
Get-CimInstance -ClassName Win32_VideoController | Select-Object Name, DriverVersion             | Format-Table -AutoSize

# Enumerate available CIM classes in the root\cimv2 namespace
Get-CimClass   -Namespace root\cimv2    | Select-Object -First 5 | Format-Table CimClassName -AutoSize

# List child namespaces under the root namespace
Get-CimInstance -Namespace root -ClassName __NAMESPACE | Format-Table Name -AutoSize



###################################################
# Asynchronous Event Registration
###################################################
Show-Section "Async Event Registration"

#### FileSystemWatcher -- fires when a new file is created in the watched folder
# FIX: original used hard-coded 'c:\tmp' which may not exist; $env:TEMP is always valid
$WatchPath = $env:TEMP
$Watcher   = [System.IO.FileSystemWatcher]::new($WatchPath)
$null      = Register-ObjectEvent -InputObject $Watcher -EventName Created `
                 -SourceIdentifier 'CheatsheetFSW' -Action {
    Write-Host "FileSystemWatcher: New file detected!" -ForegroundColor Green
}
Write-Host "FileSystemWatcher registered on: $WatchPath"

# Trigger the event artificially to produce visible demo output
$dummyFile = Join-Path $env:TEMP 'cheatsheet_event_test.tmp'
$null      = New-Item -Path $dummyFile -ItemType File -Force
Start-Sleep -Milliseconds 400            # Allow the async action block time to fire
Remove-Item -Path $dummyFile -Force -ErrorAction SilentlyContinue

# Always clean up event subscriptions and associated background jobs when done
Unregister-Event -SourceIdentifier 'CheatsheetFSW' -ErrorAction SilentlyContinue
Remove-Job       -Name           'CheatsheetFSW'   -ErrorAction SilentlyContinue

#### Timer event -- fires on a recurring interval (every N milliseconds)
$Timer = [System.Timers.Timer]::new(5000)   # 5-second interval
$null  = Register-ObjectEvent -InputObject $Timer -EventName Elapsed `
             -SourceIdentifier 'CheatsheetTimer' -Action {
    Write-Host "[Timer] Elapsed event fired." -ForegroundColor Blue
}
$Timer.Start()
Write-Host "Timer started (5-second interval). Not waiting a full cycle for demo brevity."
Start-Sleep -Milliseconds 300
$Timer.Stop()
Unregister-Event -SourceIdentifier 'CheatsheetTimer' -ErrorAction SilentlyContinue
Remove-Job       -Name           'CheatsheetTimer'   -ErrorAction SilentlyContinue

###################################################
# PowerShell Drives (PSDrives)
###################################################
Show-Section "PSDrives"

# List all active PSDrives (filesystem, registry, environment, etc.)
Get-PSDrive | Format-Table Name, Provider, Root -AutoSize

# Create a PSDrive that points to a filesystem location
New-PSDrive -Name HomeDrv -PSProvider FileSystem -Root $HOME -ErrorAction SilentlyContinue | Out-Null
Write-Host "Created PSDrive 'HomeDrv' -> $HOME"

# Push into the PSDrive context, verify location, then return
Push-Location HomeDrv:
Write-Host "Inside HomeDrv: $(Get-Location)"
Pop-Location

# A persistent drive would be visible in Windows Explorer (-Persist flag, requires UNC path)
# New-PSDrive -Name h -PSProvider FileSystem -Root '\\storage\h$\data' -Persist

# Remove the demo drive
Remove-PSDrive -Name HomeDrv -ErrorAction SilentlyContinue
Write-Host "Removed PSDrive 'HomeDrv'."

###################################################
# Data Management
###################################################
Show-Section "Data Management"

# Group-Object -- aggregate objects sharing the same property value
Get-Process | Group-Object -Property Name | Select-Object -First 5 | Format-Table Name, Count -AutoSize

# Sort-Object -- order objects by a chosen property
Get-Process | Sort-Object -Property Id | Select-Object -First 5 | Format-Table Name, Id -AutoSize

# Where-Object -- filter the pipeline to objects matching a condition
Get-Process | Where-Object -FilterScript { $PSItem.Name -match '^c' } |
    Select-Object -First 5 | Format-Table Name -AutoSize

# Abbreviated (comparison) form of Where-Object -- same result, shorter syntax
Get-Process | Where-Object Name -match '^c' |
    Select-Object -First 5 | Format-Table Name -AutoSize

###################################################
# PowerShell Classes
###################################################
Show-Section "PowerShell Classes"

class Person {
  [string] $FirstName                                       # String property -- no default
  [string] $LastName = 'Sullivan'                           # String property with a default value
  [int]    $Age                                             # Integer property

  Person() { }                                              # Default (parameterless) constructor

  Person([string]$FirstName) {                              # Constructor with one string parameter
    $this.FirstName = $FirstName
  }

  [string] FullName() {
    # -f format operator builds the full name string
    return '{0} {1}' -f $this.FirstName, $this.LastName
  }
}

$Person01 = [Person]::new()                                 # Use default constructor
$Person01.FirstName = 'Trevor'
Write-Host "Person01.FullName(): $($Person01.FullName())"   # Trevor Sullivan

$Person02 = [Person]::new('Patricia')                       # Use parameterised constructor
Write-Host "Person02.FullName(): $($Person02.FullName())"   # Patricia Sullivan


class Server {                                              # Models a remote server accessible via SSH
  [string]               $Name
  [System.Net.IPAddress] $IPAddress                         # Strongly typed IP address property
  [string]               $SSHKey   = "$HOME/.ssh/id_rsa"   # Path to private key
  [string]               $Username

  RunCommand([string]$Command) {
    # Calls the ssh binary -- requires SSH to be available in $env:PATH and a live target
    ssh -i $this.SSHKey "$($this.Username)@$($this.Name)" $Command
  }
}

$Server01          = [Server]::new()
$Server01.Name     = 'webserver01.local'
$Server01.Username = 'root'
Write-Host "Server class: $($Server01.Name) / $($Server01.Username)"
# $Server01.RunCommand("hostname")    # Commented out -- requires a live SSH-accessible host

###################################################
# REST APIs
###################################################
Show-Section "REST APIs"

# Invoke-RestMethod deserialises the JSON response into PowerShell objects automatically.
# Splatting (@Params) keeps the call clean and readable.
$RestParams = @{
    Uri         = 'https://api.github.com/events'
    Method      = 'Get'
    Headers     = @{ 'User-Agent' = 'PowerShell-Cheatsheet' }  # GitHub API requires a User-Agent header
    ErrorAction = 'Stop'
}

try {
    $RestResult = Invoke-RestMethod @RestParams
    Write-Host "GitHub /events returned $($RestResult.Count) items."
    $RestResult | Select-Object -First 3 | ForEach-Object {
        Write-Host "  Type: $($_.type)  Repo: $($_.repo.name)"
    }
}
catch {
    Write-Host "REST call failed (network may not be available): $($_.Exception.Message)" -ForegroundColor Red
}
###################################################
# Done
###################################################
Show-Section "Cheat Sheet V1 Complete" 
Write-Host "All sections finished successfully." -ForegroundColor Green







