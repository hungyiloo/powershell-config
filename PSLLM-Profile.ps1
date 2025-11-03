# PSLLM Profile Configuration
# Add this to your PowerShell profile ($PROFILE)

# Import the PSLLM module
Import-Module "$PSScriptRoot\PSLLM.psm1" -Force

# Environment setup reminder
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
