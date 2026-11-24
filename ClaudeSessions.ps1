# =================================================================
#  Claude Launcher - lecture des sessions Claude Code locales
#  Fichiers : <config Claude>\projects\<dossier encode>\<sessionId>.jsonl
#  Fonctions sans UI (testables isolement), dot-sourcees par
#  ClaudeLauncher.ps1.
#
#  Pour rester rapide (certains .jsonl font plusieurs dizaines de Mo),
#  on ne lit que le debut et la fin de chaque fichier :
#    - debut : cwd, branche git, point d'entree, premier message
#    - fin   : titre (custom-title / ai-title) et dernier message
#  Le resultat est mis en cache tant que le fichier ne change pas.
# =================================================================

$script:SessionCache  = @{}
$script:SessionChunk  = 65536   # octets lus en debut et en fin de fichier

function Get-ClaudeProjectsDir {
    $base = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $env:USERPROFILE '.claude' }
    return (Join-Path $base 'projects')
}

function Read-FileLines {
    # Lit $Count octets au debut (-FromEnd:$false) ou a la fin du fichier et
    # renvoie les lignes COMPLETES (la ligne coupee par la limite est ignoree).
    # FileShare ReadWrite : Claude Code peut etre en train d'ecrire le fichier.
    param([string]$Path, [int]$Count, [switch]$FromEnd)
    $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read, ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
    try {
        $len    = $fs.Length
        $offset = if ($FromEnd) { [Math]::Max([long]0, $len - $Count) } else { [long]0 }
        $n      = [int][Math]::Min([long]$Count, $len - $offset)
        $buf    = New-Object byte[] $n
        $read   = 0
        [void]$fs.Seek($offset, [System.IO.SeekOrigin]::Begin)
        while ($read -lt $n) {
            $r = $fs.Read($buf, $read, $n - $read)
            if ($r -le 0) { break }
            $read += $r
        }
    } finally {
        $fs.Dispose()
    }
    $lines = [System.Text.Encoding]::UTF8.GetString($buf, 0, $read) -split "`n"
    if ($FromEnd) {
        if ($offset -gt 0 -and $lines.Count -gt 0) { $lines = @($lines | Select-Object -Skip 1) }
    } else {
        if ($offset + $read -lt $len -and $lines.Count -gt 0) { $lines = @($lines | Select-Object -SkipLast 1) }
    }
    return $lines
}

function Get-TextFromContent {
    # message.content : soit une chaine, soit un tableau de blocs {type,text}
    param($Content)
    if ($null -eq $Content) { return $null }
    if ($Content -is [string]) { return $Content }
    $parts = foreach ($b in @($Content)) { if ($b.type -eq 'text' -and $b.text) { $b.text } }
    return ($parts -join ' ')
}

function Compress-Text {
    # Une seule ligne, espaces normalises, longueur bornee
    param([string]$Text, [int]$Max = 160)
    if (-not $Text) { return $null }
    $t = ($Text -replace '\s+', ' ').Trim()
    if ($t.Length -gt $Max) { $t = $t.Substring(0, $Max - 1) + [char]0x2026 }
    return $t
}

function Read-SessionFile {
    param([System.IO.FileInfo]$File)

    $cwd = $null; $branch = $null; $entry = $null; $first = $null
    foreach ($line in (Read-FileLines -Path $File.FullName -Count $script:SessionChunk)) {
        if (-not $line.Contains('"type":"user"')) { continue }
        try { $d = $line | ConvertFrom-Json } catch { continue }
        if ($d.type -ne 'user') { continue }
        if (-not $cwd -and $d.cwd) {
            $cwd = $d.cwd; $branch = $d.gitBranch; $entry = $d.entrypoint
        }
        if ($d.isMeta -or $d.isSidechain) { continue }
        $t = Get-TextFromContent $d.message.content
        # Les messages commencant par "<" sont des balises techniques
        # (commandes slash, caveats...), pas le vrai premier message.
        if ($t -and $t.Trim() -and -not $t.TrimStart().StartsWith('<')) { $first = $t; break }
    }

    $custom = $null; $ai = $null; $last = $null
    $tail = @(Read-FileLines -Path $File.FullName -Count $script:SessionChunk -FromEnd)
    for ($i = $tail.Count - 1; $i -ge 0; $i--) {
        $line = $tail[$i]
        if (-not $custom -and $line.Contains('"type":"custom-title"')) {
            try { $custom = ($line | ConvertFrom-Json).customTitle } catch {}
        } elseif (-not $ai -and $line.Contains('"type":"ai-title"')) {
            try { $ai = ($line | ConvertFrom-Json).aiTitle } catch {}
        } elseif (-not $last -and $line.Contains('"type":"last-prompt"')) {
            try { $last = ($line | ConvertFrom-Json).lastPrompt } catch {}
        }
        if ($custom -and $ai -and $last) { break }
    }

    $title = $custom
    if (-not $title) { $title = $ai }
    if (-not $title) { $title = $first }
    if (-not $title) { $title = $last }
    if (-not $title) { $title = '(sans titre)' }
    $title   = Compress-Text $title 120
    $last    = Compress-Text $last
    $first   = Compress-Text $first
    $project = if ($cwd) { Split-Path $cwd -Leaf } else { '?' }

    return [PSCustomObject]@{
        Kind         = 'session'
        Id           = $File.BaseName
        Title        = $title
        Display      = $title
        Project      = $project
        Path         = $cwd           # dossier de travail de la session
        Branch       = $branch
        Entrypoint   = $entry
        LastActivity = $File.LastWriteTime
        LastPrompt   = $last
        FirstPrompt  = $first
        File         = $File.FullName
        SearchText   = (@($title, $project, $branch, $last, $first) | Where-Object { $_ }) -join "`n"
    }
}

function Get-ClaudeSessions {
    # Toutes les sessions locales, la plus recente en premier.
    # Les sous-agents (<id>\subagents\*.jsonl) ne sont pas des sessions : on ne
    # lit que les .jsonl directement sous chaque dossier projet.
    param([switch]$HideAutomated)
    $root = Get-ClaudeProjectsDir
    if (-not (Test-Path -LiteralPath $root)) { return @() }

    $newCache = @{}
    $result   = New-Object System.Collections.Generic.List[object]
    foreach ($dir in Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue) {
        foreach ($f in Get-ChildItem -LiteralPath $dir.FullName -Filter '*.jsonl' -File -ErrorAction SilentlyContinue) {
            if ($f.Length -eq 0) { continue }
            $stamp  = "$($f.LastWriteTimeUtc.Ticks)|$($f.Length)"
            $cached = $script:SessionCache[$f.FullName]
            if ($cached -and $cached.Stamp -eq $stamp) {
                $info = $cached.Info
            } else {
                try { $info = Read-SessionFile -File $f } catch { continue }
            }
            $newCache[$f.FullName] = @{ Stamp = $stamp; Info = $info }
            if (-not $info.Path) { continue }   # pas de dossier : impossible a reprendre
            # sdk-cli = sessions lancees par script (claude -p), pas interactives
            if ($HideAutomated -and $info.Entrypoint -eq 'sdk-cli') { continue }
            $result.Add($info)
        }
    }
    $script:SessionCache = $newCache
    return @($result | Sort-Object LastActivity -Descending)
}

function Format-RelativeDate {
    param([datetime]$Date, [datetime]$Now = (Get-Date))
    $d = $Now - $Date
    if ($d.TotalMinutes -lt 1) { return "a l'instant" }
    if ($d.TotalMinutes -lt 60) { return "il y a $([int][Math]::Floor($d.TotalMinutes)) min" }
    if ($d.TotalHours   -lt 24 -and $Date.Date -eq $Now.Date) { return "il y a $([int][Math]::Floor($d.TotalHours)) h" }
    if ($Date.Date -eq $Now.Date.AddDays(-1)) { return "hier" }
    if ($d.TotalDays    -lt 7)  { return "il y a $([int][Math]::Ceiling(($Now.Date - $Date.Date).TotalDays)) j" }
    return $Date.ToString('dd/MM/yyyy')
}
