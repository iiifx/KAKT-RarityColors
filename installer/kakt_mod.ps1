# Installs or removes a King Arthur: Knight's Tale mod with a backup of every replaced file.
# Usage: powershell -ExecutionPolicy Bypass -File kakt_mod.ps1 install|uninstall
#            [--game PATH] [--with COMPONENT] [--yes] [--force] [--discard-backup]
# Works with Windows PowerShell 5.1 and PowerShell 7.

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

$AppId = '1157390'
$GameDirName = "King Arthur Knight's Tale"
$ModRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$Manifest = Join-Path (Join-Path $ModRoot 'installer') 'manifest.txt'
$Utf8 = New-Object System.Text.UTF8Encoding($false)

function Say([string]$text) { Write-Host $text }
function Fail([string]$text) {
    Write-Host "ERROR: $text"
    Write-Host 'Failed. Nothing was changed.'
    exit 1
}

function Show-Usage {
    Say 'Usage: kakt_mod.ps1 install|uninstall [options]'
    Say '  --game PATH        game folder (default: found through Steam)'
    Say '  --with COMPONENT   also install an optional component (install)'
    Say '  --yes              answer yes to all questions'
    Say '  --force            install over files changed by something else (install)'
    Say '  --discard-backup   forget a backup that can no longer be restored (uninstall)'
    exit 1
}

# ---------------------------------------------------------------- arguments

$Action = ''
$Game = ''
$With = @()
$Yes = $false
$Force = $false
$Discard = $false
$i = 0
if ($args.Count -gt 0) { $Action = [string]$args[0]; $i = 1 }
while ($i -lt $args.Count) {
    switch ([string]$args[$i]) {
        '--game' { if ($i + 1 -ge $args.Count) { Show-Usage }; $i++; $Game = [string]$args[$i] }
        '--with' { if ($i + 1 -ge $args.Count) { Show-Usage }; $i++; $With += [string]$args[$i] }
        '--yes' { $Yes = $true }
        '--force' { $Force = $true }
        '--discard-backup' { $Discard = $true }
        default { Show-Usage }
    }
    $i++
}
if ($Action -ne 'install' -and $Action -ne 'uninstall') { Show-Usage }

# ---------------------------------------------------------------- helpers

function Test-Interactive {
    return [Environment]::UserInteractive -and -not [Console]::IsInputRedirected
}

function Ask([string]$question) {
    if ($Yes) { return $true }
    if (-not (Test-Interactive)) { return $false }
    $answer = Read-Host "$question [y/N]"
    return $answer -match '^(y|yes)$'
}

function Get-Sha256([string]$path) {
    # .NET directly: Get-FileHash lives in a module that may fail to load (e.g. a foreign PSModulePath)
    if (-not [IO.File]::Exists($path)) { return '-' }
    $sha = [Security.Cryptography.SHA256]::Create()
    $stream = [IO.File]::OpenRead($path)
    try { $bytes = $sha.ComputeHash($stream) } finally { $stream.Dispose(); $sha.Dispose() }
    return ([BitConverter]::ToString($bytes) -replace '-', '').ToLowerInvariant()
}

function Join-Rel([string]$base, [string]$rel) {
    # plain string paths: no wildcard or drive checks
    return [IO.Path]::Combine($base, ($rel -replace '/', [IO.Path]::DirectorySeparatorChar))
}

function Test-GameRunning {
    if ($env:KAKT_FAKE_RUNNING -eq '1') { return $true }
    if ($env:KAKT_FAKE_RUNNING -eq '0') { return $false }
    return [bool](Get-Process -Name 'KA_KT' -ErrorAction SilentlyContinue)
}

function Test-GameFolder([string]$dir) {
    return [IO.File]::Exists([IO.Path]::Combine($dir, 'KA_KT.exe')) -and
        [IO.Directory]::Exists([IO.Path]::Combine($dir, 'Cfg')) -and
        [IO.Directory]::Exists([IO.Path]::Combine($dir, 'Strings'))
}

function Get-SteamLibraries {
    $roots = @()
    try {
        $steamPath = (Get-ItemProperty -Path 'HKCU:\Software\Valve\Steam' -Name SteamPath -ErrorAction Stop).SteamPath
        if ($steamPath) { $roots += ($steamPath -replace '/', '\') }
    } catch { }
    if (${env:ProgramFiles(x86)}) { $roots += (Join-Path ${env:ProgramFiles(x86)} 'Steam') }
    if ($env:ProgramFiles) { $roots += (Join-Path $env:ProgramFiles 'Steam') }
    $libraries = @()
    foreach ($root in $roots) {
        try {
            if (-not [IO.Directory]::Exists([IO.Path]::Combine($root, 'steamapps'))) { continue }
            $libraries += $root
            $vdf = [IO.Path]::Combine($root, 'steamapps', 'libraryfolders.vdf')
            if ([IO.File]::Exists($vdf)) {
                foreach ($line in [IO.File]::ReadAllLines($vdf)) {
                    if ($line -match '^\s*"path"\s*"(.*)"\s*$') { $libraries += ($Matches[1] -replace '\\\\', '\') }
                }
            }
        } catch { }
    }
    return $libraries
}

function Resolve-Game {
    $dir = $script:Game
    if (-not $dir) {
        foreach ($lib in Get-SteamLibraries) {
            # a library on an unplugged drive must not stop the search
            try {
                $candidate = [IO.Path]::Combine($lib, 'steamapps', 'common', $GameDirName)
                if (Test-GameFolder $candidate) { $dir = $candidate; break }
            } catch { }
        }
        if (-not $dir) {
            if (-not (Test-Interactive)) { Fail 'game folder not found; pass it with --game PATH' }
            $dir = Read-Host "Game folder not found. Enter the path to the `"$GameDirName`" folder"
        }
    }
    if (-not $dir -or -not (Test-GameFolder $dir)) {
        Fail "not a King Arthur: Knight's Tale folder (KA_KT.exe, Cfg, Strings expected): $dir"
    }
    $script:Game = (Resolve-Path -LiteralPath $dir).ProviderPath
    Say "Game folder: $script:Game"
}

function Get-GameBuildId {
    $acf = Join-Path (Split-Path -Parent (Split-Path -Parent $script:Game)) "appmanifest_$AppId.acf"
    if (Test-Path -LiteralPath $acf -PathType Leaf) {
        foreach ($line in [IO.File]::ReadAllLines($acf)) {
            if ($line -match '^\s*"buildid"\s*"(\d*)"') { return $Matches[1] }
        }
    }
    return '-'
}

function Read-Tsv([string]$path) {
    # list of string arrays, one per non-empty line
    $rows = New-Object System.Collections.ArrayList
    foreach ($line in [IO.File]::ReadAllLines($path, $Utf8)) {
        if ($line.Length -gt 0) { [void]$rows.Add($line.Split("`t")) }
    }
    return , $rows
}

function Get-Header($rows, [string]$key) {
    foreach ($row in $rows) { if ($row[0] -eq $key -and $row.Count -ge 2) { return $row[1] } }
    return $null
}

function Write-State([string]$status) {
    $lines = @(
        "mod`t$script:ModName",
        "version`t$script:Version",
        "buildid`t$script:BuildId",
        "status`t$status",
        "components`t$($script:Components -join ' ')"
    )
    $warning = Get-Header $script:ManifestRows 'uninstall_warning'
    if ($warning) { $lines += "uninstall_warning`t$warning" }
    foreach ($f in $script:StateFiles) { $lines += "file`t$($f.Target)`t$($f.Backup)`t$($f.Installed)" }
    $tmp = "$script:StateFile.tmp"
    [IO.File]::WriteAllText($tmp, (($lines -join "`n") + "`n"), $Utf8)
    [IO.File]::Copy($tmp, $script:StateFile, $true)
    [IO.File]::Delete($tmp)
}

function Copy-File([string]$from, [string]$to) {
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($to))
    [IO.File]::Copy($from, $to, $true)
}

function Remove-Backup {
    if (Test-Path -LiteralPath $script:BackupDir) {
        Remove-Item -LiteralPath $script:BackupDir -Recurse -Force
    }
    $parent = Join-Path $script:Game '_mod_backups'
    if ((Test-Path -LiteralPath $parent) -and -not (Get-ChildItem -LiteralPath $parent -Force)) {
        Remove-Item -LiteralPath $parent -Force
    }
}

function Get-StateFiles($rows) {
    $files = @()
    foreach ($row in $rows) {
        if ($row[0] -eq 'file') {
            $files += [pscustomobject]@{ Target = $row[1]; Backup = $row[2]; Installed = $row[3] }
        }
    }
    return , $files
}

function Load-Manifest {
    if (-not (Test-Path -LiteralPath $Manifest -PathType Leaf)) {
        Fail 'installer/manifest.txt is missing; extract the whole mod archive'
    }
    $script:ManifestRows = Read-Tsv $Manifest
    $script:ModName = Get-Header $script:ManifestRows 'mod'
    $script:Version = Get-Header $script:ManifestRows 'version'
    if (-not $script:ModName -or -not $script:Version) { Fail 'broken manifest' }
    $script:ModBuildId = Get-Header $script:ManifestRows 'buildid'
    if (-not $script:ModBuildId) { $script:ModBuildId = '-' }
    $script:BackupDir = Join-Path (Join-Path $script:Game '_mod_backups') $script:ModName
    $script:StateFile = Join-Path $script:BackupDir 'state.txt'
}

function Show-List([string[]]$items) {
    $items | Select-Object -First 20 | ForEach-Object { Say "  $_" }
    if ($items.Count -gt 20) { Say "  ... and $($items.Count - 20) more" }
}

# ---------------------------------------------------------------- install

function Invoke-Install {
    Resolve-Game
    if (Test-GameRunning) { Fail 'the game is running; close it first' }
    Load-Manifest
    Say "Installing $script:ModName $script:Version"
    $script:BuildId = Get-GameBuildId
    if ($script:ModBuildId -ne '-' -and $script:BuildId -ne '-' -and $script:BuildId -ne $script:ModBuildId) {
        Say "WARNING: this mod was made for game build $script:ModBuildId, the installed build is $script:BuildId."
    }

    if (Test-Path -LiteralPath $script:StateFile -PathType Leaf) {
        $state = Read-Tsv $script:StateFile
        $status = Get-Header $state 'status'
        $installedComponents = @((Get-Header $state 'components') -split ' ')
        if ($status -eq 'installing') {
            Fail 'an earlier installation did not finish; run the uninstaller to roll it back'
        }
        $files = Get-StateFiles $state
        $nInstalled = 0; $nOriginal = 0
        foreach ($f in $files) {
            $current = Get-Sha256 (Join-Rel $script:Game $f.Target)
            if ($current -eq $f.Installed) { $nInstalled++ }
            elseif ($current -eq $f.Backup) { $nOriginal++ }
        }
        if ($nInstalled -eq $files.Count -and $status -eq 'installed') {
            $installedVersion = Get-Header $state 'version'
            if ($installedVersion -ne $script:Version) {
                Fail "$script:ModName $installedVersion is installed; run its uninstaller before installing $script:Version"
            }
            foreach ($c in $With) {
                if ($installedComponents -notcontains $c) {
                    Fail "$script:ModName is installed without $c; uninstall it and install again with --with $c"
                }
            }
            Say "$script:ModName $(Get-Header $state 'version') is already installed. Nothing changed."
            exit 0
        } elseif ($nOriginal -eq $files.Count) {
            Say 'The mod files were replaced by the original ones (Steam file verification or update).'
            Say 'Removing the outdated backup and installing again.'
            Remove-Backup
        } elseif ($status -eq 'partial') {
            Fail 'a previous removal could not restore every file; run the uninstaller with --discard-backup first'
        } else {
            Fail 'files of the installed mod were changed since installation; run the uninstaller first'
        }
    } elseif (Test-Path -LiteralPath $script:BackupDir) {
        Say 'Removing an incomplete backup folder left by an interrupted installation.'
        Remove-Backup
    }

    $optional = @()
    foreach ($row in $script:ManifestRows) {
        if ($row[0] -eq 'file' -and $row[1] -ne 'core' -and $optional -notcontains $row[1]) { $optional += $row[1] }
    }
    foreach ($c in $With) {
        if ($optional -notcontains $c) { Fail "unknown component: $c (available: $($optional -join ' '))" }
    }
    $script:Components = @('core')
    foreach ($c in $optional) {
        if ($With -contains $c) { $script:Components += $c }
        elseif ($With.Count -eq 0 -and -not $Yes -and (Test-Interactive) -and (Ask "Install the optional component $c?")) {
            $script:Components += $c
        }
    }

    # pre-flight: nothing is changed until every file checks out
    $plan = @()
    $problems = @()
    foreach ($row in $script:ManifestRows) {
        if ($row[0] -ne 'file' -or $script:Components -notcontains $row[1]) { continue }
        $src = $row[2]; $target = $row[3]; $vanilla = $row[4]; $modHash = $row[5]
        if ((Get-Sha256 (Join-Rel $ModRoot $src)) -ne $modHash) {
            $problems += "damaged or missing in the mod archive: $src"
            continue
        }
        $current = Get-Sha256 (Join-Rel $script:Game $target)
        if ($current -eq $vanilla) { }
        elseif ($current -eq $modHash) { $problems += "already contains the mod (copied by hand?): $target" }
        elseif ($current -eq '-') { $problems += "missing in the game folder: $target" }
        elseif (-not $Force) { $problems += "changed by a game update or another mod: $target" }
        $plan += [pscustomobject]@{ Source = $src; Target = $target; Current = $current; ModHash = $modHash }
    }
    if ($problems.Count -gt 0) {
        Show-List $problems
        if ($problems -match '^already contains the mod') {
            Say 'The mod seems to be installed by hand. Restore the original files first:'
            Say 'Steam -> right-click the game -> Properties -> Installed Files -> Verify integrity of game files.'
        } elseif ($problems -match '^changed by') {
            Say 'Use --force to install anyway; those files will be backed up as they are now.'
        }
        Fail 'the game files do not match what this mod expects'
    }

    # backup
    Say "Backing up the original files to $script:BackupDir"
    $script:StateFiles = @()
    try {
        [void][IO.Directory]::CreateDirectory([IO.Path]::Combine($script:BackupDir, 'files'))
        foreach ($p in $plan) {
            if ($p.Current -ne '-') {
                $copy = Join-Rel (Join-Path $script:BackupDir 'files') $p.Target
                Copy-File (Join-Rel $script:Game $p.Target) $copy
                if ((Get-Sha256 $copy) -ne $p.Current) { throw "backup check failed: $($p.Target)" }
            }
            $script:StateFiles += [pscustomobject]@{ Target = $p.Target; Backup = $p.Current; Installed = $p.ModHash }
        }
        Write-State 'installing'
    } catch {
        Remove-Backup
        Fail "cannot back up the original files: $($_.Exception.Message)"
    }

    # copy
    Say 'Copying the mod files'
    $n = 0
    foreach ($p in $plan) {
        $n++
        # test hooks: simulate a crash or a failed copy after N files
        if ($env:KAKT_CRASH_AFTER -and $n -gt [int]$env:KAKT_CRASH_AFTER) { exit 99 }
        $ok = $true
        if ($env:KAKT_FAIL_AFTER -and $n -gt [int]$env:KAKT_FAIL_AFTER) { $ok = $false }
        if ($ok) {
            try {
                $dest = Join-Rel $script:Game $p.Target
                Copy-File (Join-Rel $ModRoot $p.Source) $dest
                if ((Get-Sha256 $dest) -ne $p.ModHash) { $ok = $false }
            } catch { $ok = $false }
        }
        if (-not $ok) {
            Write-Host "ERROR: cannot copy $($p.Target); restoring the original files"
            $restored = $true
            foreach ($f in $script:StateFiles) {
                $dest = Join-Rel $script:Game $f.Target
                try {
                    if ($env:KAKT_FAIL_RESTORE -eq '1') { throw 'test hook' }
                    if ($f.Backup -eq '-') {
                        if ([IO.File]::Exists($dest)) { [IO.File]::Delete($dest) }
                    } else {
                        Copy-File (Join-Rel (Join-Path $script:BackupDir 'files') $f.Target) $dest
                        if ((Get-Sha256 $dest) -ne $f.Backup) { $restored = $false }
                    }
                } catch { $restored = $false }
            }
            if ($restored) {
                Remove-Backup
                Say 'Failed. The game folder was restored.'
                Say 'If this keeps happening, try running the installer as administrator.'
            } else {
                Write-Host "ERROR: some original files could not be restored; the backup is kept in $script:BackupDir."
                Say 'Run the uninstaller to finish restoring, or verify the game files in Steam.'
                Say 'Failed.'
            }
            exit 1
        }
    }
    try { Write-State 'installed' } catch {
        Write-Host "ERROR: the mod files are copied but $script:StateFile could not be updated; run the uninstaller."
        exit 1
    }
    Say "Installed $script:ModName $script:Version ($($script:Components -join ' '))."
    $note = Get-Header $script:ManifestRows 'note_install'
    if ($note) { Say $note }
    Say 'Done.'
    exit 0
}

# ---------------------------------------------------------------- uninstall

function Invoke-Uninstall {
    Resolve-Game
    if (Test-GameRunning) { Fail 'the game is running; close it first' }
    Load-Manifest
    if (-not (Test-Path -LiteralPath $script:StateFile -PathType Leaf)) {
        if (Test-Path -LiteralPath $script:BackupDir) { Remove-Backup }
        Say "$script:ModName is not installed by this script. Nothing changed."
        Say 'If you copied it by hand, remove it with Steam: Properties -> Installed Files -> Verify integrity of game files.'
        exit 0
    }
    $state = Read-Tsv $script:StateFile
    $status = Get-Header $state 'status'
    Say "Removing $script:ModName $(Get-Header $state 'version')"
    $warning = Get-Header $state 'uninstall_warning'
    if ($status -eq 'installing') {
        Say 'The installation did not finish; rolling it back.'
    } elseif ($status -ne 'partial' -and $warning) {
        Say 'WARNING:'
        Say "  $warning"
        if (-not (Ask 'Remove the mod anyway?')) { Say 'Cancelled. Nothing changed.'; exit 1 }
    }
    $nowBuildId = Get-GameBuildId
    $stateBuildId = Get-Header $state 'buildid'
    if ($nowBuildId -ne '-' -and $stateBuildId -and $stateBuildId -ne '-' -and $nowBuildId -ne $stateBuildId) {
        Say "The game was updated since the mod was installed (build $stateBuildId -> $nowBuildId)."
        Say 'Files changed by the update are kept; the backup of them is outdated.'
    }

    $skipped = @()
    foreach ($f in (Get-StateFiles $state)) {
        $dest = Join-Rel $script:Game $f.Target
        $current = Get-Sha256 $dest
        if ($current -eq $f.Backup) { continue }
        if ($current -ne $f.Installed) { $skipped += $f.Target; continue }
        try {
            if ($f.Backup -eq '-') {
                [IO.File]::Delete($dest)
            } else {
                $copy = Join-Rel (Join-Path $script:BackupDir 'files') $f.Target
                if ((Get-Sha256 $copy) -ne $f.Backup) { $skipped += $f.Target; continue }
                Copy-File $copy $dest
                if ((Get-Sha256 $dest) -ne $f.Backup) { $skipped += $f.Target }
            }
        } catch { $skipped += $f.Target }
    }

    if ($skipped.Count -eq 0) {
        Remove-Backup
        Say "Removed $script:ModName. The original files are restored."
        Say 'Done.'
        exit 0
    }
    Say "$($skipped.Count) file(s) were changed after installation (game update, file verification or another mod) and were left as they are:"
    Show-List $skipped
    if ($Discard -or (Ask 'Forget the backup of these files so the mod can be installed again?')) {
        Remove-Backup
        Say 'The backup was removed. To be sure every game file is original, verify the game files in Steam.'
    } else {
        $lines = @([IO.File]::ReadAllLines($script:StateFile, $Utf8) | Where-Object { $_ -notmatch "^status`t" })
        $lines += "status`tpartial"
        [IO.File]::WriteAllText($script:StateFile, (($lines -join "`n") + "`n"), $Utf8)
        Say 'The backup is kept. Run the uninstaller with --discard-backup to forget it.'
    }
    Say 'Partly done.'
    exit 2
}

if ($Action -eq 'install') { Invoke-Install } else { Invoke-Uninstall }
