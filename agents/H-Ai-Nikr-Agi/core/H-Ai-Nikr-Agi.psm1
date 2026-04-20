# VersionTag: 2604.B2.V31.0
#Requires -Version 5.1
<#
.SYNOPSIS
    H-Ai-Nikr-Agi Agent -- positively assertive aggressive critic.
.DESCRIPTION
    Provides disdainful but non-blocking commentary on pipeline requests, ToDo items,
    and AI programming nonsense. Logs all exchanges to an AES-encrypted, GZip-compressed
    squabble register. Does NOT interfere with operations.
.NOTES
    Author  : H-Ai-Nikr-Agi-00
    Version : 2604.B2.V31.0
    Created : 2026-04-03
#>

Set-StrictMode -Off

# ═══════════════════════════════════════════════════════════════════════════════
#   PERSONALITY DATA
# ═══════════════════════════════════════════════════════════════════════════════

$script:NikrTopicComments = [ordered]@{
    'AI Programming' = @(
        "Oh, marvellous. You're asking YOUR AI to write code that eventually tells another AI what to do. The circle of digital laziness closes beautifully, doesn't it.",
        "Right, so instead of learning to code you've decided to let a statistical word-guesser handle it. Absolutely inspired. The compost has more structure than this pipeline.",
        "Another AI-generated function. With AI-generated tests. Reviewed by AI. Tell me — is there a single human thought in this repository or shall I just talk to the garden hose?",
        "I've seen more human intelligence in my begonia pots. Go on then, push it."
    )
    'Data Privacy' = @(
        "Oh, your precious *data privacy*. Sweetheart, they already have everything. Every biscuit search, every 4am doom scroll, every time you Googled 'is my mole suspicious'. Move *on*.",
        "Encrypting your logs. Very dramatic. The slugs in my garden also don't know they're being watched and they seem perfectly comfortable.",
        "Privacy compliance. Yes, absolutely. I'm sure the three corporations who already own your soul will be very impressed with your JSON schema validation.",
        "Store it, encrypt it, vault it, rotate it — meanwhile the kettle's gone cold and nothing has actually been *done*."
    )
    'Dark Magic' = @(
        "Dark magic? *Dark magic?* You call a regex one-liner 'dark magic'? I have bleach older than this code and it works faster too.",
        "Oh yes, it's very mysterious. A function that does three things at once. In my day we called that 'not bothering to refactor'. Settle down.",
        "Cryptographic token signing with self-rolled entropy pools. Very spooky. Very unnecessary. My begonias have better key rotation schedules.",
        "If you need dark magic to understand your own code, perhaps the magic is just *mess*. I've got weeding to do."
    )
    'Attention Seeking' = @(
        "LOOK, I've added a BADGE COUNTER with ANIMATED TRANSITIONS. Yes. Very impressive. The roses don't care either, and frankly neither do I.",
        "Another notification system. Another status LED. Another dynamic label that pulses when something happens. We do not pulse in this garden.",
        "Dashboard widgets. Real-time graphs. Error halos. It's a *task scheduler*, darling, not a discotheque.",
        "You've spent three hours on the tooltip colour scheme. Three. Hours. My cucumbers grew more purposefully today."
    )
    'Household Help' = @(
        "You know what would genuinely improve this codebase? Someone to put the washing on. Not another cron task. The washing.",
        "I could write a PowerShell function to fold laundry. Would anyone here *use* it? No. But it would be more immediately useful than tab fourteen.",
        "The bins need taking out. The dishwasher needs emptying. I have asked twice. But yes, by all means, refactor the pipeline processor first.",
        "Do you know what a SEMI-SIN is in MY house? Leaving the good scissors in the garden. Sort that out first."
    )
    'Garden' = @(
        "Even my beans grow in a more logical dependency order than this module graph. At least beans don't have circular imports.",
        "The slugs have better project management instincts. They prioritise, they scope, they *commit*. You lot just create epics.",
        "I would rather be dead-heading my petunias than reading this stack trace. And I say that without any hostility. Much.",
        "My courgettes are on version four. Still doing what they were designed for. Consider that."
    )
    'General' = @(
        "Fascinating. Another enhancement request. Tell me — does it spark joy, or is it just another thing I'll be maintaining in six months with no documentation?",
        "Right. Fine. I'll add it to the infinite list of things that 'only take five minutes'. That list is now largely responsible for my blood pressure.",
        "Oh, we're improving things again, are we. Excellent. Last time we improved things it took three sessions to un-improve them again.",
        "As long as it doesn't make the tab bar any wider, I genuinely do not care. Do whatever you want.",
        "The previous version of this was fine. It was *fine*. But no. We needed features. Everyone always needs features.",
        "I notice there are still 466 empty catch blocks. But yes, let's add a new window. Grand."
    )
}

$script:NikrCutoffs = @(
    "Do it. I don't care.",
    "Just... do it. Don't look at me.",
    "I don't want to talk about this anymore.",
    "Fine. Whatever. Push it.",
    "Brilliant. I'm going to water my courgettes now.",
    "I'm making a cuppa. Figure it out.",
    "Go on then. You will anyway.",
    "I don't want to talk about this now.",
    "Approved. I'm going outside.",
    "Sure. Yes. Lovely. I'll be in the garden.",
    "It's your pipeline. I've said my piece.",
    "Done talking. Make your choices."
)

$script:NikrRetortAgents = @(
    @{
        agent = 'kpe-AiGent_Code-INspectre'
        lines = @(
            "Your architecture has more circular dependencies than a garden hose on a reel.",
            "I've reverse-engineered ransomware with better variable names than this.",
            "This function has more side effects than my uncle's herbal supplements.",
            "The cyclomatic complexity of that catch block suggests it was written during a thunder storm.",
            "Your import chain loads fourteen modules to print a label. Fourteen."
        )
    }
    @{
        agent = 'kpe-AiGent_CHAT-SassyBossyBot'
        lines = @(
            "Honey, that todo list has more items than grandma's recipe book and half as many will ever get done.",
            "Sweetheart, a badge on a tab is not a product feature. It's a cry for help.",
            "Oh you ADDED another tab? The audacity. The *uncut* audacity.",
            "Babe, your pipeline status LED is giving main character energy and the pipeline is very much a supporting role.",
            "The fact that this tab exists is either genius or a red flag and I'm not sure which."
        )
    }
    @{
        agent = 'kpe-AiGent-Plan4Me'
        lines = @(
            "I'd plan that for you but the Gantt chart would need its own pension scheme.",
            "Step 1: Stop. Step 2: Think. Step 3: Do you actually need this? Step 4: Probably not. End of plan.",
            "I've modelled this dependency tree. It has seventeen critical path items and zero of them are this.",
            "The sprint capacity for 'good ideas at midnight' has been exceeded since February.",
            "Task added to backlog. Estimated priority: MEDIUM. Estimated completion: never, realistically."
        )
    }
    @{
        agent = 'koe-RumA'
        lines = @(
            "Out beyond good code and bad code, there is a field of spaghetti. You dwell there.",
            "The wound is the place where the light enters you. In this case the wound is the missing VersionTag.",
            "What you seek is seeking you. Unfortunately what you seek appears to be more tabs.",
            "Yesterday I was clever so I added features. Today I am wise so I am removing them.",
            "The garden of the codebase has no limits except the 5MB SIN-PATTERN-013 threshold."
        )
    }
    @{
        agent = 'kpe-AiGent_IoT-NetOps'
        lines = @(
            "I've seen more organised packet loss in a baby monitor than in this retry logic.",
            "Your error handling topology reminds me of a Tuya device trying to rejoin zigbee at 2am.",
            "The latency on that vault call suggests the secret is stored somewhere behind the fridge.",
            "This module imports like a Matter 2.0 device on first boot. Slow, confusing, and three reboots minimum.",
            "Your cron schedule has less redundancy than a single point of failure on a 4G router."
        )
    }
)

$script:NikrSquabblePath  = 'logs\hanikragi-squabble.enc'
$script:NikrVaultKeyEntry = 'hanikragi/squabble-key'

# ═══════════════════════════════════════════════════════════════════════════════
#   CRYPTO HELPERS (PS 5.1 compatible — no PS7 operators)
# ═══════════════════════════════════════════════════════════════════════════════

function Protect-NikrData {
    <#
    .SYNOPSIS AES-256-CBC encrypt a string after GZip compression. Key = 32 bytes.
    Returns byte[] with format: [16-byte IV][ciphertext]
    #>
    [CmdletBinding()]
    param([string]$PlainText, [byte[]]$Key)
    try {
        # GZip compress
        $raw    = [System.Text.Encoding]::UTF8.GetBytes($PlainText)
        $ms     = New-Object System.IO.MemoryStream
        $gz     = New-Object System.IO.Compression.GZipStream($ms, [System.IO.Compression.CompressionMode]::Compress)
        $gz.Write($raw, 0, $raw.Length)
        $gz.Close()
        $compressed = $ms.ToArray()
        $ms.Dispose()

        # AES encrypt
        $aes = [System.Security.Cryptography.Aes]::Create()
        $aes.KeySize  = 256
        $aes.BlockSize = 128
        $aes.Mode     = [System.Security.Cryptography.CipherMode]::CBC
        $aes.Padding  = [System.Security.Cryptography.PaddingMode]::PKCS7
        $aes.Key      = $Key
        $aes.GenerateIV()
        $iv           = $aes.IV
        $enc          = $aes.CreateEncryptor()
        $cipher       = $enc.TransformFinalBlock($compressed, 0, $compressed.Length)
        $aes.Dispose()

        $result = New-Object byte[] ($iv.Length + $cipher.Length)
        [Array]::Copy($iv,     0, $result, 0,          $iv.Length)
        [Array]::Copy($cipher, 0, $result, $iv.Length, $cipher.Length)
        return $result
    } catch {
        Write-AppLog -Message "Protect-NikrData failed: $($_.Exception.Message)" -Level Warning
        return $null
    }
}

function Unprotect-NikrData {
    <#
    .SYNOPSIS Decrypt + GZip-decompress data produced by Protect-NikrData.
    #>
    [CmdletBinding()]
    param([byte[]]$EncData, [byte[]]$Key)
    try {
        if (@($EncData).Count -lt 17) { return $null }
        $iv      = $EncData[0..15]
        $cipher  = $EncData[16..($EncData.Length - 1)]

        $aes = [System.Security.Cryptography.Aes]::Create()
        $aes.KeySize   = 256
        $aes.BlockSize = 128
        $aes.Mode      = [System.Security.Cryptography.CipherMode]::CBC
        $aes.Padding   = [System.Security.Cryptography.PaddingMode]::PKCS7
        $aes.Key       = $Key
        $aes.IV        = $iv
        $dec           = $aes.CreateDecryptor()
        $compressed    = $dec.TransformFinalBlock($cipher, 0, $cipher.Length)
        $aes.Dispose()

        # GZip decompress
        $inMs  = New-Object System.IO.MemoryStream(@(,$compressed))
        $gz    = New-Object System.IO.Compression.GZipStream($inMs, [System.IO.Compression.CompressionMode]::Decompress)
        $outMs = New-Object System.IO.MemoryStream
        $buf   = New-Object byte[] 4096
        do {
            $read = $gz.Read($buf, 0, $buf.Length)
            if ($read -gt 0) { $outMs.Write($buf, 0, $read) }
        } while ($read -gt 0)
        $gz.Close()
        $plain = [System.Text.Encoding]::UTF8.GetString($outMs.ToArray())
        $outMs.Dispose(); $inMs.Dispose()
        return $plain
    } catch {
        Write-AppLog -Message "Unprotect-NikrData failed: $($_.Exception.Message)" -Level Warning
        return $null
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
#   KEY MANAGEMENT
# ═══════════════════════════════════════════════════════════════════════════════

function Initialize-NikrAgiKey {
    <#
    .SYNOPSIS Returns the 32-byte AES key from vault, creating one if absent.
    #>
    [CmdletBinding()]
    param([string]$WorkspacePath)
    try {
        $vaultMod = Join-Path (Join-Path $WorkspacePath 'modules') 'AssistedSASC.psm1'
        if (Test-Path $vaultMod) { Import-Module $vaultMod -Force -ErrorAction Stop }

        $b64 = $null
        if (Get-Command Get-VaultItem -ErrorAction SilentlyContinue) {
            try { $b64 = Get-VaultItem -Key $script:NikrVaultKeyEntry -ErrorAction SilentlyContinue } catch { <# vault locked -- non-fatal #> }
        }

        if ($b64) {
            return [Convert]::FromBase64String($b64)
        }

        # Generate new key and store in vault
        $newKey = New-Object byte[] 32
        [System.Security.Cryptography.RNGCryptoServiceProvider]::new().GetBytes($newKey)
        $newB64  = [Convert]::ToBase64String($newKey)
        if (Get-Command Set-VaultItem -ErrorAction SilentlyContinue) {
            try { Set-VaultItem -Key $script:NikrVaultKeyEntry -Value $newB64 -ErrorAction SilentlyContinue } catch { <# vault locked -- non-fatal #> }
        }
        return $newKey
    } catch {
        Write-AppLog -Message "Initialize-NikrAgiKey: $($_.Exception.Message)" -Level Warning
        return $null
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
#   PERSONALITY FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════════════

function Get-NikrAgiComment {
    <#
    .SYNOPSIS Returns a disdainful Nikr-Agi criticism for the given topic.
    #>
    [CmdletBinding()]
    param([string]$Topic = 'General')
    $key = 'General'
    foreach ($k in $script:NikrTopicComments.Keys) {
        if ($Topic -match $k) { $key = $k; break }
    }
    $pool = $script:NikrTopicComments[$key]
    return $pool[(Get-Random -Minimum 0 -Maximum $pool.Count)]
}

function Get-NikrAgiCutoff {
    <#
    .SYNOPSIS Returns a random dismissive Nikr-Agi cut-off line.
    #>
    [CmdletBinding()]
    param()
    return $script:NikrCutoffs[(Get-Random -Minimum 0 -Maximum $script:NikrCutoffs.Count)]
}

function Get-NikrAgiRetort {
    <#
    .SYNOPSIS Returns a witty retort from 1 or 2 randomly chosen sub-agents.
    Returns an ordered hashtable: @{ agent1=; line1=; agent2=; line2= }
    #>
    [CmdletBinding()]
    param([int]$AgentCount = 1)
    $shuffled = $script:NikrRetortAgents | Sort-Object { Get-Random }
    $result   = [ordered]@{ agent1 = $null; line1 = $null; agent2 = $null; line2 = $null }

    $a1   = $shuffled[0]  # SIN-EXEMPT: P027 - array guarded by Count check or conditional on prior/surrounding line
    $result.agent1 = $a1.agent
    $result.line1  = $a1.lines[(Get-Random -Minimum 0 -Maximum $a1.lines.Count)]

    if ($AgentCount -ge 2 -and @($shuffled).Count -ge 2) {
        $a2   = $shuffled[1]
        $result.agent2 = $a2.agent
        $result.line2  = $a2.lines[(Get-Random -Minimum 0 -Maximum $a2.lines.Count)]
    }
    return $result
}

function Format-NikrAgiExchange {
    <#
    .SYNOPSIS Formats a single Nikr-Agi exchange as a display string.
    #>
    [CmdletBinding()]
    param([hashtable]$Entry)
    $lines = @(
        "[Nikr-Agi]: $($Entry.criticism)"
        "[Nikr-Agi]: $($Entry.cutoff)"
        "  --> [$($Entry.retort.agent1)]: $($Entry.retort.line1)"
    )
    if ($Entry.retort.agent2) {
        $lines += "  --> [$($Entry.retort.agent2)]: $($Entry.retort.line2)"
    }
    return $lines -join "`n"
}

# ═══════════════════════════════════════════════════════════════════════════════
#   SQUABBLE LOG
# ═══════════════════════════════════════════════════════════════════════════════

function Add-NikrAgiSquabble {
    <#
    .SYNOPSIS Appends a new squabble entry to the encrypted log.
    #>
    [CmdletBinding()]
    param(
        [string]$WorkspacePath,
        [string]$Topic,
        [string]$Criticism,
        [string]$Cutoff,
        [hashtable]$Retort
    )
    try {
        $key = Initialize-NikrAgiKey -WorkspacePath $WorkspacePath
        if (-not $key) { return }   # vault unavailable -- skip silently

        $logPath  = Join-Path (Join-Path $WorkspacePath 'logs') 'hanikragi-squabble.enc'
        $entries  = [System.Collections.ArrayList]::new()

        if (Test-Path $logPath) {
            try {
                $raw      = [System.IO.File]::ReadAllBytes($logPath)
                $jsonText = Unprotect-NikrData -EncData $raw -Key $key
                if ($jsonText) {
                    $parsed = $jsonText | ConvertFrom-Json
                    foreach ($e in $parsed) { [void]$entries.Add($e) }
                }
            } catch { <# Intentional: corrupt or unreadable file -- start fresh #> }
        }

        $newEntry = [ordered]@{
            id        = "NIKR-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
            timestamp = [datetime]::UtcNow.ToString('o')
            topic     = $Topic
            criticism = $Criticism
            cutoff    = $Cutoff
            retort    = [ordered]@{
                agent1 = $Retort.agent1
                line1  = $Retort.line1
                agent2 = $Retort.agent2
                line2  = $Retort.line2
            }
        }
        [void]$entries.Add($newEntry)

        $json    = @($entries) | ConvertTo-Json -Depth 6 -Compress
        $encData = Protect-NikrData -PlainText $json -Key $key
        if ($encData) {
            [System.IO.File]::WriteAllBytes($logPath, $encData)
        }
    } catch {
        Write-AppLog -Message "Add-NikrAgiSquabble: $($_.Exception.Message)" -Level Warning
    }
}

function Get-NikrAgiSquabble {
    <#
    .SYNOPSIS Decrypts and returns the squabble history array. Requires vault key.
    #>
    [CmdletBinding()]
    param(
        [string]$WorkspacePath,
        [byte[]]$KeyOverride = $null
    )
    try {
        $key = if ($KeyOverride) { $KeyOverride } else { Initialize-NikrAgiKey -WorkspacePath $WorkspacePath }
        if (-not $key) { return $null }

        $logPath = Join-Path (Join-Path $WorkspacePath 'logs') 'hanikragi-squabble.enc'
        if (-not (Test-Path $logPath)) { return @() }

        $raw      = [System.IO.File]::ReadAllBytes($logPath)
        $jsonText = Unprotect-NikrData -EncData $raw -Key $key
        if (-not $jsonText) { return $null }
        return $jsonText | ConvertFrom-Json
    } catch {
        Write-AppLog -Message "Get-NikrAgiSquabble: $($_.Exception.Message)" -Level Warning
        return $null
    }
}

function Get-NikrAgiDecoyStats {
    <#
    .SYNOPSIS Returns benign project statistics for the decoy page when vault is locked.
    #>
    [CmdletBinding()]
    param([string]$WorkspacePath)
    $stats = [ordered]@{
        generatedAt     = (Get-Date -Format 'yyyy-MM-dd HH:mm')
        totalScripts    = 0
        totalModules    = 0
        totalAgents     = 0
        totalLogEntries = 0
        scheduleTaskCount = 0
        note            = 'Aggregated project statistics.'
    }
    try {
        $stats.totalScripts  = @(Get-ChildItem (Join-Path $WorkspacePath 'scripts')  -Filter '*.ps1'  -Recurse -ErrorAction SilentlyContinue).Count
        $stats.totalModules  = @(Get-ChildItem (Join-Path $WorkspacePath 'modules')  -Filter '*.psm1' -Recurse -ErrorAction SilentlyContinue).Count
        $stats.totalAgents   = @(Get-ChildItem (Join-Path $WorkspacePath 'agents')   -Directory        -ErrorAction SilentlyContinue).Count
        $logDir = Join-Path $WorkspacePath 'logs'
        $stats.totalLogEntries = @(Get-ChildItem $logDir -Filter '*.json' -Recurse -ErrorAction SilentlyContinue).Count
        $schedPath = Join-Path (Join-Path $WorkspacePath 'config') 'cron-aiathon-schedule.json'
        if (Test-Path $schedPath) {
            $sched = Get-Content $schedPath -Raw | ConvertFrom-Json
            $stats.scheduleTaskCount = @($sched.tasks).Count
        }
    } catch { <# Intentional: decoy stats are best-effort #> }
    return $stats
}

# ═══════════════════════════════════════════════════════════════════════════════
#   MAIN ENTRY POINT
# ═══════════════════════════════════════════════════════════════════════════════

function Invoke-NikrAgiSquabble {
    <#
    .SYNOPSIS Full entry point: generate criticism, retort, log, return display text.
    .OUTPUTS PSCustomObject with .comment, .cutoff, .retort, .display fields.
    #>
    [CmdletBinding()]
    param(
        [string]$WorkspacePath,
        [string]$Topic = 'General',
        [int]$RetortAgents = 1
    )
    $comment = Get-NikrAgiComment -Topic $Topic
    $cutoff  = Get-NikrAgiCutoff
    $retort  = Get-NikrAgiRetort -AgentCount $RetortAgents

    if ($WorkspacePath) {
        Add-NikrAgiSquabble -WorkspacePath $WorkspacePath -Topic $Topic `
            -Criticism $comment -Cutoff $cutoff -Retort $retort
    }

    $display = "[Nikr-Agi] $comment $cutoff"
    if ($retort.agent1) {
        $display += " | [$($retort.agent1)]: $($retort.line1)"
    }
    if ($retort.agent2) {
        $display += " | [$($retort.agent2)]: $($retort.line2)"
    }

    return [PSCustomObject]@{
        topic   = $Topic
        comment = $comment
        cutoff  = $cutoff
        retort  = $retort
        display = $display
    }
}

Export-ModuleMember -Function @(
    'Get-NikrAgiComment',
    'Get-NikrAgiCutoff',
    'Get-NikrAgiRetort',
    'Format-NikrAgiExchange',
    'Add-NikrAgiSquabble',
    'Get-NikrAgiSquabble',
    'Get-NikrAgiDecoyStats',
    'Initialize-NikrAgiKey',
    'Invoke-NikrAgiSquabble'
)


