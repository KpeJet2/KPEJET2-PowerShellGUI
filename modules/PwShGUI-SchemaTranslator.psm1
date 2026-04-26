# VersionTag: 2604.B1.V32.2
# SupportPS5.1: YES(As of: 2026-04-21)
# SupportsPS7.6: YES(As of: 2026-04-21)
# SupportPS5.1TestedDate: 2026-04-21
# SupportsPS7.6TestedDate: 2026-04-21
# Author: The Establishment
# Date: 2026-04-05
# FileRole: Module
# Module: PwShGUI-SchemaTranslator
#
# Provides schema detection, validation, and upgrade transforms for PwShGUI scan data files.
# Applies transform chains defined in config/scan-schema-version-map.json to convert legacy
# scan output to the current DependencyMap/1.0 schema so that all downstream Reports and tools
# can use a single canonical data shape.
#
# PUBLIC FUNCTIONS:
#   Get-ScanSchemaVersion       — detect the schema version of a scan data file or object
#   Test-ScanSchemaCompatibility — validate a scan object against a given schema version
#   Convert-ScanSchema          — apply the transform chain to upgrade scan data to target schema
#   Get-SchemaTransformPlan     — return the ordered transform steps for a given version pair
# TODO: HelpMenu | Show-SchemaTranslatorHelp | Actions: Translate|Validate|Export|Help | Spec: config/help-menu-registry.json

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$script:_SchemaMapPath = $null  # resolved lazily in Get-SchemaMap

# ─── Internals ────────────────────────────────────────────────────────────────────

function Get-SchemaMap {
    [CmdletBinding()]
    param()
    if ($null -ne $script:_SchemaMapPath -and (Test-Path -LiteralPath $script:_SchemaMapPath)) {
        try {
            $raw = Get-Content -LiteralPath $script:_SchemaMapPath -Raw -Encoding UTF8
            $map = $raw | ConvertFrom-Json
            return $map
        } catch {
            Write-Warning "[SchemaTranslator] Failed to parse schema map: $_"
            return $null
        }
    }
    # Auto-discover: search up from module location for config/scan-schema-version-map.json
    $searchBase = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $candidates = @(
        (Join-Path (Join-Path $PSScriptRoot '..' -Resolve) 'config\scan-schema-version-map.json'),
        (Join-Path $searchBase 'config\scan-schema-version-map.json')
    )
    foreach ($c in $candidates) {
        $abs = [System.IO.Path]::GetFullPath($c)
        if (Test-Path -LiteralPath $abs) {
            $script:_SchemaMapPath = $abs
            try {
                $raw = Get-Content -LiteralPath $abs -Raw -Encoding UTF8
                return ($raw | ConvertFrom-Json)
            } catch {
                Write-Warning "[SchemaTranslator] Failed to parse schema map at ${abs}: $_"
                return $null
            }
        }
    }
    Write-Warning '[SchemaTranslator] scan-schema-version-map.json not found. Schema detection will be limited.'
    return $null
}


# ─── PUBLIC: Get-ScanSchemaVersion ────────────────────────────────────────────────

function Get-ScanSchemaVersion {
    <#
    .SYNOPSIS
        Detect the schema version of a scan data file or already-parsed object.
    .DESCRIPTION
        Checks for a 'schemaVersion' field in the root of the data object. If absent, applies
        field-presence heuristics against the entries in scan-schema-version-map.json to infer
        the legacy version. Returns a string like 'DependencyMap/0.9' or 'DependencyMap/1.0'.
    .PARAMETER ScanData
        A PSCustomObject parsed from scan JSON (e.g., from ConvertFrom-Json).
    .PARAMETER FilePath
        Path to a scan JSON file. Mutually exclusive with -ScanData.
    .OUTPUTS
        [string] schema version identifier, or $null if indeterminate.
    .EXAMPLE
        $ver = Get-ScanSchemaVersion -FilePath 'C:\PowerShellGUI\~REPORTS\workspace-map.json'
        # Returns 'DependencyMap/1.0' or 'DependencyMap/0.9'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(ParameterSetName='Object', ValueFromPipeline)]
        [pscustomobject]$ScanData,

        [Parameter(ParameterSetName='File')]
        [string]$FilePath
    )
    process {
        if ($PSCmdlet.ParameterSetName -eq 'File') {
            if ([string]::IsNullOrWhiteSpace($FilePath) -or -not (Test-Path -LiteralPath $FilePath)) {
                Write-Warning "[SchemaTranslator] File not found: $FilePath"
                return $null
            }
            try {
                $raw      = Get-Content -LiteralPath $FilePath -Raw -Encoding UTF8
                $ScanData = $raw | ConvertFrom-Json
            } catch {
                Write-Warning "[SchemaTranslator] Parse error: $_"
                return $null
            }
        }
        if ($null -eq $ScanData) { return $null }

        # 1. Explicit field wins
        if ($ScanData.PSObject.Properties.Name -contains 'schemaVersion') {
            $sv = $ScanData.schemaVersion
            if (-not [string]::IsNullOrWhiteSpace($sv)) { return $sv }
        }

        # 2. Heuristic: if well-known DependencyMap fields exist, treat as 0.9 legacy
        $wellKnown = @('generated','workspace','summary','nodes','edges')
        $matchCount = 0
        foreach ($f in $wellKnown) {
            if ($ScanData.PSObject.Properties.Name -contains $f) { $matchCount++ }
        }
        if ($matchCount -ge 3) {
            return 'DependencyMap/0.9'
        }

        return $null
    }
}


# ─── PUBLIC: Test-ScanSchemaCompatibility ─────────────────────────────────────────

function Test-ScanSchemaCompatibility {
    <#
    .SYNOPSIS
        Validate that a scan data object contains the required fields for a given schema version.
    .DESCRIPTION
        Compares the root fields of the scan object against the 'knownFields.root' list defined
        in scan-schema-version-map.json for the specified schema version. Reports missing fields.
    .PARAMETER ScanData
        PSCustomObject to validate.
    .PARAMETER SchemaVersion
        Target schema to validate against, e.g. 'DependencyMap/1.0'. Defaults to current.
    .OUTPUTS
        PSCustomObject with: IsValid, SchemaVersion, MissingFields, PresentFields
    .EXAMPLE
        Test-ScanSchemaCompatibility -ScanData $parsed -SchemaVersion 'DependencyMap/1.0'
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$ScanData,

        [string]$SchemaVersion = 'DependencyMap/1.0'
    )
    $map = Get-SchemaMap
    $schemaEntry = $null
    if ($null -ne $map) {
        $schemaEntry = @($map.schemas) | Where-Object { $_.id -eq $SchemaVersion } | Select-Object -First 1
    }
    $requiredFields = if ($null -ne $schemaEntry) { @($schemaEntry.knownFields.root) } else { @('generated','workspace','summary','nodes','edges','schemaVersion') }
    $presentFields  = @($ScanData.PSObject.Properties.Name)
    $missing        = @($requiredFields | Where-Object { $presentFields -notcontains $_ })

    return [pscustomobject]@{
        IsValid        = (@($missing).Count -eq 0)
        SchemaVersion  = $SchemaVersion
        MissingFields  = $missing
        PresentFields  = $presentFields
    }
}


# ─── PUBLIC: Get-SchemaTransformPlan ─────────────────────────────────────────────

function Get-SchemaTransformPlan {
    <#
    .SYNOPSIS
        Return the ordered list of transform operations to upgrade from one schema to another.
    .PARAMETER FromSchema
        Source schema version identifier.
    .PARAMETER ToSchema
        Target schema version identifier. Defaults to 'DependencyMap/1.0'.
    .OUTPUTS
        Array of transform operation objects from the version map config.
    .EXAMPLE
        Get-SchemaTransformPlan -FromSchema 'DependencyMap/0.9'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$FromSchema,

        [string]$ToSchema = 'DependencyMap/1.0'
    )
    if ($FromSchema -eq $ToSchema) { return @() }
    $map = Get-SchemaMap
    if ($null -eq $map) { return @() }

    # Simple linear chain resolution: find transform whose fromSchema = $FromSchema, etc.
    $plan = [System.Collections.ArrayList]@()
    $current = $FromSchema
    $maxSteps = 20  # safety guard against circular transforms — P021: $maxSteps -gt 0 guarded below
    $steps = 0
    while ($current -ne $ToSchema -and $steps -lt $maxSteps) {
        $xform = @($map.transforms) | Where-Object { $_.fromSchema -eq $current } | Select-Object -First 1
        if ($null -eq $xform) {
            Write-Warning "[SchemaTranslator] No transform found for '$current' → '$ToSchema'."
            break
        }
        $null = $plan.Add($xform)
        $current = $xform.toSchema
        $steps++
    }
    return @($plan)
}


# ─── PUBLIC: Convert-ScanSchema ───────────────────────────────────────────────────

function Convert-ScanSchema {
    <#
    .SYNOPSIS
        Apply the transform chain to upgrade scan data to the target schema version.
    .DESCRIPTION
        Detects the source schema version, computes the transform plan, and applies each
        operation in sequence. This is non-destructive: each operation clones the field set.
        Returns the upgraded PSCustomObject with a schemaVersion field set to $ToSchema.
    .PARAMETER ScanData
        PSCustomObject to convert. Not mutated — a new object is returned.
    .PARAMETER FilePath
        Path to a scan JSON file. Mutually exclusive with -ScanData.
    .PARAMETER ToSchema
        Target schema version. Defaults to 'DependencyMap/1.0'.
    .PARAMETER PassThru
        When set with -FilePath, writes the upgraded object back to the same file.
    .OUTPUTS
        PSCustomObject with the upgraded scan data.
    .EXAMPLE
        $upgraded = Convert-ScanSchema -FilePath 'C:\PowerShellGUI\~REPORTS\old-scan.json'
        $upgraded | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath 'old-scan-upgraded.json' -Encoding UTF8
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(ParameterSetName='Object', ValueFromPipeline)]
        [pscustomobject]$ScanData,

        [Parameter(ParameterSetName='File')]
        [string]$FilePath,

        [string]$ToSchema = 'DependencyMap/1.0',

        [switch]$PassThru
    )
    process {
        if ($PSCmdlet.ParameterSetName -eq 'File') {
            if ([string]::IsNullOrWhiteSpace($FilePath) -or -not (Test-Path -LiteralPath $FilePath)) {
                Write-Warning "[SchemaTranslator] File not found: $FilePath"
                return $null
            }
            try {
                $raw      = Get-Content -LiteralPath $FilePath -Raw -Encoding UTF8
                $ScanData = $raw | ConvertFrom-Json
            } catch {
                Write-Warning "[SchemaTranslator] Parse error: $_"
                return $null
            }
        }
        if ($null -eq $ScanData) { return $null }

        $fromSchema = Get-ScanSchemaVersion -ScanData $ScanData
        if ($fromSchema -eq $ToSchema) {
            Write-Verbose "[SchemaTranslator] Already at target schema '$ToSchema'. No transform needed."
            return $ScanData
        }

        $plan = Get-SchemaTransformPlan -FromSchema $fromSchema -ToSchema $ToSchema
        if (@($plan).Count -eq 0) {
            Write-Warning "[SchemaTranslator] No transform path from '$fromSchema' to '$ToSchema'."
            return $ScanData
        }

        # Clone via JSON round-trip to avoid mutating source
        $workObj = ($ScanData | ConvertTo-Json -Depth 8) | ConvertFrom-Json

        foreach ($xform in $plan) {
            Write-Verbose "[SchemaTranslator] Applying: $($xform.id)"
            foreach ($op in @($xform.operations)) {
                if ($op.op -eq 'add-field' -and $op.target -eq 'root') {
                    $alreadyHas = $workObj.PSObject.Properties.Name -contains $op.field
                    if (($op.ifMissing -eq $true) -and $alreadyHas) { continue }
                    if ($alreadyHas) {
                        $workObj.PSObject.Properties.Remove($op.field)
                    }
                    # Re-create object with field placed first
                    if ($op.position -eq 'first') {
                        $newObj = [pscustomobject]@{}
                        $newObj | Add-Member -MemberType NoteProperty -Name $op.field -Value $op.value
                        foreach ($prop in $workObj.PSObject.Properties) {
                            if ($prop.Name -ne $op.field) {
                                $newObj | Add-Member -MemberType NoteProperty -Name $prop.Name -Value $prop.Value
                            }
                        }
                        $workObj = $newObj
                    } else {
                        $workObj | Add-Member -MemberType NoteProperty -Name $op.field -Value $op.value -Force
                    }
                }
                elseif ($op.op -eq 'rename-field' -and $op.target -eq 'root') {
                    if ($workObj.PSObject.Properties.Name -contains $op.field) {
                        $val = $workObj.$($op.field)
                        $workObj.PSObject.Properties.Remove($op.field)
                        $workObj | Add-Member -MemberType NoteProperty -Name $op.newField -Value $val
                    }
                }
                elseif ($op.op -eq 'remove-field' -and $op.target -eq 'root') {
                    if ($workObj.PSObject.Properties.Name -contains $op.field) {
                        $workObj.PSObject.Properties.Remove($op.field)
                    }
                }
            }
        }

        # Stamp final schema version
        if ($workObj.PSObject.Properties.Name -contains 'schemaVersion') {
            $workObj.schemaVersion = $ToSchema
        } else {
            $workObj | Add-Member -MemberType NoteProperty -Name 'schemaVersion' -Value $ToSchema -Force
        }

        if ($PassThru -and $PSCmdlet.ParameterSetName -eq 'File') {
            if ($PSCmdlet.ShouldProcess($FilePath, "Write upgraded schema ($fromSchema → $ToSchema)")) {
                ConvertTo-Json -InputObject $workObj -Depth 8 |
                    Set-Content -LiteralPath $FilePath -Encoding UTF8
                Write-Verbose "[SchemaTranslator] Written upgraded schema to $FilePath"
            }
        }

        return $workObj
    }
}


# ─── Module exports ───────────────────────────────────────────────────────────────

<# Outline:
    Stub: describe module/script purpose here.
#>

<# Problems:
    Stub: list known issues here.
#>

<# ToDo:
    Stub: list pending work here.
#>
Export-ModuleMember -Function @(
    'Get-ScanSchemaVersion',
    'Test-ScanSchemaCompatibility',
    'Get-SchemaTransformPlan',
    'Convert-ScanSchema'
)





