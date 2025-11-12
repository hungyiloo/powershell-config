# PSLLM - PowerShell LLM Command Completion Module
# Uses PSReadLine buffer manipulation for seamless command line integration
# OpenAI API integration (compatible with OpenAI-compatible endpoints)

#region Module State
# Module-level state for command history and "chat history" context
$script:LastLLMCommand = $null
$script:LLMCommandHistory = @()
$script:ActiveSession = $false
$script:SessionHistory = @()
function Get-MessagesForApiCall {
  <#
    .SYNOPSIS
    Build messages array for API call using session history as single source of truth
    .DESCRIPTION
    Centralizes message building logic with clear active/inactive session handling
    .PARAMETER SystemPrompt
    The system prompt to prepend
    .PARAMETER ActiveSession
    Whether the session is currently active
    #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)]
    [string]$SystemPrompt,

    [Parameter(Mandatory=$true)]
    [bool]$ActiveSession
  )

  $messages = @()
  
  # Always start with system prompt
  $messages += @{
    role = "system"
    content = $SystemPrompt
  }

  if ($ActiveSession) {
    # Active session: send all session history
    $messages += $script:SessionHistory
  } else {
    # Inactive session: extract last interaction context
    # Search backwards from end of session history, collect messages until
    # we hit a role=user message, which captures the last interaction
    $contextMessages = @()
    for ($i = $script:SessionHistory.Count - 1; $i -ge 0; $i--) {
      $msg = $script:SessionHistory[$i]
      $contextMessages = @($msg) + $contextMessages

      if ($msg.role -eq "user") {
        break
      }
    }
    $messages += $contextMessages
  }

  return $messages
}

#endregion

#region Private Helper Functions

function Get-LLMApiKey {
  <#
    .SYNOPSIS
    Get PSLLM_API_KEY environment variable
    .DESCRIPTION
    Centralized API key retrieval with validation
    #>
  [CmdletBinding()]
  param()

  $apiKey = $env:PSLLM_API_KEY
  if ([string]::IsNullOrWhiteSpace($apiKey)) {
    Write-Error "PSLLM_API_KEY environment variable not set"
    return $null
  }
  return $apiKey
}

function Merge-LLMContext {
  <#
    .SYNOPSIS
    Merge explicit context and pipeline context into unified string
    .DESCRIPTION
    Handles context merging with explicit context taking priority over pipeline
    .PARAMETER Context
    Explicit context provided via parameter
    .PARAMETER PipelineContext
    Context collected from pipeline input
    #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$false)]
    [object[]]$Context,

    [Parameter(Mandatory=$false)]
    [object[]]$PipelineContext
  )

  # Merge explicit context and pipeline context (explicit takes priority)
  $mergedContext = @()
  if ($Context) {
    $mergedContext += $Context
  }
  if ($PipelineContext.Count -gt 0) {
    $mergedContext += $PipelineContext
  }

  # Convert context objects to strings for LLM consumption
  if ($mergedContext.Count -gt 0) {
    if ($mergedContext.Count -eq 1 -and $mergedContext[0] -is [string]) {
      return $mergedContext[0]
    } else {
      return $mergedContext | ForEach-Object {
        if ($_ -is [string]) { $_ }
        else { $_ | Out-String -Stream }
      } | Out-String
    }
  } else {
    return $null
  }
}

function Get-LLMDefaultSystemPrompt {
  <#
    .SYNOPSIS
    Generate default system prompt based on color preferences
    .DESCRIPTION
    Creates appropriate system prompt with or without ANSI color support
    .PARAMETER NoColors
    Whether to disable color formatting in the prompt
    .PARAMETER Config
    PSLLM configuration object
    #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$false)]
    [switch]$NoColors,

    [Parameter(Mandatory=$true)]
    [object]$Config
  )

  if ($NoColors -or $Config.NoColors) {
    return @"
You are a helpful assistant in a pwsh terminal. Be concise. Keep your lines under 80 chars.
Use neat plain text layout and **AVOID ALL MARKDOWN FORMATTING** unless otherwise instructed. ASCII/Unicode diagrams and tables are encouraged.
Return clean text without ANSI color codes.
"@
  } else {
    return @"
You are a helpful assistant in a pwsh terminal. Be concise. Keep your lines under 80 chars.
Use neat text layout and **AVOID ALL MARKDOWN FORMATTING** unless otherwise instructed. ASCII/Unicode diagrams and tables are encouraged.
You are encouraged to judiciously use ANSI escape codes for colors and formatting (bold, underline, background colors). e.g. \x1b[31m
You are STRONGLY ENCOURAGED TO USE TERMINAL COLORS AND FORMATTING in lieu of markdown to emphasize headings, important phrases and to add visual separation to your reply.
"@
  }
}

function Build-LLMUserMessage {
  <#
    .SYNOPSIS
    Build user message with context integration
    .DESCRIPTION
    Constructs the final user message by merging base message with context
    .PARAMETER UserMessage
    The base user message
    .PARAMETER ContextString
    Merged context string (may be null)
    #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)]
    [string]$UserMessage,

    [Parameter(Mandatory=$false)]
    [string]$ContextString
  )

  if (-not [string]::IsNullOrWhiteSpace($ContextString)) {
    return "$UserMessage`n`n<IMPORTANT_CONTEXT_PROVIDED>`n$ContextString`n</IMPORTANT_CONTEXT_PROVIDED>"
  } else {
    return $UserMessage
  }
}

function Update-LLMSessionHistory {
  <#
    .SYNOPSIS
    Update session history with message and enforce size limits
    .DESCRIPTION
    Adds message to session history and trims if needed
    .PARAMETER Message
    The message to add to history
    .PARAMETER Config
    PSLLM configuration object
    .PARAMETER SkipUpdate
    Whether to skip adding this message (for recursive calls)
    #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)]
    [object]$Message,

    [Parameter(Mandatory=$true)]
    [object]$Config,

    [Parameter(Mandatory=$false)]
    [switch]$SkipUpdate
  )

  if (-not $SkipUpdate) {
    $script:SessionHistory += $Message
    
    # Trim history if needed (hard cutoff)
    if ($script:SessionHistory.Count -gt $config.MaxSessionContextMessages) {
      $script:SessionHistory = $script:SessionHistory[-$config.MaxSessionContextMessages..-1]
    }
  }
}

function Format-LLMResponse {
  <#
    .SYNOPSIS
    Format and clean LLM response based on color preferences
    .DESCRIPTION
    Handles ANSI color code processing and response cleaning
    .PARAMETER ResponseText
    The raw response text from LLM
    .PARAMETER NoColors
    Whether to disable color formatting
    .PARAMETER Config
    PSLLM configuration object
    #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)]
    [string]$ResponseText,

    [Parameter(Mandatory=$false)]
    [switch]$NoColors,

    [Parameter(Mandatory=$true)]
    [object]$Config
  )

  if ($NoColors -or $config.NoColors) {
    # Strip ANSI color codes from response
    return $ResponseText -replace '\x1b\[[0-9;]*m', ''
  } else {
    return $ResponseText -replace "\\x1b","`e"
  }
}

function Build-LLMApiRequest {
  <#
    .SYNOPSIS
    Build API request body and headers for LLM call
    .DESCRIPTION
    Constructs the complete request including tools, messages, and authentication
    .PARAMETER Model
    The model to use for the request
    .PARAMETER Messages
    The message array for the conversation
    .PARAMETER ApiKey
    The API key for authentication
    .PARAMETER Config
    PSLLM configuration object
    #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)]
    [string]$Model,

    [Parameter(Mandatory=$true)]
    [object[]]$Messages,

    [Parameter(Mandatory=$true)]
    [string]$ApiKey,

    [Parameter(Mandatory=$true)]
    [object]$Config
  )

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
    messages = $Messages
    max_tokens = $config.MaxTokens
    stream = $false
    tools = $tools
    tool_choice = "auto"
  } | ConvertTo-Json -Depth 10

  # Prepare HTTP headers
  $headers = @{
    "Authorization" = "Bearer $ApiKey"
    "Content-Type" = "application/json"
  }

  return @{
    Body = $requestBody
    Headers = $headers
  }
}

function Process-LLMToolCalls {
  <#
    .SYNOPSIS
    Process tool calls from LLM response and update session history
    .DESCRIPTION
    Executes tool calls and handles recursive API calls with results
    .PARAMETER ToolCalls
    The tool calls array from LLM response
    .PARAMETER UserMessage
    The original user message for recursive call
    .PARAMETER SystemPrompt
    The system prompt for recursive call
    .PARAMETER ApiEndpoint
    The API endpoint for recursive call
    .PARAMETER Model
    The model for recursive call
    .PARAMETER NoColors
    Whether to disable colors in recursive call
    #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)]
    [object[]]$ToolCalls,

    [Parameter(Mandatory=$true)]
    [string]$UserMessage,

    [Parameter(Mandatory=$true)]
    [string]$SystemPrompt,

    [Parameter(Mandatory=$true)]
    [string]$ApiEndpoint,

    [Parameter(Mandatory=$true)]
    [string]$Model,

    [Parameter(Mandatory=$false)]
    [switch]$NoColors
  )

  Write-Verbose "Processing $($ToolCalls.Count) tool calls"

  # Add the tool call request assistant message to session history
  $script:SessionHistory += @{
    role = "assistant"
    content = $null
    tool_calls = $ToolCalls
  }

  foreach ($toolCall in $ToolCalls) {
    if ($toolCall.function.name -eq "execute") {
      # Execute the command and get structured result
      $toolResult = Invoke-PSLLMTool -ToolCall $toolCall

      # Build tool response content for API
      $toolContent = if ($toolResult.Success) {
        "Command: $($toolResult.Command)`nExit Code: $($toolResult.ExitCode)`nOutput:`n$($toolResult.Output)"
      } elseif ($toolResult.Cancelled) {
        "Command: $($toolResult.Command)`nResult: Cancelled by user"
      } else {
        "Command: $($toolResult.Command)`nError: $($toolResult.Error)"
      }

      # Add tool call response to session history
      $script:SessionHistory += @{
        role = "tool"
        tool_call_id = $toolCall.id
        name = "execute"
        content = $toolContent
      }
    }
  }

  # Recursive call with updated session history
  Write-Verbose "Making recursive API call with tool results"
  return Get-LLMResponse -UserMessage $UserMessage -SystemPrompt $SystemPrompt -ApiEndpoint $ApiEndpoint -Model $Model -NoColors:$NoColors -SkipUserMessage
}

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
    Returns structured data for session history management
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
      return @{
        Success = $false
        Cancelled = $true
        ToolCallId = $ToolCall.id
        Command = $command
        Result = "Command cancelled by user"
      }
    }
  } else {
    Write-Host "🔸 [EXECUTE] $command" -ForegroundColor Cyan
    $confirm = Read-Host "🔸 Run this command? (y/n)"
    if ($confirm -ne 'y' -and $confirm -ne 'Y') {
      return @{
        Success = $false
        Cancelled = $true
        ToolCallId = $ToolCall.id
        Command = $command
        Result = "Command cancelled by user"
      }
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

    return @{
      Success = $true
      Cancelled = $false
      ToolCallId = $ToolCall.id
      Command = $command
      ExitCode = $exitCode
      Output = $result.output
      Result = $successResult
    }
  }
  catch {
    $errorResult = "Command failed at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`nError: $($_.Exception.Message)"

    return @{
      Success = $false
      Cancelled = $false
      ToolCallId = $ToolCall.id
      Command = $command
      Error = $_.Exception.Message
      Result = $errorResult
    }
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
    [switch]$NoColors,

    [Parameter(Mandatory=$false)]
    [switch]$SkipUserMessage
  )

  begin {
    # Get API key using extracted function
    $apiKey = Get-LLMApiKey
    if ($null -eq $apiKey) {
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

    # Merge context using extracted function
    $contextString = Merge-LLMContext -Context $Context -PipelineContext $collectedPipelineContext

    try
    {
      # Assign a default system prompt if none was specified
      if ([string]::IsNullOrWhiteSpace($SystemPrompt)) {
        $SystemPrompt = Get-LLMDefaultSystemPrompt -NoColors:$NoColors -Config $config
      }

      # Keep system prompt clean - context goes in user message
      $finalSystemPrompt = $SystemPrompt

      # Create and add current user message with context (unless skipping)
      $finalUserMessage = Build-LLMUserMessage -UserMessage $UserMessage -ContextString $contextString

      $currentMessage = @{
        role = "user"
        content = $finalUserMessage
      }

      # Add to session history unless this is a recursive call
      Update-LLMSessionHistory -Message $currentMessage -Config $config -SkipUpdate:$SkipUserMessage

      # Build messages for API call using session history as single source of truth
      $messages = Get-MessagesForApiCall -SystemPrompt $finalSystemPrompt -ActiveSession $script:ActiveSession

      # Build API request using extracted function
      $apiRequest = Build-LLMApiRequest -Model $Model -Messages $messages -ApiKey $apiKey -Config $config

      Write-Verbose "Querying LLM API: $ApiEndpoint"
      Write-Verbose "Request: $($apiRequest.Body)"

      # Make the API request
      $response = Invoke-RestMethod -Uri $ApiEndpoint -Method Post -Headers $apiRequest.Headers -Body $apiRequest.Body -TimeoutSec $config.RequestTimeout

      # Handle tool calls if present
      if ($response.choices -and $response.choices.Count -gt 0)
      {
        $choice = $response.choices[0]

        # Check if there are tool calls to execute
        if ($choice.message.tool_calls)
        {
          # Process tool calls using extracted function
          return Process-LLMToolCalls -ToolCalls $choice.message.tool_calls -UserMessage $UserMessage -SystemPrompt $finalSystemPrompt -ApiEndpoint $ApiEndpoint -Model $Model -NoColors:$NoColors
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
        Update-LLMSessionHistory -Message @{role="assistant"; content=$responseText} -Config $config

        Write-Verbose "Generated response: $responseText"

        # Handle color initialization and response cleaning
        return Format-LLMResponse -ResponseText $responseText -NoColors:$NoColors -Config $config
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
