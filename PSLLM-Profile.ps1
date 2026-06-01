# PSLLM Profile Configuration
# Add this to your PowerShell profile ($PROFILE)

# Import the PSLLM module
Import-Module "$PSScriptRoot\PSLLM.psm1" -Force

# Provider config: Google AI Studio (Gemini API) via its OpenAI-compatible endpoint.
# Gemma 4 26B — free tier: 15 RPM, unlimited TPM, 1,500 RPD. Supports tool calling.
# Gemma is a thinking model. reasoning_effort is effectively a binary toggle on it:
# only "minimal" (thinking fully off) and "high" (thinking on) are accepted — low,
# medium, and none all 400. We use "minimal" to suppress its <thought> output. The
# PSLLM <thought> stripper remains as defense-in-depth. Set PSLLM_REASONING_EFFORT=""
# if you ever swap to a model that rejects the field.
$env:PSLLM_API_ENDPOINT     = "https://generativelanguage.googleapis.com/v1beta/openai"
$env:PSLLM_MODEL            = "gemma-4-26b-a4b-it"
$env:PSLLM_REASONING_EFFORT = "minimal"
$env:PSLLM_MAX_TOKENS       = "1024"

# Environment setup reminder — set your Google AI Studio key (starts with "AIza"):
#   $env:PSLLM_API_KEY = 'AIza...'   (or add it to your system environment variables)
# Generate one at https://aistudio.google.com/apikey
if (-not $env:PSLLM_API_KEY)
{
  Write-Warning "PSLLM_API_KEY environment variable not set!"
  Write-Host "Set it with: `$env:PSLLM_API_KEY = 'your-api-key-here'" -ForegroundColor Yellow
  Write-Host "Or add it to your system environment variables for persistence" -ForegroundColor Yellow
}

# PSReadLine key bindings for LLM completion
# Ctrl+Alt+L: Complete current line with LLM (primary method)
Set-PSReadLineKeyHandler -Chord 'Ctrl+Alt+L' -BriefDescription 'LLMCompleteCurrent' -ScriptBlock {
    Invoke-LLMCompleteCurrentLine
}

# Ctrl+Alt+K: Insert last generated LLM command
Set-PSReadLineKeyHandler -Chord 'Ctrl+Alt+K' -BriefDescription 'LLMInsertLast' -ScriptBlock {
    Invoke-InsertLastLLMCommand
}

# Convenient aliases
Set-Alias -Name ask -Value Get-LLMResponse
Set-Alias -Name gen -Value Get-LLMCommand
