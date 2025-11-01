# PSLLM - PowerShell LLM Command Completion Module
# Uses PSReadLine buffer manipulation for seamless command line integration
# OpenAI API integration (compatible with OpenAI-compatible endpoints)

#region Configuration
# Default API endpoint - can be overridden via environment variable
$script:ApiEndpoint = ($env:LLM_API_ENDPOINT ?? "https://api.openai.com/v1") + "/chat/completions"

# Model configuration
$script:DefaultModel = $env:LLM_MODEL ?? "Qwen/Qwen3-Next-80B-A3B-Instruct"

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
    .PARAMETER ApiEndpoint
    Override the default API endpoint
    .PARAMETER Model
    Override the default model
    .EXAMPLE
    Get-LLMCommand "list all running processes sorted by memory"
    .EXAMPLE
    Get-LLMCommand "rename all .txt files to .bak" -Model "gpt-4"
    #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)]
    [string]$Description,

    [Parameter(Mandatory=$false)]
    [string]$ApiEndpoint = $script:ApiEndpoint,

    [Parameter(Mandatory=$false)]
    [string]$Model = $script:DefaultModel
  )

  # Validate API key
  $apiKey = $env:LLM_API_KEY ?? $env:OPENAI_API_KEY
  if ([string]::IsNullOrWhiteSpace($apiKey))
  {
    Write-Error "LLM_API_KEY or OPENAI_API_KEY environment variable not set"
    return $null
  }

  try
  {
    # Construct the system prompt for PowerShell commands
    $systemPrompt = @"
You are a PowerShell and CLI expert assistant. Generate ONLY the command(s) that accomplish the user's request.

Rules:
- Return ONLY the command code, no explanations
- Return ONLY ONE SOLUTION; it may be multiple commands, but *never return more than one way to do the same thing*
- Assume a pwsh environment, e.g. don't use bash piping
- use pwsh functions and cmdlets by default, unless told otherwise
- Keep commands concise and idiomatic
- For complex operations, use pipeline where appropriate
- Do not include any markdown formatting, backticks, or explanatory text
- If multiple commands are needed, separate them with newlines
- Handle common edge cases (quoted paths, error handling) appropriately
"@

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
          content = "PowerShell command to: $Description"
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
    $providerName = if ($ApiEndpoint -match "openai") { "OpenAI" }
    elseif ($ApiEndpoint -match "nanogpt") { "NanoGPT" }
    else { "LLM API" }

    Write-Error "Failed to get command from $providerName"
    return $null
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

# Core interactive function
function Invoke-LLMCompletion
{
  <#
    .SYNOPSIS
    Interactive LLM command completion that replaces current line
    .DESCRIPTION
    Prompts for natural language description, gets command from LLM,
    and replaces the current command line buffer
    #>
  [CmdletBinding()]
  param()

  # Get current buffer state
  $bufferState = Get-PSConsoleReadLineBufferState
  $currentLine = $bufferState.Line

  # If current line has text, use it as initial prompt
  $initialPrompt = if ([string]::IsNullOrWhiteSpace($currentLine))
  {
    ""
  } else
  {
    $currentLine
  }

  # Prompt user for description
  $description = Read-Host -Prompt "Describe command$(if($initialPrompt) { " (current: $initialPrompt)" })"

  if ([string]::IsNullOrWhiteSpace($description))
  {
    return  # User cancelled
  }

  # Show loading indicator
  Write-Host "🤖 Querying LLM..." -ForegroundColor Yellow -NoNewline

  # Get command from LLM
  $generatedCommand = Get-LLMCommand -Description $description

  # Clear loading line
  [System.Console]::SetCursorPosition(0, [System.Console]::CursorTop)
  Write-Host ("🔸" + (" " * ([System.Console]::WindowWidth - 2))) -NoNewline
  [System.Console]::SetCursorPosition(0, [System.Console]::CursorTop)

  if ($null -eq $generatedCommand)
  {
    Write-Host "❌ Failed to generate command" -ForegroundColor Red
    return
  }

  # Replace entire current line with generated command
  Invoke-ReplacePSConsoleReadLineText -Start 0 -Length $currentLine.Length -ReplacementText $generatedCommand
}

# Convenience function for current line completion
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
    Invoke-LLMCompletion
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

# Export functions
Export-ModuleMember -Function @(
  'Get-LLMCommand',
  'Invoke-LLMCompletion',
  'Invoke-LLMCompleteCurrentLine'
)
