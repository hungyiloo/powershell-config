# init oh-my-posh and set a custom theme
oh-my-posh init pwsh --config '~\OneDrive\Documents\PowerShell\tiwahu-custom.omp.json' | Invoke-Expression

# use eza to replace "ls" and also define convenience "ll" and "la" shortcuts
function Invoke-My-Ls { eza --icons=always --color=always $args }
Set-Alias -Name ls -Value Invoke-My-Ls
function Invoke-My-Ll { eza --icons=always --color=always -l $args }
Set-Alias -Name ll -Value Invoke-My-Ll
function Invoke-My-La { eza --icons=always --color=always -la $args }
Set-Alias -Name la -Value Invoke-My-La

# set up "bat" to replace "cat"
Set-Alias -Name cat -Value bat

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

