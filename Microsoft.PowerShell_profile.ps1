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

# PowerToys CommandNotFound module
Import-Module -Name Microsoft.WinGet.CommandNotFound
