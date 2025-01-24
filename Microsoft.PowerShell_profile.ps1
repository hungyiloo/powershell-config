# NOTE:
# This file should go in ~\Documents\PowerShell\
# even though the normal profile dir is ~\OneDrive\Documents\PowerShell\
# This prevents PowerShell junk from being uploaded into OneDrive.
# ---
# In the OneDrive profile dir, make sure you have a
# Microsoft.PowerShell_profile.ps1 file to do a redirect:
#
# $profile = "$env:UserProfile/Documents/PowerShell/Microsoft.PowerShell_profile.ps1"
# .$profile

# init oh-my-posh and set a custom theme
oh-my-posh init pwsh --config '~\Documents\PowerShell\tiwahu-custom.omp.json' | Invoke-Expression

# ensure modules in the local Documents PowerShell folder can be found
$env:PSModulePath = $env:PSModulePath + ";$env:UserProfile/Documents/PowerShell/Modules"

# use eza to replace "ls" and also define convenience "ll" and "la" shortcuts
function Invoke-My-Ls { eza --icons=always --color=auto $args }
Set-Alias -Name ls -Value Invoke-My-Ls
function Invoke-My-Ll { eza --icons=always --color=auto -l $args }
Set-Alias -Name ll -Value Invoke-My-Ll
function Invoke-My-La { eza --icons=always --color=auto -la $args }
Set-Alias -Name la -Value Invoke-My-La

# set up "bat" to replace "cat"
Set-Alias -Name cat -Value bat

# set up shortcut for lazygit
Set-Alias -Name lg -Value lazygit

# set up zoxide "z" command to replace "cd"
Invoke-Expression (& { (zoxide init powershell --cmd cd | Out-String) })

#f45873b3-b655-43a6-b217-97c00aa0db58 PowerToys CommandNotFound module
Import-Module -Name Microsoft.WinGet.CommandNotFound
#f45873b3-b655-43a6-b217-97c00aa0db58

# a convenience command for refreshing PATH
function Reset-Path 
{ 
  $env:PATH = 
    [System.Environment]::GetEnvironmentVariable("Path","Machine") + 
    ";" + 
    [System.Environment]::GetEnvironmentVariable("Path","User") 
}

# PSFzf setup
Set-PsFzfOption -PSReadlineChordProvider 'Ctrl+t' -PSReadlineChordReverseHistory 'Ctrl+r'
Set-PSReadLineKeyHandler -Key Tab -ScriptBlock { Invoke-FzfTabCompletion }
