# PSLLM - PowerShell LLM Command Completion Module
# Uses PSReadLine buffer manipulation for seamless command line integration
# OpenAI API integration (compatible with OpenAI-compatible endpoints)

#region Module State
# Module-level state for command history
$script:LastLLMCommand = $null
$script:LLMCommandHistory = @()
$script:MaxHistorySize = 50
#endregion

#region Configuration
# Default API endpoint - can be overridden via environment variable
$script:ApiEndpoint = ($env:LLM_API_ENDPOINT ?? "https://api.openai.com/v1") + "/chat/completions"

# Model configuration
$script:DefaultModel = $env:LLM_MODEL ?? "qwen/qwen3-coder"

# Maximum tokens for response
$script:MaxTokens = 150

# Request timeout in seconds
$script:RequestTimeout = 10
#endregion

function Get-LLMCommand
{
  <#
    .SYNOPSIS
    Get a PowerShell command from LLM API based on natural language description
    .DESCRIPTION
    Queries LLM API and returns a PowerShell command
    .PARAMETER Description
    Natural language description of the command you want
    .PARAMETER Context
    Additional context to provide to the LLM for more accurate command generation. Accepts any PowerShell objects.
    .PARAMETER PipelineContext
    Context provided via pipeline. Automatically collected from pipeline input.
    .PARAMETER ApiEndpoint
    Override the default API endpoint
    .PARAMETER Model
    Override the default model
    .EXAMPLE
    Get-LLMCommand "list all running processes sorted by memory"
    .EXAMPLE
    Get-LLMCommand "rename all .txt files to .bak" -Model "gpt-4"
    .EXAMPLE
    Get-LLMCommand "generate summary" -Context "Recent commits: abc123 fix bug, def456 add feature"
    .EXAMPLE
    Get-Process | Get-LLMCommand "show top memory consumers"
    .EXAMPLE
    Get-ChildItem | Get-LLMCommand "analyze file structure" -Context "additional info"
    #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true, Position=0)]
    [string]$Description,

    [Parameter(Mandatory=$false)]
    [object[]]$Context,

    [Parameter(Mandatory=$false, ValueFromPipeline=$true)]
    [object[]]$PipelineContext,

    [Parameter(Mandatory=$false)]
    [string]$ApiEndpoint = $script:ApiEndpoint,

    [Parameter(Mandatory=$false)]
    [string]$Model = $script:DefaultModel
  )

  begin {
    # Validate API key
    $apiKey = $env:LLM_API_KEY ?? $env:OPENAI_API_KEY
    if ([string]::IsNullOrWhiteSpace($apiKey))
    {
      Write-Error "LLM_API_KEY or OPENAI_API_KEY environment variable not set"
      return
    }

    # Collect pipeline context
    $collectedPipelineContext = @()
  }

  process {
    # Collect pipeline objects
    if ($PipelineContext) {
      $collectedPipelineContext += $PipelineContext
    }
  }

  end {
    # Merge explicit context and pipeline context (explicit takes priority)
    $mergedContext = @()
    if ($Context) {
      $mergedContext += $Context
    }
    if ($collectedPipelineContext.Count -gt 0) {
      $mergedContext += $collectedPipelineContext
    }

    # Convert context objects to strings for LLM consumption
    $contextString = if ($mergedContext.Count -gt 0) {
      if ($mergedContext.Count -eq 1 -and $mergedContext[0] -is [string]) {
        $mergedContext[0]
      } else {
        $mergedContext | ForEach-Object { 
          if ($_ -is [string]) { $_ } 
          else { $_ | Out-String -Stream } 
        } | Out-String
      }
    } else { $null }

    try
    {
      # Construct the system prompt for PowerShell commands
      $systemPrompt = @"
You are a PowerShell and CLI expert assistant. Generate ONLY the command(s) that accomplish the user's request.

$(-not [string]::IsNullOrWhiteSpace($contextString) ? "Context provided: $contextString`n" : "")

Rules:
- Return ONLY the command code, no explanations
- Return ONLY ONE SOLUTION; it may be multiple commands, but *never return more than one way to do the same thing*
- The solution should match what the user asked; NO MORE
- Assume a pwsh environment, e.g. don't use bash piping
- Use pwsh functions and cmdlets by default, unless otherwise specified
- If asked to use a specific tool, use it; don't forcibly replace it with native pwsh
- Keep commands concise and idiomatic
- For complex operations, use pipeline where appropriate
- **DO NOT** include any markdown formatting, backticks, explanatory text or commentary
- If multiple commands are needed, put them on separate lines
- Handle common edge cases (quoted paths, error handling) appropriately
- Safety first: where reasonable, add CONCISE checks and confirmations for destructive operations (e.g. -WhatIf)
"@

      # Construct the user message
      $userMessage = if (-not [string]::IsNullOrWhiteSpace($contextString))
      {
        "Generate a command to: $Description (using the provided context)"
      } else
      {
        "Generate a command to: $Description"
      }

      # Prepare the request body
      $requestBody = @{
        model = $Model
        messages = @(
          @{
            role = "system"
            content = $systemPrompt
          }
          @{
            role = "user"
            content = $userMessage
          }
        )
        max_tokens = $script:MaxTokens
        temperature = 0.3
        stream = $false
      } | ConvertTo-Json -Depth 10

      # Prepare HTTP headers
      $headers = @{
        "Authorization" = "Bearer $apiKey"
        "Content-Type" = "application/json"
      }

      Write-Verbose "Querying LLM API: $ApiEndpoint"
      Write-Verbose "Request: $requestBody"

      # Make the API request
      $response = Invoke-RestMethod -Uri $ApiEndpoint -Method Post -Headers $headers -Body $requestBody -TimeoutSec $script:RequestTimeout

      # Extract the command from the response
      if ($response.choices -and $response.choices.Count -gt 0)
      {
        $command = $response.choices[0].message.content.Trim()

        if ([string]::IsNullOrWhiteSpace($command))
        {
          Write-Warning "LLM returned empty response"
          return $null
        }

        # Clean up common formatting issues
        $command = $command -replace '^```powershell\s*', '' -replace '^```ps1\s*', '' -replace '^```\s*', '' -replace '```\s*$', ''
        $command = $command.Trim()

        # Store in module state
        $script:LastLLMCommand = $command
        $script:LLMCommandHistory = @($command) + $script:LLMCommandHistory
        if ($script:LLMCommandHistory.Count -gt $script:MaxHistorySize) {
          $script:LLMCommandHistory = $script:LLMCommandHistory[0..($script:MaxHistorySize-1)]
        }

        Write-Verbose "Generated command: $command"
        return $command
      } else
      {
        Write-Warning "No choices returned from LLM API"
        return $null
      }
    } catch
    {
      Write-Host $_.Exception

      # Use generic LLM name since we support multiple providers
      $providerName = if ($ApiEndpoint -match "openai")
      { "OpenAI" 
      } elseif ($ApiEndpoint -match "nanogpt")
      { "NanoGPT" 
      } else
      { "LLM API" 
      }

      Write-Error "Failed to get command from $providerName"
      return $null
    }
  }
}

# PSReadLine buffer manipulation wrappers (borrowed from PSFzf pattern)
function Get-PSConsoleReadLineBufferState
{
  [CmdletBinding()]
  param()
  $line = $null
  $cursor = $null
  [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$cursor)
  return @{ Line = $line; Cursor = $cursor }
}

function Invoke-ReplacePSConsoleReadLineText
{
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [int]$Start,

    [Parameter(Mandatory = $true)]
    [int]$Length,

    [Parameter(Mandatory = $true)]
    [string]$ReplacementText
  )
  [Microsoft.PowerShell.PSConsoleReadLine]::Replace($Start, $Length, $ReplacementText)
}

function Invoke-InsertPSConsoleReadLineText
{
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [string]$TextToInsert
  )
  [Microsoft.PowerShell.PSConsoleReadLine]::Insert($TextToInsert)
}

# Current line completion function
function Invoke-LLMCompleteCurrentLine
{
  <#
    .SYNOPSIS
    Complete/replace current line using LLM based on existing text
    .DESCRIPTION
    Uses the current command line as context for LLM completion
    #>
  [CmdletBinding()]
  param()

  $bufferState = Get-PSConsoleReadLineBufferState
  $currentLine = $bufferState.Line

  if ([string]::IsNullOrWhiteSpace($currentLine))
  {
    Write-Host "🤖 Enter a description first, then use Ctrl+Alt+K to insert the last LLM command" -ForegroundColor Yellow
    return
  }

  # Clear current line
  [System.Console]::SetCursorPosition(0, [System.Console]::CursorTop)
  Write-Host (" " * ([System.Console]::WindowWidth - 1)) -NoNewline
  [System.Console]::SetCursorPosition(0, [System.Console]::CursorTop)

  # Show loading indicator
  Write-Host "🤖 Completing with LLM..." -ForegroundColor Yellow -NoNewline

  # Use current line as context for completion
  $generatedCommand = Get-LLMCommand -Description "Complete or improve this PowerShell command: $currentLine"

  # Clear loading line
  [System.Console]::SetCursorPosition(0, [System.Console]::CursorTop)
  Write-Host ("🔸" + (" " * ([System.Console]::WindowWidth - 2))) -NoNewline
  [System.Console]::SetCursorPosition(0, [System.Console]::CursorTop)

  if ($null -eq $generatedCommand)
  {
    Write-Host "❌ Failed to complete command" -ForegroundColor Red
    return
  }

  # Replace current line
  Invoke-ReplacePSConsoleReadLineText -Start 0 -Length $currentLine.Length -ReplacementText $generatedCommand
}

# PSReadLine helper functions for state management
function Invoke-InsertLastLLMCommand
{
  <#
    .SYNOPSIS
    Insert or cycle through LLM commands based on current buffer state
    .DESCRIPTION
    Three behaviors:
    1. Empty buffer: Insert last LLM command
    2. Buffer matches LLM history: Cycle to previous command
    3. Buffer doesn't match: No-op (silent)
    #>
  $bufferState = Get-PSConsoleReadLineBufferState
  $currentText = $bufferState.Line.Trim()
  
  # Case 1: Empty buffer → insert last command
  if ([string]::IsNullOrWhiteSpace($currentText)) {
    if ($script:LastLLMCommand) {
      Invoke-InsertPSConsoleReadLineText($script:LastLLMCommand)
    } else {
      Write-Host "No LLM command available. Run Get-LLMCommand first." -ForegroundColor Yellow
    }
    return
  }
  
  # Case 2: Buffer matches LLM history → cycle to previous
  $currentIndex = $script:LLMCommandHistory.IndexOf($currentText)
  if ($currentIndex -ne -1) {
    $prevIndex = ($currentIndex - 1 + $script:LLMCommandHistory.Count) % $script:LLMCommandHistory.Count
    $prevCommand = $script:LLMCommandHistory[$prevIndex]
    Invoke-ReplacePSConsoleReadLineText -Start 0 -Length $bufferState.Line.Length -ReplacementText $prevCommand
    return
  }
  
  # Case 3: Buffer doesn't match → no-op (silent)
  # Don't disturb user typing
}

function Get-LLMCommandHistory
{
  <#
    .SYNOPSIS
    Get the history of generated LLM commands
    .DESCRIPTION
    Returns the array of previously generated LLM commands
    #>
  return $script:LLMCommandHistory
}

function Clear-LLMCommandHistory
{
  <#
    .SYNOPSIS
    Clear the LLM command history
    .DESCRIPTION
    Clears the module-level command history and last command
    #>
  $script:LLMCommandHistory = @()
  $script:LastLLMCommand = $null
}

# Export functions
Export-ModuleMember -Function @(
  'Get-LLMCommand',
  'Invoke-LLMCompleteCurrentLine',
  'Invoke-InsertLastLLMCommand',
  'Get-LLMCommandHistory',
  'Clear-LLMCommandHistory'
)
