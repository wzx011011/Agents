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

function Get-FrontmatterBlock {
  param(
    [string]$Frontmatter,
    [string]$Key
  )

  $lines = $Frontmatter -split "`r?`n"
  $capturing = $false
  $block = @()

  foreach ($line in $lines) {
    if (-not $capturing) {
      if ($line -match ('^' + [regex]::Escape($Key) + ':\s*$')) {
        $capturing = $true
      }
      continue
    }

    if ($line -match '^[A-Za-z0-9_-]+:\s*') {
      break
    }

    $block += $line
  }

  return $block
}

function Get-AgentToolPreset {
  param([string]$AgentName)

  $pmAgentName = ( -join @([char]32452, [char]21512, [char]80, [char]77))
  $developerAgentName = ( -join @([char]36890, [char]29992, [char]24320, [char]21457))
  $reviewAgentName = ( -join @([char]35780, [char]23457, [char]35843, [char]35797))
  $testAgentName = ( -join @([char]27979, [char]35797, [char]24037, [char]31243, [char]24072))

  switch ($AgentName) {
    $pmAgentName { return 'Read, Edit, Grep, Glob' }
    $developerAgentName { return 'Read, Edit, Grep, Glob, Bash' }
    $reviewAgentName { return 'Read, Edit, Grep, Glob, Bash' }
    $testAgentName { return 'Read, Edit, Grep, Glob, Bash' }
    default { return 'Read, Grep, Glob' }
  }
}

function Get-AgentHandoffs {
  param([string]$Frontmatter)

  $block = Get-FrontmatterBlock -Frontmatter $Frontmatter -Key 'handoffs'
  $handoffs = @()
  $current = $null

  foreach ($line in $block) {
    if ($line -match '^\s*-\s+label:\s*(.+)$') {
      if ($null -ne $current) {
        $handoffs += [pscustomobject]$current
      }

      $current = @{
        label  = $Matches[1].Trim().Trim("'").Trim('"')
        agent  = ''
        prompt = ''
        send   = ''
      }
      continue
    }

    if ($null -eq $current) {
      continue
    }

    if ($line -match '^\s+agent:\s*(.+)$') {
      $current.agent = $Matches[1].Trim().Trim("'").Trim('"')
      continue
    }

    if ($line -match '^\s+prompt:\s*(.+)$') {
      $current.prompt = $Matches[1].Trim().Trim("'").Trim('"')
      continue
    }

    if ($line -match '^\s+send:\s*(.+)$') {
      $current.send = $Matches[1].Trim().Trim("'").Trim('"')
    }
  }

  if ($null -ne $current) {
    $handoffs += [pscustomobject]$current
  }

  return $handoffs
}

function Clear-GeneratedFiles {
  param([string[]]$Paths)

  foreach ($path in $Paths) {
    if (Test-Path -LiteralPath $path) {
      Remove-Item -LiteralPath $path -Recurse -Force
    }
  }
}

function Get-SourceAgentDefinitions {
  $definitions = @()
  $agentsRoot = Join-Path $WorkspaceRoot '.github\agents'

  Get-ChildItem -LiteralPath $agentsRoot -Filter '*.agent.md' | Sort-Object Name | ForEach-Object {
    $raw = Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8
    $parsed = Get-FrontmatterAndBody -Raw $raw
    $frontmatter = $parsed[0]
    $body = $parsed[1]
    $name = Get-FrontmatterValue -Frontmatter $frontmatter -Key 'name'
    $description = Get-FrontmatterValue -Frontmatter $frontmatter -Key 'description'

    if ([string]::IsNullOrWhiteSpace($name)) {
      $name = $_.BaseName -replace '\.agent$', ''
    }

    $definitions += [pscustomobject]@{
      name        = $name
      description = $description
      body        = $body
      handoffs    = @(Get-AgentHandoffs -Frontmatter $frontmatter)
      sourcePath  = $_.FullName
    }
  }

  return $definitions
}

function Convert-AgentToClaude {
  param(
    [pscustomobject]$Agent,
    [string]$DestinationPath
  )

  $tools = Get-AgentToolPreset -AgentName $Agent.name
  $handoffLines = @()

  if ($Agent.handoffs.Count -gt 0) {
    $handoffLines += '## Available Handoffs'
    $handoffLines += ''
    foreach ($handoff in $Agent.handoffs) {
      $line = '- ' + $handoff.label + ' -> ' + $handoff.agent
      if (-not [string]::IsNullOrWhiteSpace($handoff.prompt)) {
        $line += ' | ' + $handoff.prompt
      }
      $handoffLines += $line
    }
    $handoffLines += ''
  }

  $output = @(
    '---'
    ('name: ' + $Agent.name)
    ('description: ' + $Agent.description)
    ('tools: ' + $tools)
    '---'
    ''
    $Agent.body
    ''
    $handoffLines
    '## Migration Notes'
    ''
    '- Exported from a VS Code custom agent file.'
    '- Structured handoff data is also exported to workflow.json.'
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

function Build-WorkflowData {
  param([object[]]$Agents)

  return [ordered]@{
    workflowVersion = 1
    exportedFrom    = 'VS Code custom agents workspace'
    agents          = @(
      foreach ($agent in $Agents) {
        [ordered]@{
          name        = $agent.name
          description = $agent.description
          tools       = (Get-AgentToolPreset -AgentName $agent.name) -split ',\s*'
          handoffs    = @(
            foreach ($handoff in $agent.handoffs) {
              [ordered]@{
                label  = $handoff.label
                target = $handoff.agent
                prompt = $handoff.prompt
                send   = $handoff.send
              }
            }
          )
        }
      }
    )
  }
}

function Get-InstructionSourceFiles {
  return @(Get-ChildItem -LiteralPath (Join-Path $WorkspaceRoot '.github\instructions') -Recurse -Filter '*.instructions.md' | Sort-Object FullName)
}

function Get-RuleRelativePath {
  param([string]$SourcePath)

  $instructionsRoot = Join-Path $WorkspaceRoot '.github\instructions'
  $relativeSourcePath = $SourcePath.Substring($instructionsRoot.Length).TrimStart('\')
  $relativeDirectory = Split-Path -Path $relativeSourcePath -Parent
  $baseName = [IO.Path]::GetFileNameWithoutExtension([IO.Path]::GetFileNameWithoutExtension($SourcePath))

  if ([string]::IsNullOrWhiteSpace($relativeDirectory)) {
    return ($baseName + '.md')
  }

  return (Join-Path $relativeDirectory ($baseName + '.md'))
}

function Get-LegacyFlatRulePaths {
  param(
    [object[]]$InstructionFiles,
    [string]$RulesRoot
  )

  return @(
    foreach ($instructionFile in $InstructionFiles) {
      $relativeRulePath = Get-RuleRelativePath -SourcePath $instructionFile.FullName
      $fileName = Split-Path -Path $relativeRulePath -Leaf
      $legacyFlatPath = Join-Path $RulesRoot $fileName

      if ($legacyFlatPath -ne (Join-Path $RulesRoot $relativeRulePath)) {
        $legacyFlatPath
      }
    }
  )
}

function Export-ClaudePackage {
  param([string]$RootPath)

  $claudeRoot = Join-Path $RootPath '.claude'
  $agentsRoot = Join-Path $claudeRoot 'agents'
  $rulesRoot = Join-Path $claudeRoot 'rules'
  $workflowPath = Join-Path $claudeRoot 'workflow.json'
  $agents = Get-SourceAgentDefinitions
  $instructionFiles = Get-InstructionSourceFiles

  Ensure-Directory -Path $claudeRoot
  Ensure-Directory -Path $agentsRoot
  Ensure-Directory -Path $rulesRoot

  $generatedAgentFiles = @(
    foreach ($agent in $agents) {
      Join-Path $agentsRoot ($agent.name + '.md')
    }
  )
  $generatedRuleFiles = @(
    foreach ($instructionFile in $instructionFiles) {
      Join-Path $rulesRoot (Get-RuleRelativePath -SourcePath $instructionFile.FullName)
    }
  )
  $legacyFlatRuleFiles = Get-LegacyFlatRulePaths -InstructionFiles $instructionFiles -RulesRoot $rulesRoot

  Clear-GeneratedFiles -Paths (@(
      (Join-Path $claudeRoot 'CLAUDE.md'),
      $workflowPath
    ) + $generatedAgentFiles + $generatedRuleFiles + $legacyFlatRuleFiles)

  Build-ClaudeMemory -DestinationPath (Join-Path $claudeRoot 'CLAUDE.md')
  (Build-WorkflowData -Agents $agents | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $workflowPath -Encoding UTF8

  foreach ($agent in $agents) {
    Convert-AgentToClaude -Agent $agent -DestinationPath (Join-Path $agentsRoot ($agent.name + '.md'))
  }

  foreach ($instructionFile in $instructionFiles) {
    $destinationPath = Join-Path $rulesRoot (Get-RuleRelativePath -SourcePath $instructionFile.FullName)
    Ensure-Directory -Path (Split-Path -Path $destinationPath -Parent)
    Convert-InstructionToClaudeRule -SourcePath $instructionFile.FullName -DestinationPath $destinationPath
  }
}

function Export-OpenClawPackage {
  param([string]$RootPath)

  $migrationRoot = Join-Path $RootPath 'migration\openclaw'
  $compatRoot = Join-Path $migrationRoot 'claude-compatible'
  $compatClaudeRoot = Join-Path $compatRoot '.claude'
  $manifestPath = Join-Path $migrationRoot 'manifest.json'
  $readmePath = Join-Path $migrationRoot 'README.md'
  $workflowPath = Join-Path $migrationRoot 'workflow.json'

  Ensure-Directory -Path $migrationRoot
  Ensure-Directory -Path $compatRoot

  Clear-GeneratedFiles -Paths @($manifestPath, $readmePath, $workflowPath)

  Export-ClaudePackage -RootPath $compatRoot

  $workflowData = Get-Content -LiteralPath (Join-Path $compatClaudeRoot 'workflow.json') -Raw -Encoding UTF8
  Set-Content -LiteralPath $workflowPath -Value $workflowData -Encoding UTF8

  $manifest = @{
    source   = 'VS Code custom agents workspace'
    strategy = 'Export Claude-compatible assets and reuse them as OpenClaw migration input'
    files    = @(
      'claude-compatible/.claude/CLAUDE.md',
      'claude-compatible/.claude/agents/*.md',
      'claude-compatible/.claude/rules/**/*.md',
      'claude-compatible/.claude/workflow.json',
      'workflow.json'
    )
    workflow = 'workflow.json'
  } | ConvertTo-Json -Depth 4

  Set-Content -LiteralPath $manifestPath -Value $manifest -Encoding UTF8

  $readme = @(
    '# OpenClaw Migration Bundle'
    ''
    'Use this directory as the migration input for OpenClaw.'
    ''
    '## Recommended usage'
    ''
    '- If your OpenClaw version can read Claude-compatible assets, point it at claude-compatible/.claude/.'
    '- Otherwise, use manifest.json and map agents, rules, and workspace memory manually.'
    '- Use claude-compatible/.claude/CLAUDE.md as the workspace memory entrypoint.'
    '- Use workflow.json to preserve PM -> Dev -> Review -> Test handoff semantics during manual mapping.'
  ) -join "`r`n"

  Set-Content -LiteralPath $readmePath -Value $readme -Encoding UTF8
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