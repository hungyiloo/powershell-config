# wt — git worktree helper tuned for PR review on Windows
# ---------------------------------------------------------------------------
# Commands navigate you INTO a ready worktree (cd + ensure deps). They do not
# launch anything — once there you run 'claude', 'npm start', 'lg', etc.
#
#   wt            list worktrees (name | branch | state)
#   wt go         pick an existing worktree -> cd in
#   wt root  (r)  jump to the repo root from anywhere
#   wt new pr:ID  resolve PR ID's source branch via Azure DevOps, check it
#                 out into worktree 'pr-ID', then cd in
#   wt new wi:Q   fetch, fuzzy-match a local/remote branch containing Q,
#                 check it out into worktree 'Q', then cd in
#   wt new NAME   literal name, NO lookup -> new worktree on a new branch,
#                 based on the up-to-date origin default branch (main/master)
#   wt new        no arg -> scratch worktree on 'scratch-<slug>' branch, cd in
#   ... -FromHere on either of the above, branch from current HEAD instead
#   wt pr ID      alias for 'wt new pr:ID'
#   wt rm         pick a worktree -> remove it (always confirms) + prune,
#                 then optionally delete its local branch
#   wt prune      delete leftover scratch-* / worktree-* branches that are not
#                 checked out in any live worktree (safe: git branch -d)
#   wt help       this help
# ---------------------------------------------------------------------------

function script:Get-WtMainRoot {
    # The main working tree is always the first entry git lists.
    $first = (git worktree list --porcelain | Select-Object -First 1)
    if ($first -like 'worktree *') { return $first.Substring(9) }
    return $null
}

function script:Get-WtList {
    param([switch]$ExcludeMain)
    $root = script:Get-WtMainRoot
    if (-not $root) { return @() }
    $lines = git worktree list --porcelain
    $list = @()
    $cur = $null
    foreach ($l in $lines) {
        if ($l -like 'worktree *') {
            if ($cur) { $list += $cur }
            $cur = [pscustomobject]@{ Path=$l.Substring(9); Name=''; Branch='(detached)'; IsMain=$false; Dirty=$false }
        } elseif ($l -like 'branch *') {
            $cur.Branch = ($l.Substring(7) -replace '^refs/heads/','')
        } elseif ($l -eq 'detached') {
            $cur.Branch = '(detached)'
        }
    }
    if ($cur) { $list += $cur }

    foreach ($w in $list) {
        $w.IsMain = ($w.Path -replace '\\','/') -eq ($root -replace '\\','/')
        $w.Name  = if ($w.IsMain) { '(main)' } else { Split-Path $w.Path -Leaf }
        $w.Dirty = [bool]( git -C $w.Path status --porcelain )
    }
    if ($ExcludeMain) { $list = $list | Where-Object { -not $_.IsMain } }
    return $list
}

function script:Show-WtTable {
    param($Worktrees)
    if (-not $Worktrees) { Write-Host "No worktrees." -ForegroundColor DarkGray; return }
    $Worktrees |
        Select-Object @{n='worktree';e={$_.Name}},
                      @{n='branch';e={$_.Branch}},
                      @{n='state';e={ if ($_.Dirty) {'dirty'} else {'clean'} }} |
        Format-Table -AutoSize
}

# Generic picker: fzf if available, numbered Read-Host fallback. Returns the
# chosen object (or $null if cancelled).
function script:Select-Wt {
    param($Worktrees, [string]$Prompt = 'worktree> ')
    if (-not $Worktrees) { Write-Host "No worktrees to pick from." -ForegroundColor DarkGray; return $null }
    $Worktrees = @($Worktrees)

    if (Get-Command fzf -ErrorAction SilentlyContinue) {
        $rows = $Worktrees | ForEach-Object {
            $state  = if ($_.Dirty) {'dirty'} else {'clean'}
            $folder = if ($_.IsMain) {'main'} else {$_.Name}
            # visible field: "branch (folder) [state]"; hidden key after tab = path
            "{0} ({1}) [{2}]`t{3}" -f $_.Branch, $folder, $state, $_.Path
        }
        $sel = $rows | fzf --prompt $Prompt --with-nth=1 --delimiter "`t" --height=40% --reverse
        if (-not $sel) { return $null }
        $key = ($sel -split "`t")[-1]
        return $Worktrees | Where-Object { $_.Path -eq $key } | Select-Object -First 1
    }

    # fallback: numbered menu
    for ($i=0; $i -lt $Worktrees.Count; $i++) {
        $w = $Worktrees[$i]
        $state = if ($w.Dirty) {'dirty'} else {'clean'}
        "{0,3}  {1,-28} {2,-40} {3}" -f ($i+1), $w.Name, $w.Branch, $state
    }
    $pick = Read-Host "Pick number (blank to cancel)"
    if (-not $pick) { return $null }
    $idx = ($pick -as [int]) - 1
    if ($idx -lt 0 -or $idx -ge $Worktrees.Count) { Write-Host "Invalid selection." -ForegroundColor Red; return $null }
    return $Worktrees[$idx]
}

function script:New-WtForBranch {
    # Create a worktree at $Path checked out to $Branch (local or origin/).
    param([string]$Path, [string]$Branch)
    git show-ref --verify --quiet "refs/heads/$Branch"
    if ($LASTEXITCODE -eq 0) { git worktree add $Path $Branch }
    else { git worktree add --track -b $Branch $Path "origin/$Branch" }
    if ($LASTEXITCODE -ne 0) { Write-Host "git worktree add failed." -ForegroundColor Red; return $false }
    return $true
}

function script:Get-WtBaseRef {
    # Resolve the start-point for a brand-new branch: the up-to-date default
    # branch on origin (main/master/whatever), so scratch + new branches never
    # silently fork off whatever feature branch you happened to be standing on.
    # Returns a ref string for `git worktree add ... <ref>`, or $null meaning
    # "fall back to current HEAD" (offline / no remote default resolvable).
    $head = git symbolic-ref --quiet refs/remotes/origin/HEAD 2>$null
    if (-not $head) {
        # origin/HEAD not recorded locally — try to establish it from the remote.
        git remote set-head origin --auto *> $null
        $head = git symbolic-ref --quiet refs/remotes/origin/HEAD 2>$null
    }

    if ($head) {
        $default = $head -replace '^refs/remotes/origin/',''
        Write-Host "Fetching origin/$default for base..." -ForegroundColor Cyan
        git fetch origin $default --quiet
        return "origin/$default"
    }

    # No remote default — fall back to a local default branch, then current HEAD.
    foreach ($b in 'main','master') {
        git show-ref --verify --quiet "refs/heads/$b"
        if ($LASTEXITCODE -eq 0) {
            Write-Host "No origin default resolved; basing on local '$b'." -ForegroundColor Yellow
            return $b
        }
    }
    Write-Host "No origin/local default branch; basing on current HEAD." -ForegroundColor Yellow
    return $null
}

function script:Remove-WtTree {
    # Delete a directory tree fast. Benchmarked on the ReFS Dev Drive: native
    # `rmdir /s /q` is ~2x faster than [IO.Directory]::Delete, and parallel
    # approaches (robocopy /MT, ForEach -Parallel) are SLOWER — ReFS serializes
    # metadata ops. So: lean native fast-path, with the long-path-aware managed
    # delete as fallback if rmdir leaves anything behind (deep >260-char paths)
    # or hits a locked file. Returns $true on a fully-emptied tree.
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $true }

    cmd /c "rmdir /s /q `"$Path`"" 2>$null
    if (-not (Test-Path -LiteralPath $Path)) { return $true }

    # rmdir left residue (long path / locked file) -> robust managed delete.
    try {
        [System.IO.Directory]::Delete($Path, $true)
        return $true
    } catch {
        Write-Host "Delete failed: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "A file may be locked — is a dev server still running in that worktree? Close it and retry." -ForegroundColor Yellow
        return $false
    }
}

function script:New-WtSlug {
    # Readable adjective-noun slug for scratch worktrees, so the name reads as a
    # throwaway ("amber-otter") and never gets mistaken for a work-item number.
    $adj  = 'amber','brisk','calm','dusky','eager','fern','glint','hazel','ivory',
            'jade','keen','lush','misty','noble','ochre','pale','quiet','rust',
            'sage','teal','umber','vivid','warm','zephyr'
    $noun = 'otter','finch','heron','lynx','moth','newt','owl','pike','quail',
            'raven','seal','toad','vole','wren','bison','crane','dove','elk',
            'fox','gull','hawk','ibis','koi','yak'
    "{0}-{1}" -f (Get-Random -InputObject $adj), (Get-Random -InputObject $noun)
}

function script:New-WtNewBranch {
    # Create a worktree at $Path on a NEW branch $Branch. Default base is the
    # up-to-date origin default branch; -FromHere forks the current HEAD instead.
    param([string]$Path, [string]$Branch, [switch]$FromHere)
    if ($FromHere) {
        Write-Host "Branching from current HEAD (-FromHere)." -ForegroundColor DarkGray
        git worktree add $Path -b $Branch
    } else {
        $base = script:Get-WtBaseRef
        if ($base) { git worktree add $Path -b $Branch $base }
        else       { git worktree add $Path -b $Branch }
    }
    if ($LASTEXITCODE -ne 0) { Write-Host "git worktree add failed." -ForegroundColor Red; return $false }
    return $true
}

function script:Find-Branch {
    # Match local+remote branches containing <Query>. Returns the single match,
    # a picked match, $null (no match), or '__CANCELLED__' (picker dismissed).
    param([string]$Query)
    $refs = git for-each-ref --format '%(refname:short)' refs/heads refs/remotes/origin
    $branches = @($refs |
        Where-Object { $_ -ne 'origin/HEAD' -and $_ -like "*$Query*" } |
        ForEach-Object { $_ -replace '^origin/','' } |
        Select-Object -Unique)
    if ($branches.Count -eq 0) { return $null }
    if ($branches.Count -eq 1) { return $branches[0] }
    if (Get-Command fzf -ErrorAction SilentlyContinue) {
        $sel = $branches | fzf --prompt "branch for '$Query'> " --height=40% --reverse
        if (-not $sel) { return '__CANCELLED__' }
        return $sel
    }
    for ($i=0; $i -lt $branches.Count; $i++) { "{0,3}  {1}" -f ($i+1), $branches[$i] }
    $pick = Read-Host "Pick number (blank to cancel)"
    if (-not $pick) { return '__CANCELLED__' }
    return $branches[($pick -as [int]) - 1]
}

function script:Enter-Wt {
    # Navigate into a worktree and make sure deps are present. Does NOT launch
    # anything — you decide (claude / npm start / lg) once you're there.
    param([string]$Path)
    Set-Location -LiteralPath $Path
    if (-not (Test-Path (Join-Path $Path 'node_modules'))) {
        Write-Host "Installing dependencies (bun install --frozen-lockfile)..." -ForegroundColor Cyan
        bun install --frozen-lockfile
    }
    Write-Host "Ready in $Path" -ForegroundColor Green
}

function wt {
    [CmdletBinding()]
    param(
        [Parameter(Position=0)][string]$Command = '',
        [Parameter(Position=1)][string]$Arg,
        [switch]$FromHere
    )

    if (-not (git rev-parse --is-inside-work-tree 2>$null)) {
        Write-Host "Not inside a git repository." -ForegroundColor Red; return
    }

    switch ($Command) {

        { $_ -in '', 'list', 'ls' } {
            script:Show-WtTable (script:Get-WtList)
            Write-Host "  wt new pr:<id>  wt new wi:<q>  wt go  wt root  wt rm   |   wt help" -ForegroundColor DarkGray
        }

        'go' {
            $w = script:Select-Wt (script:Get-WtList) 'go to worktree> '
            if ($w) { script:Enter-Wt $w.Path }
        }

        { $_ -in 'root', 'r' } {
            $root = script:Get-WtMainRoot
            if ($root) { Set-Location -LiteralPath $root; Write-Host "At repo root: $root" -ForegroundColor Green }
        }

        'new' {
            $root = script:Get-WtMainRoot

            # no arg -> scratch worktree on a 'scratch-<slug>' branch, then cd in
            if (-not $Arg) {
                do {
                    $name = "scratch-$(script:New-WtSlug)"
                    $path = Join-Path $root ".claude/worktrees/$name"
                } while (Test-Path $path)
                Write-Host "Creating scratch worktree '$name'..." -ForegroundColor DarkGray
                if (script:New-WtNewBranch $path $name -FromHere:$FromHere) { script:Enter-Wt $path }
                return
            }

            # pr:<id> -> Azure DevOps PR lookup (delegate to canonical handler)
            if ($Arg -match '^pr:(.+)$') { wt pr $Matches[1]; return }

            # wi:<q> -> fuzzy branch match (local + remote)
            if ($Arg -match '^wi:(.+)$') {
                $q = $Matches[1]
                $path = Join-Path $root ".claude/worktrees/$q"
                if (Test-Path $path) {
                    Write-Host "Worktree '$q' already exists -> entering it." -ForegroundColor Yellow
                    script:Enter-Wt $path; return
                }
                Write-Host "Fetching from origin..." -ForegroundColor Cyan
                git fetch --all --prune --quiet
                $branch = script:Find-Branch $q
                if ($branch -eq '__CANCELLED__') { Write-Host "Cancelled." -ForegroundColor DarkGray; return }
                if (-not $branch) { Write-Host "No local or remote branch matches '$q'. (Use 'wt new <name>' to create one.)" -ForegroundColor Yellow; return }
                Write-Host "Matched branch: $branch" -ForegroundColor Green
                if (script:New-WtForBranch $path $branch) { script:Enter-Wt $path }
                return
            }

            # literal name -> NO lookup, new worktree on a new branch
            $name = $Arg
            $path = Join-Path $root ".claude/worktrees/$name"
            if (Test-Path $path) {
                Write-Host "Worktree '$name' already exists -> entering it." -ForegroundColor Yellow
                script:Enter-Wt $path; return
            }
            if (script:New-WtNewBranch $path $name -FromHere:$FromHere) { script:Enter-Wt $path }
        }

        'pr' {
            if (-not $Arg) { Write-Host "Usage: wt pr <pr-id>" -ForegroundColor Red; return }
            if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
                Write-Host "Azure CLI ('az') not found." -ForegroundColor Red; return
            }
            $root = script:Get-WtMainRoot
            $prid = $Arg
            $path = Join-Path $root ".claude/worktrees/pr-$prid"
            if (Test-Path $path) {
                Write-Host "Worktree 'pr-$prid' already exists -> entering it." -ForegroundColor Yellow
                script:Enter-Wt $path
                return
            }

            Write-Host "Resolving PR !$prid via Azure DevOps..." -ForegroundColor Cyan
            $ref = az repos pr show --id $prid --detect true --query "sourceRefName" -o tsv 2>$null
            if (-not $ref) { Write-Host "Could not resolve PR !$prid (not found, or 'az' not logged in)." -ForegroundColor Red; return }
            $branch = $ref -replace '^refs/heads/',''
            Write-Host "PR !$prid -> $branch" -ForegroundColor Green

            git fetch --all --prune --quiet
            if (script:New-WtForBranch $path $branch) { script:Enter-Wt $path }
        }

        'rm' {
            $w = script:Select-Wt (script:Get-WtList -ExcludeMain) 'remove worktree> '
            if (-not $w) { return }

            $dirtyNote = if ($w.Dirty) { " [has UNCOMMITTED changes]" } else { "" }
            Write-Host ("About to remove: {0}  ({1}){2}" -f $w.Name, $w.Branch, $dirtyNote) -ForegroundColor $(if ($w.Dirty){'Red'}else{'Yellow'})
            $yn = Read-Host "Confirm removal? (y/N)"
            if ($yn -notmatch '^(y|yes)$') { Write-Host "Aborted." -ForegroundColor DarkGray; return }

            # step out so we're never inside the target while removing
            $root = script:Get-WtMainRoot
            Set-Location -LiteralPath $root

            # safety: only ever fast-delete something under this repo's .claude/worktrees
            $wtBase = (Join-Path $root '.claude\worktrees') -replace '\\','/'
            $target = $w.Path -replace '\\','/'
            if (-not $target.StartsWith($wtBase, [System.StringComparison]::OrdinalIgnoreCase)) {
                Write-Host "Refusing to delete '$($w.Path)' — not under .claude/worktrees." -ForegroundColor Red
                return
            }

            # Fast native delete (rmdir), managed fallback; then prune the
            # now-dangling worktree admin record.
            Write-Host "Deleting files..." -ForegroundColor Cyan
            if (-not (script:Remove-WtTree $w.Path)) { return }
            git worktree prune --expire now
            Write-Host "Removed worktree '$($w.Name)'." -ForegroundColor Green

            if ($w.Branch -and $w.Branch -ne '(detached)') {
                $yn2 = Read-Host "Also delete local branch '$($w.Branch)'? (y/N)"
                if ($yn2 -match '^(y|yes)$') {
                    git branch -D $w.Branch
                    if ($LASTEXITCODE -eq 0) { Write-Host "Deleted branch '$($w.Branch)'." -ForegroundColor Green }
                }
            }
        }

        'prune' {
            # Delete leftover scratch branches that aren't checked out in any live
            # worktree: 'scratch-*' (wt new, no arg) and 'worktree-*' (legacy /
            # claude --worktree). Strip git's leading '*' (current) / '+' (checked
            # out elsewhere) markers before comparing, or the names never match.
            $live = @(script:Get-WtList | ForEach-Object { $_.Branch })
            $scratch = @(git branch --list 'scratch-*' 'worktree-*' |
                ForEach-Object { ($_ -replace '^[*+]?\s*', '').Trim() })
            $orphans = @($scratch | Where-Object { $_ -and ($_ -notin $live) })

            if ($orphans.Count -eq 0) { Write-Host "No orphaned scratch branches." -ForegroundColor Green; return }

            Write-Host "Orphaned scratch branches:" -ForegroundColor Yellow
            $orphans | ForEach-Object { Write-Host "  $_" }
            $yn = Read-Host "Delete these $($orphans.Count) branch(es)? (y/N)"
            if ($yn -notmatch '^(y|yes)$') { Write-Host "Aborted." -ForegroundColor DarkGray; return }

            foreach ($b in $orphans) {
                git branch -d $b 2>$null
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "Deleted $b" -ForegroundColor Green
                } else {
                    Write-Host "Kept $b — has unmerged commits. Use 'git branch -D $b' if you're sure." -ForegroundColor Red
                }
            }
        }

        { $_ -in 'help', '--help', '/?' } {
            @"
wt — git worktree helper

  Commands navigate you INTO a ready worktree (cd + deps). They do NOT
  launch anything — once there, run 'claude', 'npm start', 'lg', etc.

  wt              list worktrees (name | branch | state)
  wt go           pick an existing worktree -> cd in
  wt root  (wt r) jump to the repo root from anywhere
  wt new pr:9114  resolve PR 9114 via Azure DevOps -> worktree 'pr-9114' -> cd in
  wt new wi:14781 fuzzy-match branch *14781* -> worktree '14781' -> cd in
  wt new my-name  literal name, NO lookup -> new branch + worktree -> cd in
                  (based on up-to-date origin default branch: main/master)
  wt new          scratch worktree on 'scratch-<slug>' branch -> cd in
  ...  -FromHere  on 'wt new'/'wt new NAME': branch from current HEAD instead
  wt pr 9114      alias for 'wt new pr:9114'
  wt rm           pick a worktree -> confirm -> remove + prune,
                  then optionally delete its local branch
  wt prune        delete leftover scratch-* / worktree-* branches not
                  checked out in any live worktree (safe: git branch -d)
  wt help         this help
"@ | Write-Host
        }

        default {
            Write-Host "Unknown subcommand '$Command'. Try: wt help" -ForegroundColor Red
        }
    }
}
