# PSLLM - PowerShell LLM Command Completion Module
# Uses PSReadLine buffer manipulation for seamless command line integration
# OpenAI API integration (compatible with OpenAI-compatible endpoints)

#region Module State
# Module-level state for command history and "chat history" context
$script:LastLLMCommand = $null
$script:LLMCommandHistory = @()
$script:ActiveSession = $false
$script:SessionHistory = @()
#endregion

#region Configuration
# Dynamic configuration resolver - reads env vars on each access
function Get-PSLLMConfiguration {
  <#
    .SYNOPSIS
    Get current PSLLM configuration from environment variables
    .DESCRIPTION
    Centralized configuration that reads environment variables dynamically
    #>
  [CmdletBinding()]
  param()

  return @{
    ApiEndpoint = ($env:PSLLM_API_ENDPOINT ?? "https://api.openai.com/v1") + "/chat/completions"
    Model = $env:PSLLM_MODEL ?? "gpt-4o-mini"
    MaxTokens = [int]($env:PSLLM_MAX_TOKENS ?? 500)
    RequestTimeout = [int]($env:PSLLM_REQUEST_TIMEOUT ?? 40)
    NoColors = [bool]($env:PSLLM_NO_COLORS ?? $false)
    MaxCommandHistorySize = [int]($env:PSLLM_MAX_COMMAND_HISTORY_SIZE ?? 50)
    MaxSessionContextMessages = [int]($env:PSLLM_MAX_SESSION_CONTEXT_MESSAGES ?? 20)
  }
}
#endregion

function Start-LLMSession
{
  <#
    .SYNOPSIS
    Start a conversational session with context persistence
    .DESCRIPTION
    Enables conversation history across multiple LLM calls
    .EXAMPLE
    Start-LLMSession
    #>
  [CmdletBinding()]
  param()

  $script:ActiveSession = $true
  Write-Host "🤖 LLM Session started" -ForegroundColor Green
}

function Stop-LLMSession
{
  <#
    .SYNOPSIS
    Stop the current LLM session
    .DESCRIPTION
    Ends the conversational session but preserves history for UX
    #>
  [CmdletBinding()]
  param()

  $script:ActiveSession = $false
  # Don't clear history - preserve for UX requirement
  Write-Host "🤖 LLM Session stopped" -ForegroundColor Yellow
}

function Reset-LLMSessionHistory
{
  <#
    .SYNOPSIS
    Clear all session history and optionally start fresh
    .DESCRIPTION
    Clears the accumulated session history. Optionally starts a new session.
    .PARAMETER StartSession
    Automatically start a new session after clearing history
    .EXAMPLE
    Reset-LLMSessionHistory
    .EXAMPLE
    Reset-LLMSessionHistory -StartSession
    #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$false)]
    [switch]$StartSession
  )

  # Clear history
  $script:SessionHistory = @()
  Write-Host "🗑️  Session history cleared" -ForegroundColor Yellow

  # Optionally start new session
  if ($StartSession) {
    Start-LLMSession
  }
}

function Get-LLMSessionStatus
{
  <#
    .SYNOPSIS
    Get the current session status and message count
    .DESCRIPTION
    Returns information about the active session state
    #>
  [CmdletBinding()]
  param()

  $config = Get-PSLLMConfiguration

  if ($script:ActiveSession) {
    return @{
      Active = $true
      MessageCount = $script:SessionHistory.Count
      MaxMessages = $config.MaxSessionContextMessages
    }
  } else {
    return @{
      Active = $false
      MessageCount = $script:SessionHistory.Count  # Show preserved history
      MaxMessages = $config.MaxSessionContextMessages
    }
  }
}

function Invoke-PSLLMTool
{
  <#
    .SYNOPSIS
    Execute PowerShell commands and return results to LLM
    .DESCRIPTION
    Executes arbitrary PowerShell commands with user confirmation and safety checks
    #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)]
    [object]$ToolCall
  )

  # Check for dangerous commands and warn user
  $dangerousPatterns = @(
    'rm\s+-rf',
    'remove-item.*-recurse',
    'format\s+',
    'del\s+/s',
    'rd\s+/s',
    'Stop-Process.*-Name',
    'Stop-Computer',
    'Restart-Computer',
    'Reset-ComputerMachinePassword'
  )

  $arguments = $ToolCall.function.arguments | ConvertFrom-Json
  $command = $arguments.command
  $isDangerous = $false
  foreach ($pattern in $dangerousPatterns) {
    if ($command -match $pattern) {
      $isDangerous = $true
      break
    }
  }

  if ($isDangerous) {
    Write-Host "⚠️ WARNING: This command appears potentially destructive!" -ForegroundColor Red
    Write-Host "🔸 [EXECUTE] $command" -ForegroundColor Yellow
    $confirm = Read-Host "🔸 Are you sure you want to run this? (y/n)"
    if ($confirm -ne 'y' -and $confirm -ne 'Y') {
      $cancelledResult = "Command cancelled by user"
      $script:SessionHistory += @{
        role = "tool"
        tool_call_id = $ToolCall.id
        name = "execute"
        content = "Command: $command`nResult: Cancelled by user"
      }
      return $cancelledResult
    }
  } else {
    Write-Host "🔸 [EXECUTE] $command" -ForegroundColor Cyan
    $confirm = Read-Host "🔸 Run this command? (y/n)"
    if ($confirm -ne 'y' -and $confirm -ne 'Y') {
      $cancelledResult = "Command cancelled by user"
      $script:SessionHistory += @{
        role = "tool"
        tool_call_id = $ToolCall.id
        name = "execute"
        content = "Command: $command`nResult: Cancelled by user"
      }
      return $cancelledResult
    }
  }

  try {
    # Execute command and capture output
    $output = Invoke-Expression -Command $command 2>&1
    $exitCode = $LASTEXITCODE

    $result = @{
      command = $command
      output = if ($output) { $output | Out-String } else { "(no output)" }
      exitCode = $exitCode
      timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    }

    $successResult = "Command executed successfully at $($result.timestamp)`nExit Code: $exitCode`nOutput:`n$($result.output)"

    $script:SessionHistory += @{
      role = "tool"
      tool_call_id = $ToolCall.id
      name = "execute"
      content = "Command: $command`nExit Code: $exitCode`nOutput:`n$($result.output)"
    }

    return $successResult
  }
  catch {
    $errorResult = "Command failed at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`nError: $($_.Exception.Message)"

    $script:SessionHistory += @{
      role = "tool"
      tool_call_id = $ToolCall.id
      name = "execute"
      content = "Command: $command`nError: $($_.Exception.Message)"
    }

    return $errorResult
  }
}

function Get-LLMResponse
{
  <#
    .SYNOPSIS
    Get a response from LLM API with custom system prompt
    .DESCRIPTION
    Core API communication function that handles context merging, authentication, and response processing
    .PARAMETER UserMessage
    The user's message or query
    .PARAMETER SystemPrompt
    The system prompt that defines the LLM's behavior and constraints
    .PARAMETER Context
    Additional context to provide to the LLM. Accepts any PowerShell objects.
    .PARAMETER PipelineContext
    Context provided via pipeline. Automatically collected from pipeline input.
    .PARAMETER ApiEndpoint
    Override the default API endpoint
    .PARAMETER Model
    Override the default model
    .EXAMPLE
    Get-LLMResponse -UserMessage "What is PowerShell?" -SystemPrompt "You are a helpful assistant."
    .EXAMPLE
    Get-Process | Get-LLMResponse -UserMessage "Show me the top memory consumers" -SystemPrompt "Analyze this data:"
    #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)]
    [string]$UserMessage,

    [Parameter(Mandatory=$false)]
    [string]$SystemPrompt,

    [Parameter(Mandatory=$false)]
    [object[]]$Context,

    [Parameter(Mandatory=$false, ValueFromPipeline=$true)]
    [object[]]$PipelineContext,

    [Parameter(Mandatory=$false)]
    [string]$ApiEndpoint,

    [Parameter(Mandatory=$false)]
    [string]$Model,

    [Parameter(Mandatory=$false)]
    [switch]$NoColors
  )

  begin {
    # Validate API key
    $apiKey = $env:PSLLM_API_KEY
    if ([string]::IsNullOrWhiteSpace($apiKey))
    {
      Write-Error "PSLLM_API_KEY environment variable not set"
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
    # Get current configuration dynamically
    $config = Get-PSLLMConfiguration

    # Set defaults from dynamic config if not overridden
    if (-not $ApiEndpoint) { $ApiEndpoint = $config.ApiEndpoint }
    if (-not $Model) { $Model = $config.Model }

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
      # Assign a default system prompt if none was specified
      if ([string]::IsNullOrWhiteSpace($SystemPrompt)) {
        if ($NoColors -or $config.NoColors) {
          $SystemPrompt = @"
You are a helpful assistant in a pwsh terminal. Be concise. Keep your lines under 80 chars.
Use neat plain text layout and **AVOID ALL MARKDOWN FORMATTING** unless otherwise instructed. ASCII/Unicode diagrams and tables are encouraged.
Return clean text without ANSI color codes.
"@
        } else {
          $SystemPrompt = @"
You are a helpful assistant in a pwsh terminal. Be concise. Keep your lines under 80 chars.
Use neat text layout and **AVOID ALL MARKDOWN FORMATTING** unless otherwise instructed. ASCII/Unicode diagrams and tables are encouraged.
You are encouraged to judiciously use ANSI escape codes for colors and formatting (bold, underline, background colors). e.g. \\x1b[31m
You are STRONGLY ENCOURAGED TO USE TERMINAL COLORS AND FORMATTING in lieu of markdown to emphasize headings, important phrases and to add visual separation to your reply.
"@
        }
      }

      # Keep system prompt clean - context goes in user message
      $finalSystemPrompt = $SystemPrompt

      # Build messages array with session history if active
      $messages = @()

      # Add system message
      $messages += @{
        role = "system"
        content = $finalSystemPrompt
      }

      if ($script:ActiveSession) {
        # Add session history first
        $messages += $script:SessionHistory
      }

      # Create and add current user message with context
      $finalUserMessage = if (-not [string]::IsNullOrWhiteSpace($contextString))
      {
        "$UserMessage`n`n<IMPORTANT_CONTEXT_PROVIDED>`n$contextString`n</IMPORTANT_CONTEXT_PROVIDED>"
      } else {
        $UserMessage
      }

      $currentMessage = @{
        role = "user"
        content = $finalUserMessage
      }
      $messages += $currentMessage

      # Always add to session history (your UX requirement)
      $script:SessionHistory += $currentMessage
      # Trim history if needed (hard cutoff)
      if ($script:SessionHistory.Count -gt $config.MaxSessionContextMessages) {
        $script:SessionHistory = $script:SessionHistory[-$config.MaxSessionContextMessages..-1]
      }

      # Define available tools
      $tools = @(
        @{
          type = "function"
          function = @{
            name = "execute"
            description = "Execute PowerShell commands in the current environment. Use this for system operations, file management, data processing, or any other PowerShell tasks. Only use for safe, non-destructive operations unless explicitly confirmed by user. The command will be executed with user confirmation."
            parameters = @{
              type = "object"
              properties = @{
                command = @{
                  type = "string"
                  description = "The PowerShell command to execute"
                }
              }
              required = @("command")
            }
          }
        }
      )

      # Prepare the request body with tools
      $requestBody = @{
        model = $Model
        messages = $messages
        max_tokens = $config.MaxTokens
        stream = $false
        tools = $tools
        tool_choice = "auto"
      } | ConvertTo-Json -Depth 10

      # Prepare HTTP headers
      $headers = @{
        "Authorization" = "Bearer $apiKey"
        "Content-Type" = "application/json"
      }

      Write-Verbose "Querying LLM API: $ApiEndpoint"
      Write-Verbose "Request: $requestBody"

      # Make the API request
      $response = Invoke-RestMethod -Uri $ApiEndpoint -Method Post -Headers $headers -Body $requestBody -TimeoutSec $config.RequestTimeout

      # Handle tool calls if present
      if ($response.choices -and $response.choices.Count -gt 0)
      {
        $choice = $response.choices[0]

        # Check if there are tool calls to execute
        if ($choice.message.tool_calls)
        {
          Write-Verbose "Processing $($choice.message.tool_calls.Count) tool calls"

          # This adds the tool call request assistant message to the history
          # Without this, the LLM won't understand where the tool call results originate from
          $messages += $choice.message
          $script:SessionHistory += $choice.message

          foreach ($toolCall in $choice.message.tool_calls)
          {
            if ($toolCall.function.name -eq "execute")
            {
              # Execute the command (interally adds tool call results to session history)
              $toolResult = Invoke-PSLLMTool -ToolCall $toolCall

              # Add tool call response result to messages for next API call
              $messages += @{
                role = "tool"
                tool_call_id = $toolCall.id
                name = $toolCall.function.name
                content = $toolResult
              }
            }
          }

          $finalMessages = @()

          # Add updated session history (which now includes tool results from Invoke-PSLLMTool)
          if ($script:ActiveSession) {
            # Add system message
            $finalMessages += @{
              role = "system"
              content = $finalSystemPrompt
            }
            $finalMessages += $script:SessionHistory
          } else {
            # In inactive sessions, we only send the session history relevant to the last tool call
            $finalMessages += $messages
          }

          $finalRequestBody = @{
            model = $Model
            messages = $finalMessages
            max_tokens = $config.MaxTokens
            stream = $false
          } | ConvertTo-Json -Depth 10

          Write-Verbose "Making follow-up API call with tool results: $finalRequestBody"
          $finalResponse = Invoke-RestMethod -Uri $ApiEndpoint -Method Post -Headers $headers -Body $finalRequestBody -TimeoutSec $config.RequestTimeout

          # Extract final response
          if ($finalResponse.choices -and $finalResponse.choices.Count -gt 0)
          {
            $responseText = $finalResponse.choices[0].message.content.Trim()
          } else {
            Write-Warning "No choices returned from follow-up API call"
            return $null
          }
        } else {
          # No tool calls, use original response
          $responseText = $choice.message.content.Trim()
        }

        if ([string]::IsNullOrWhiteSpace($responseText))
        {
          Write-Warning "LLM returned empty response"
          return $null
        }

        # Always add response to session history (consistent with user messages)
        $script:SessionHistory += @{role="assistant"; content=$responseText}

        # Trim history again if needed (after adding response)
        if ($script:SessionHistory.Count -gt $config.MaxSessionContextMessages) {
          $script:SessionHistory = $script:SessionHistory[-$config.MaxSessionContextMessages..-1]
        }

        Write-Verbose "Generated response: $responseText"

        # Handle color initialization and response cleaning
        if ($NoColors -or $config.NoColors) {
          # Strip ANSI color codes from response
          $cleanResponse = $responseText -replace '\x1b\[[0-9;]*m', ''
          return $cleanResponse
        } else {
          return $responseText -replace "\\x1b","`e"
        }
      } else
      {
        Write-Warning "No choices returned from LLM API"
        return $null
      }
    } catch
    {
      Write-Error $_ -ErrorAction Continue
      return $null
    }
  }
}

function Get-LLMCommand
{
  <#
    .SYNOPSIS
    Get a PowerShell command from LLM API based on natural language description
    .DESCRIPTION
    Queries LLM API and returns a PowerShell command using a specialized system prompt
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
    [string]$ApiEndpoint,

    [Parameter(Mandatory=$false)]
    [string]$Model
  )

  begin {
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
    # Get current configuration dynamically
    $config = Get-PSLLMConfiguration

    # Set defaults from dynamic config if not overridden
    if (-not $ApiEndpoint) { $ApiEndpoint = $config.ApiEndpoint }
    if (-not $Model) { $Model = $config.Model }

    # Construct the system prompt for PowerShell commands
    $systemPrompt = @"
You are a PowerShell and CLI expert assistant. Generate ONLY the command(s) that accomplish the user's request.

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
      $userMessage = if (-not [string]::IsNullOrWhiteSpace($collectedPipelineContext) || -not [string]::IsNullOrWhiteSpace($Context)) {
        "Complete this rest of this command (or rewrite/improve it if you can't complete it): $Description (YOU MUST CONSIDER THE IMPORTANT_CONTEXT_PROVIDED)"
      } else {
        "Complete this rest of this command (or rewrite/improve it if you can't complete it): $Description"
      }

    # Get response from the base function (always disable colors for commands)
    $rawResponse = Get-LLMResponse -UserMessage $userMessage -SystemPrompt $systemPrompt -Context $Context -PipelineContext $collectedPipelineContext -ApiEndpoint $ApiEndpoint -Model $Model -NoColors

    if ($null -eq $rawResponse) {
      return $null
    }

    # Clean up common formatting issues specific to commands
    $command = $rawResponse -replace '^```powershell\s*', '' -replace '^```ps1\s*', '' -replace '^```\s*', '' -replace '```\s*$', ''
    $command = $command.Trim()

    # Store in module state
    $script:LastLLMCommand = $command
    $script:LLMCommandHistory = @($command) + $script:LLMCommandHistory
    if ($script:LLMCommandHistory.Count -gt $config.MaxCommandHistorySize) {
      $script:LLMCommandHistory = $script:LLMCommandHistory[0..($config.MaxCommandHistorySize-1)]
    }

    Write-Verbose "Generated command: $command"
    return $command
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
  $generatedCommand = Get-LLMCommand -Description "$currentLine"

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
  'Start-LLMSession',
  'Stop-LLMSession',
  'Reset-LLMSessionHistory',
  'Get-LLMSessionStatus',
  'Get-LLMResponse',
  'Get-LLMCommand',
  'Invoke-LLMCompleteCurrentLine',
  'Invoke-InsertLastLLMCommand',
  'Get-LLMCommandHistory',
  'Clear-LLMCommandHistory',
  'Get-PSLLMConfiguration'
)
