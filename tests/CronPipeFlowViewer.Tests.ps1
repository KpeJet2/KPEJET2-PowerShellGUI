# VersionTag: 2608.B1.V54.2

Describe 'XHTML-Cron-Pipe-Flow scaffold' {
    It 'exists and is parseable as XML' {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        $viewerPath = Join-Path $repoRoot 'XHTML-Cron-Pipe-Flow.xhtml'
        Test-Path -LiteralPath $viewerPath | Should -BeTrue
        $raw = Get-Content -LiteralPath $viewerPath -Raw -Encoding UTF8
        { [xml]$raw | Out-Null } | Should -Not -Throw
    }

    It 'contains data injection placeholders' {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        $viewerPath = Join-Path $repoRoot 'XHTML-Cron-Pipe-Flow.xhtml'
        $raw = Get-Content -LiteralPath $viewerPath -Raw -Encoding UTF8
        $raw | Should -Match 'FLOW_GRAPH_DATA'
        $raw | Should -Match 'FLOW_GRAPH_HASH'
    }
}
