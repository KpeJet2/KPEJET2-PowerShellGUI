# VersionTag: 2608.B1.V54.2
BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $modulePath = Join-Path (Join-Path $repoRoot 'modules') 'PwShGUI-PipelineFlowGraph.psm1'
    Import-Module -Name $modulePath -Force
}

Describe 'PwShGUI-PipelineFlowGraph' {
    It 'builds a graph object from the configured sources' {
        $graph = Get-PipelineFlowGraph -WorkspacePath $repoRoot
        $graph.SchemaVersion | Should -Be 'CronPipeFlow/1.0'
        @($graph.nodes).Count | Should -BeGreaterThan 0
    }

    It 'produces deterministic hash values for unchanged input' {
        $a = Get-PipelineFlowGraph -WorkspacePath $repoRoot
        $b = Get-PipelineFlowGraph -WorkspacePath $repoRoot
        $a.graphHash | Should -Be $b.graphHash
    }

    It 'exports graph json with UTF8 encoding path output' {
        $graph = Get-PipelineFlowGraph -WorkspacePath $repoRoot
        $tempOut = Join-Path (Join-Path $repoRoot 'temp') 'pipeline-flow-graph-test.json'
        try {
            $path = Export-PipelineFlowGraph -Graph $graph -OutputPath $tempOut
            Test-Path -LiteralPath $path | Should -BeTrue
        } finally {
            Remove-Item -LiteralPath $tempOut -Force -ErrorAction SilentlyContinue
        }
    }
}
