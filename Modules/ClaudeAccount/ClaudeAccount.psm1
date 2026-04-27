$ClaudeJson       = "$env:USERPROFILE\.claude.json"
$CredentialsJson  = "$env:USERPROFILE\.claude\.credentials.json"
$WorkJson         = "$env:USERPROFILE\.claude.work.json"
$WorkCredJson     = "$env:USERPROFILE\.claude.work.credentials.json"
$PersonalJson     = "$env:USERPROFILE\.claude.personal.json"
$PersonalCredJson = "$env:USERPROFILE\.claude.personal.credentials.json"

function Get-ClaudeAccount {
    if (-not (Test-Path $ClaudeJson)) { Write-Warning "~/.claude.json not found"; return }
    $j = Get-Content $ClaudeJson -Raw | ConvertFrom-Json
    $email = $j.oauthAccount?.emailAddress
    if ($email) { Write-Host "Current Claude account: $email" }
    else         { Write-Host "Current Claude account: (no oauthAccount found — possibly logged out)" }
}

function Switch-ClaudeAccount {
    param(
        [Parameter(Position = 0)]
        [ValidateSet('work', 'personal')]
        [string]$To
    )

    if (-not (Test-Path $ClaudeJson)) { Write-Warning "~/.claude.json not found"; return }

    # Detect current account so we know which slot to save back to
    $j = Get-Content $ClaudeJson -Raw | ConvertFrom-Json
    $currentEmail = $j.oauthAccount?.emailAddress

    # If no explicit target, toggle based on current state
    if (-not $To) {
        $To = if (Test-Path $WorkJson) {
            $workEmail = (Get-Content $WorkJson -Raw | ConvertFrom-Json).oauthAccount?.emailAddress
            if ($currentEmail -eq $workEmail) { 'personal' } else { 'work' }
        } else { 'personal' }
    }

    # Save current files to the appropriate slot
    $saveSlot     = if ($To -eq 'personal') { $WorkJson } else { $PersonalJson }
    $saveCredSlot = if ($To -eq 'personal') { $WorkCredJson } else { $PersonalCredJson }
    Copy-Item $ClaudeJson $saveSlot
    if (Test-Path $CredentialsJson) { Copy-Item $CredentialsJson $saveCredSlot }
    Write-Host "Saved current config to $(Split-Path $saveSlot -Leaf)"

    # Load the target slot
    $loadSlot     = if ($To -eq 'work') { $WorkJson } else { $PersonalJson }
    $loadCredSlot = if ($To -eq 'work') { $WorkCredJson } else { $PersonalCredJson }
    if (-not (Test-Path $loadSlot)) {
        Write-Warning "No saved '$To' config found at $loadSlot — log in to Claude Code first, then run Switch-ClaudeAccount to save it."
        return
    }

    Copy-Item $loadSlot $ClaudeJson
    if (Test-Path $loadCredSlot) { Copy-Item $loadCredSlot $CredentialsJson }
    $newEmail = (Get-Content $ClaudeJson -Raw | ConvertFrom-Json).oauthAccount?.emailAddress
    Write-Host "Switched to $To account: $newEmail"
    Write-Host "Restart Claude Code for the change to take effect."
}

Export-ModuleMember -Function Get-ClaudeAccount, Switch-ClaudeAccount
