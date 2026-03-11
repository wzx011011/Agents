param(
    [ValidateSet('Claude', 'OpenClaw', 'Both')]
    [string]$Target = 'Both',

    [string]$WorkspaceRoot = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'

function Ensure-Directory {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path | Out-Null
    }
}

function Remove-IfExists {
    param([string]$Path)

    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Recurse -Force
    }
}

function Get-FrontmatterAndBody {
    param([string]$Raw)

    if ($Raw -notmatch '(?s)^---\r?\n(.*?)\r?\n---\r?\n(.*)$') {
        throw 'Unable to parse frontmatter.'
    }

    return @($Matches[1], $Matches[2].Trim())
}

function Get-FrontmatterValue {
    param(
        [string]$Frontmatter,
        [string]$Key,
        [string]$Default = ''
    )

    foreach ($line in ($Frontmatter -split "`r?`n")) {
        if ($line -match ('^' + [regex]::Escape($Key) + ':\s*(.+)$')) {
            return $Matches[1].Trim().Trim("'").Trim('"')
        }
    }

    return $Default
}

function Convert-AgentToClaude {
    param(
        [string]$SourcePath,
        [string]$DestinationPath
    )

    $raw = Get-Content -LiteralPath $SourcePath -Raw -Encoding UTF8
    $parsed = Get-FrontmatterAndBody -Raw $raw
    $frontmatter = $parsed[0]
    $body = $parsed[1]

    $name = Get-FrontmatterValue -Frontmatter $frontmatter -Key 'name'
    $description = Get-FrontmatterValue -Frontmatter $frontmatter -Key 'description'

    if ([string]::IsNullOrWhiteSpace($name)) {
        $name = [IO.Path]::GetFileNameWithoutExtension([IO.Path]::GetFileNameWithoutExtension($SourcePath))
    }

    $output = @(
        '---'
        ('name: ' + $name)
        ('description: ' + $description)
        'tools: Read, Edit, Grep, Glob, Bash'
        '---'
        ''
        $body
        ''
        '## Migration Notes'
        ''
        '- Exported from a VS Code custom agent file.'
        '- VS Code handoffs are not mapped directly. Recreate multi-agent transitions manually if needed.'
    ) -join "`r`n"

    Set-Content -LiteralPath $DestinationPath -Value $output -Encoding UTF8
}

function Convert-InstructionToClaudeRule {
    param(
        [string]$SourcePath,
        [string]$DestinationPath
    )

    $raw = Get-Content -LiteralPath $SourcePath -Raw -Encoding UTF8
    $parsed = Get-FrontmatterAndBody -Raw $raw
    $frontmatter = $parsed[0]
    $body = $parsed[1]

    $name = Get-FrontmatterValue -Frontmatter $frontmatter -Key 'name'
    $description = Get-FrontmatterValue -Frontmatter $frontmatter -Key 'description'
    $applyTo = Get-FrontmatterValue -Frontmatter $frontmatter -Key 'applyTo' -Default '**'

    if ([string]::IsNullOrWhiteSpace($name)) {
        $name = [IO.Path]::GetFileNameWithoutExtension([IO.Path]::GetFileNameWithoutExtension($SourcePath))
    }

    $output = @(
        '---'
        ('name: ' + $name)
        ('description: ' + $description)
        'paths:'
        ('  - ' + $applyTo)
        '---'
        ''
        $body
    ) -join "`r`n"

    Set-Content -LiteralPath $DestinationPath -Value $output -Encoding UTF8
}

function Build-ClaudeMemory {
    param([string]$DestinationPath)

    $agentsMd = Join-Path $WorkspaceRoot 'AGENTS.md'
    $copilotInstructions = Join-Path $WorkspaceRoot '.github\copilot-instructions.md'
    $parts = @()

    if (Test-Path -LiteralPath $agentsMd) {
        $parts += Get-Content -LiteralPath $agentsMd -Raw -Encoding UTF8
    }

    if (Test-Path -LiteralPath $copilotInstructions) {
        if ($parts.Count -gt 0) {
            $parts += "`r`n---`r`n"
        }
        $parts += Get-Content -LiteralPath $copilotInstructions -Raw -Encoding UTF8
    }

    $header = @(
        '# CLAUDE Workspace Memory'
        ''
        'This file is exported from the VS Code workspace configuration.'
        ''
    ) -join "`r`n"

    Set-Content -LiteralPath $DestinationPath -Value ($header + ($parts -join "`r`n")) -Encoding UTF8
}

function Export-ClaudePackage {
    param([string]$RootPath)

    $claudeRoot = Join-Path $RootPath '.claude'
    $agentsRoot = Join-Path $claudeRoot 'agents'
    $rulesRoot = Join-Path $claudeRoot 'rules'

    Remove-IfExists -Path $claudeRoot
    Ensure-Directory -Path $claudeRoot
    Ensure-Directory -Path $agentsRoot
    Ensure-Directory -Path $rulesRoot

    Build-ClaudeMemory -DestinationPath (Join-Path $claudeRoot 'CLAUDE.md')

    Get-ChildItem -LiteralPath (Join-Path $WorkspaceRoot '.github\agents') -Filter '*.agent.md' | ForEach-Object {
        $destName = $_.BaseName -replace '\.agent$',''
        Convert-AgentToClaude -SourcePath $_.FullName -DestinationPath (Join-Path $agentsRoot ($destName + '.md'))
    }

    Get-ChildItem -LiteralPath (Join-Path $WorkspaceRoot '.github\instructions') -Recurse -Filter '*.instructions.md' | ForEach-Object {
        $destName = $_.BaseName -replace '\.instructions$',''
        Convert-InstructionToClaudeRule -SourcePath $_.FullName -DestinationPath (Join-Path $rulesRoot ($destName + '.md'))
    }
}

function Export-OpenClawPackage {
    param([string]$RootPath)

    $migrationRoot = Join-Path $RootPath 'migration\openclaw'
    $compatRoot = Join-Path $migrationRoot 'claude-compatible'

    Remove-IfExists -Path $migrationRoot
    Ensure-Directory -Path $compatRoot

    Export-ClaudePackage -RootPath $compatRoot

    $manifest = @{
        generatedAt = (Get-Date).ToString('s')
        source = 'VS Code custom agents workspace'
        strategy = 'Export Claude-compatible assets and reuse them as OpenClaw migration input'
        files = @(
            'claude-compatible/.claude/CLAUDE.md',
            'claude-compatible/.claude/agents/*.md',
            'claude-compatible/.claude/rules/*.md'
        )
    } | ConvertTo-Json -Depth 4

    Set-Content -LiteralPath (Join-Path $migrationRoot 'manifest.json') -Value $manifest -Encoding UTF8

    $readme = @(
        '# OpenClaw Migration Bundle'
        ''
        'Use this directory as the migration input for OpenClaw.'
        ''
        '## Recommended usage'
        ''
        '- If your OpenClaw version can read Claude-compatible assets, point it at claude-compatible/.claude/.'
        '- Otherwise, use manifest.json and map agents, rules, and workspace memory manually.'
        '- Treat .claude/CLAUDE.md as the top-level workspace memory entrypoint.'
    ) -join "`r`n"

    Set-Content -LiteralPath (Join-Path $migrationRoot 'README.md') -Value $readme -Encoding UTF8
}

switch ($Target) {
    'Claude' {
        Export-ClaudePackage -RootPath $WorkspaceRoot
    }
    'OpenClaw' {
        Export-OpenClawPackage -RootPath $WorkspaceRoot
    }
    'Both' {
        Export-ClaudePackage -RootPath $WorkspaceRoot
        Export-OpenClawPackage -RootPath $WorkspaceRoot
    }
}

Write-Output ('Export complete: ' + $Target)