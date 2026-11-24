# =================================================================
#  Claude Launcher - tray application
#  Tape quelques lettres, filtre tes projets (ProjectsRoot),
#  Entree => ouvre PowerShell + claude dans le dossier choisi.
# =================================================================

# ----- Configuration --------------------------------------------
# Toute la conf est dans config.json (a cote du script).
# Si le fichier n'existe pas, il est cree avec les valeurs par defaut.
# ----------------------------------------------------------------

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# ----- Instance unique ------------------------------------------
# Un mutex nomme empeche de lancer deux fois l'app (deux icones dans la traybar).
$script:Mutex = New-Object System.Threading.Mutex($false, "Local\ClaudeLauncher_SingleInstance")
$hasMutex = $false
try {
    $hasMutex = $script:Mutex.WaitOne(0)
} catch [System.Threading.AbandonedMutexException] {
    $hasMutex = $true   # l'instance precedente a plante sans liberer le mutex
}
if (-not $hasMutex) {
    [System.Windows.Forms.MessageBox]::Show(
        "Claude Launcher est deja lance (voir la zone de notification).",
        "Claude Launcher", 'OK', 'Information') | Out-Null
    exit
}

$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$IconPath   = Join-Path $ScriptDir "icon.ico"
$ConfigPath = Join-Path $ScriptDir "config.json"

# Valeurs par defaut (utilisees si config.json absent ou cle manquante)
$DefaultConfig = [ordered]@{
    ProjectsRoot     = "C:\wamp64\www"
    SearchDepth      = 1
    ExcludeFolders   = @(".git", "node_modules", "vendor")   # le dossier du launcher est exclu automatiquement
    ClaudeCommand    = "claude"
    ChromeUrlPattern = "http://127.0.0.1/{name}"
}

function Load-Config {
    # Cree config.json avec les defauts si absent
    if (-not (Test-Path $ConfigPath)) {
        try {
            $DefaultConfig | ConvertTo-Json | Set-Content -Path $ConfigPath -Encoding UTF8
        } catch {
            [System.Windows.Forms.MessageBox]::Show(
                "Impossible de creer config.json :`n$($_.Exception.Message)",
                "Claude Launcher", 'OK', 'Warning') | Out-Null
        }
    }
    # Lit le fichier ; fusionne avec les defauts pour les cles absentes
    $cfg = [ordered]@{}
    foreach ($k in $DefaultConfig.Keys) { $cfg[$k] = $DefaultConfig[$k] }
    if (Test-Path $ConfigPath) {
        try {
            $loaded = Get-Content -Path $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($k in $DefaultConfig.Keys) {
                if ($loaded.PSObject.Properties.Name -contains $k -and $null -ne $loaded.$k) {
                    $cfg[$k] = $loaded.$k
                }
            }
        } catch {
            [System.Windows.Forms.MessageBox]::Show(
                "config.json est invalide, utilisation des valeurs par defaut :`n$($_.Exception.Message)",
                "Claude Launcher", 'OK', 'Warning') | Out-Null
        }
    }
    return $cfg
}

$cfg              = Load-Config
$ProjectsRoot     = ([string]$cfg.ProjectsRoot).TrimEnd('\', '/')
if ($ProjectsRoot -match ':$') { $ProjectsRoot += '\' }   # racine de lecteur : "C:" -> "C:\"
# SearchDepth : au minimum 1 (0 ou negatif ferait planter Get-ChildItem -Depth)
$SearchDepth      = 1
try { $SearchDepth = [Math]::Max(1, [int]$cfg.SearchDepth) } catch { $SearchDepth = 1 }
$ExcludeFolders   = @($cfg.ExcludeFolders)
$ClaudeCommand    = [string]$cfg.ClaudeCommand
$ChromeUrlPattern = [string]$cfg.ChromeUrlPattern

# ===== Tray icon ================================================
$notify = New-Object System.Windows.Forms.NotifyIcon
if (Test-Path $IconPath) {
    $notify.Icon = New-Object System.Drawing.Icon($IconPath)
} else {
    $notify.Icon = [System.Drawing.SystemIcons]::Application
}
$notify.Text    = "Claude Launcher"
$notify.Visible = $true

$menu     = New-Object System.Windows.Forms.ContextMenuStrip
$mOpen    = $menu.Items.Add("Ouvrir le launcher")
$mRoot    = $menu.Items.Add("Ouvrir $ProjectsRoot")
$mLocal   = $menu.Items.Add("Ouvrir http://127.0.0.1 dans Chrome")
$mRefresh = $menu.Items.Add("Rafraichir la liste")
[void]$menu.Items.Add("-")
$mExit    = $menu.Items.Add("Quitter")
$notify.ContextMenuStrip = $menu

# ===== Search form ==============================================
$form = New-Object System.Windows.Forms.Form
$form.Text            = "Claude Launcher"
$form.Size            = New-Object System.Drawing.Size(520, 480)
$form.StartPosition   = "Manual"
$form.FormBorderStyle = "FixedToolWindow"
$form.TopMost         = $true
$form.ShowInTaskbar   = $false
$form.KeyPreview      = $true
$form.BackColor       = [System.Drawing.Color]::FromArgb(245, 245, 245)

$label = New-Object System.Windows.Forms.Label
$label.Text     = "Entree = Claude  -  Ctrl+Entree = Chrome  -  Shift+Entree = Explorateur  -  Echap = fermer"
$label.Location = New-Object System.Drawing.Point(12, 8)
$label.Size     = New-Object System.Drawing.Size(490, 18)
$label.ForeColor = [System.Drawing.Color]::Gray
$form.Controls.Add($label)

$textbox = New-Object System.Windows.Forms.TextBox
$textbox.Location    = New-Object System.Drawing.Point(12, 28)
$textbox.Size        = New-Object System.Drawing.Size(490, 28)
$textbox.Font        = New-Object System.Drawing.Font("Segoe UI", 13)
$textbox.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle   # bordure plate (pas de liseret bleu 3D)
$form.Controls.Add($textbox)

$listbox = New-Object System.Windows.Forms.ListBox
$listbox.Location       = New-Object System.Drawing.Point(12, 62)
$listbox.Size           = New-Object System.Drawing.Size(490, 360)
$listbox.Font           = New-Object System.Drawing.Font("Segoe UI", 11)
$listbox.IntegralHeight = $false
$listbox.BorderStyle    = [System.Windows.Forms.BorderStyle]::FixedSingle
$listbox.DrawMode       = [System.Windows.Forms.DrawMode]::OwnerDrawFixed
$listbox.ItemHeight     = 26    # un peu plus aere
$form.Controls.Add($listbox)

# Couleurs pour le rendu en zebra
$colorRowEven = [System.Drawing.Color]::White
$colorRowOdd  = [System.Drawing.Color]::FromArgb(245, 245, 245)   # gris clair
$colorSelBg   = [System.Drawing.Color]::FromArgb(204, 120, 92)    # coral Claude
$colorSelFg   = [System.Drawing.Color]::White
$colorText    = [System.Drawing.Color]::FromArgb(35, 35, 35)

$listbox.Add_DrawItem({
    param($s, $e)
    if ($e.Index -lt 0) { return }
    $isSelected = ($e.State -band [System.Windows.Forms.DrawItemState]::Selected) -ne 0

    if ($isSelected) {
        $bg = $colorSelBg
        $fg = $colorSelFg
    } elseif ($e.Index % 2 -eq 0) {
        $bg = $colorRowEven
        $fg = $colorText
    } else {
        $bg = $colorRowOdd
        $fg = $colorText
    }

    # Fond
    $brushBg = New-Object System.Drawing.SolidBrush($bg)
    $e.Graphics.FillRectangle($brushBg, $e.Bounds)
    $brushBg.Dispose()

    # Texte avec padding gauche
    $text = [string]$listbox.Items[$e.Index].Display
    $brushFg = New-Object System.Drawing.SolidBrush($fg)
    $textRect = New-Object System.Drawing.RectangleF(
        ([single]($e.Bounds.X + 10)),
        ([single]($e.Bounds.Y + 5)),
        ([single]($e.Bounds.Width - 10)),
        ([single]($e.Bounds.Height))
    )
    $e.Graphics.DrawString($text, $listbox.Font, $brushFg, $textRect)
    $brushFg.Dispose()
})

$status = New-Object System.Windows.Forms.Label
$status.Location  = New-Object System.Drawing.Point(12, 428)
$status.Size      = New-Object System.Drawing.Size(490, 18)
$status.ForeColor = [System.Drawing.Color]::Gray
$form.Controls.Add($status)

# ===== Data & helpers ===========================================
$script:AllFolders = @()

function Refresh-Folders {
    $list = New-Object System.Collections.Generic.List[object]
    if (Test-Path -LiteralPath $ProjectsRoot) {
        $selfDir = $ScriptDir.TrimEnd('\')
        # Parcours manuel : on ne descend PAS dans les dossiers exclus
        # (node_modules, vendor...) et le dossier du launcher est toujours ignore.
        # Le chemin relatif est construit au fil du parcours (pas de Substring :
        # chemin court "UTILIS~1" vs chemin long ne font pas la meme longueur).
        $walk = {
            param([string]$dir, [int]$level, [string]$prefix)
            Get-ChildItem -LiteralPath $dir -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                if ($ExcludeFolders -contains $_.Name) { return }
                # Dossier du launcher : par chemin, ou par la presence du script
                # (couvre le cas chemin court / chemin long)
                if ($_.FullName.TrimEnd('\') -ieq $selfDir -or
                    (Test-Path -LiteralPath (Join-Path $_.FullName 'ClaudeLauncher.ps1'))) { return }
                $rel = if ($prefix) { "$prefix\$($_.Name)" } else { $_.Name }
                $list.Add([PSCustomObject]@{
                    Name    = $_.Name
                    Path    = $_.FullName
                    RelPath = $rel
                    # Avec SearchDepth > 1, on affiche le chemin relatif pour
                    # distinguer les homonymes (deux "src", deux "app"...).
                    Display = $(if ($SearchDepth -gt 1) { $rel } else { $_.Name })
                })
                if ($level -lt $SearchDepth) { & $walk $_.FullName ($level + 1) $rel }
            }
        }
        & $walk $ProjectsRoot 1 ''
    }
    $script:AllFolders = @($list | Sort-Object Display)
}

function Update-List {
    param([string]$Filter)
    $listbox.BeginUpdate()
    try {
        $listbox.Items.Clear()
        $needle = $Filter.Trim()
        if ([string]::IsNullOrEmpty($needle)) {
            $found = $script:AllFolders
        } else {
            # Recherche litterale (pas de -like : "[" ou "*" casseraient le filtre)
            $found = $script:AllFolders | Where-Object {
                $_.Display.IndexOf($needle, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
            }
        }
        foreach ($m in $found) { [void]$listbox.Items.Add($m) }
        if ($listbox.Items.Count -gt 0) { $listbox.SelectedIndex = 0 }
    } finally {
        $listbox.EndUpdate()
    }
    $status.Text = "$($listbox.Items.Count) dossier(s)  /  total: $($script:AllFolders.Count)"
}

function Get-SelectedEntry {
    if ($listbox.SelectedIndex -lt 0) { return $null }
    return $listbox.SelectedItem
}

function Launch-Selected {
    $entry = Get-SelectedEntry
    if (-not $entry) { return }
    $path = $entry.Path

    $wt = Get-Command wt.exe -ErrorAction SilentlyContinue
    if ($wt) {
        # Windows Terminal : ouvre un onglet PowerShell dans le dossier et lance claude.
        # wt interprete ";" comme separateur de commandes : on l'echappe en "\;".
        $cmd = $ClaudeCommand -replace ';', '\;'
        Start-Process -FilePath "wt.exe" -ArgumentList @(
            "-d", "`"$path`"",
            "powershell.exe", "-NoExit", "-Command", $cmd
        )
    } else {
        # Le dossier est passe via -WorkingDirectory : aucun souci d'apostrophe
        # ou de caractere special dans le chemin.
        Start-Process -FilePath "powershell.exe" -WorkingDirectory $path -ArgumentList @(
            "-NoExit", "-Command", $ClaudeCommand
        )
    }
    $form.Hide()
}

function Get-ChromePath {
    # Trouve chrome.exe (Program Files, Program Files (x86), LocalAppData, PATH)
    $candidates = @(
        "${env:ProgramFiles}\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
        "${env:LocalAppData}\Google\Chrome\Application\chrome.exe"
    )
    $exe = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $exe) {
        $cmd = Get-Command chrome.exe -ErrorAction SilentlyContinue
        if ($cmd) { $exe = $cmd.Source }
    }
    return $exe
}

function Start-Chrome {
    param([string]$Url)
    $exe = Get-ChromePath
    try {
        if ($exe) {
            # Si Chrome tourne deja, un nouvel onglet s'ouvre dans la fenetre active
            Start-Process -FilePath $exe -ArgumentList $Url
        } else {
            # Fallback : navigateur par defaut
            Start-Process $Url
        }
    } catch {
        Start-Process $Url
    }
}

function Open-InChrome {
    $entry = Get-SelectedEntry
    if (-not $entry) { return }
    # Pattern issu de config.json : {name} est remplace par le chemin relatif
    # du dossier (segments encodes pour l'URL, separateur "/").
    $urlPath = ($entry.RelPath -split '\\' | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/'
    $url     = $ChromeUrlPattern.Replace('{name}', $urlPath)
    Start-Chrome -Url $url
    $form.Hide()
}

function Open-InExplorer {
    $entry = Get-SelectedEntry
    if (-not $entry) { return }
    Start-Process explorer.exe "`"$($entry.Path)`""
    $form.Hide()
}

function Show-Launcher {
    Refresh-Folders
    $textbox.Text = ""
    Update-List ""
    # Place la fenetre en bas a droite de l'ecran ou se trouve la souris
    # (= celui de la traybar cliquee, utile en multi-ecran)
    $wa = [System.Windows.Forms.Screen]::FromPoint([System.Windows.Forms.Cursor]::Position).WorkingArea
    $form.Location = New-Object System.Drawing.Point(
        ($wa.Right  - $form.Width  - 12),
        ($wa.Bottom - $form.Height - 12)
    )
    $form.Show()
    $form.Activate()
    [void]$textbox.Focus()
}

# ===== Events ===================================================
$textbox.Add_TextChanged({ Update-List $textbox.Text })

# Gestion clavier au niveau du formulaire (KeyPreview=$true plus haut) :
# le formulaire intercepte la touche AVANT que la TextBox/ListBox la voie.
# Comparaison explicite sur l'enum Keys pour eviter toute ambiguite avec
# Enter/Return (qui sont des alias mais .ToString() renvoie "Return").
$form.Add_KeyDown({
    $k    = $_.KeyCode
    $Keys = [System.Windows.Forms.Keys]
    if ($k -eq $Keys::Enter -or $k -eq $Keys::Return) {
        $_.Handled = $true
        $_.SuppressKeyPress = $true
        if ($_.Control) {
            Open-InChrome      # Ctrl+Entree  => Chrome http://127.0.0.1/<dossier>
        } elseif ($_.Shift) {
            Open-InExplorer    # Shift+Entree => Explorateur Windows dans le dossier
        } else {
            Launch-Selected    # Entree       => PowerShell + claude dans le dossier
        }
    }
    elseif ($k -eq $Keys::Escape) {
        $_.Handled = $true
        $_.SuppressKeyPress = $true
        $form.Hide()
    }
    elseif ($k -eq $Keys::Down) {
        # On ne capture les fleches que si le focus est dans la TextBox
        # (sinon on laisse la ListBox gerer sa navigation native).
        if ($textbox.Focused -and $listbox.Items.Count -gt 0 -and
            $listbox.SelectedIndex -lt $listbox.Items.Count - 1) {
            $listbox.SelectedIndex++
            $_.Handled = $true
            $_.SuppressKeyPress = $true
        }
    }
    elseif ($k -eq $Keys::Up) {
        if ($textbox.Focused -and $listbox.SelectedIndex -gt 0) {
            $listbox.SelectedIndex--
            $_.Handled = $true
            $_.SuppressKeyPress = $true
        }
    }
})

$listbox.Add_DoubleClick({ Launch-Selected })

# Clic droit sur un element : le selectionne et copie son chemin complet
$listbox.Add_MouseDown({
    param($s, $e)
    if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Right) { return }
    $idx = $listbox.IndexFromPoint($e.Location)
    if ($idx -lt 0 -or $idx -ge $listbox.Items.Count) { return }
    $listbox.SelectedIndex = $idx
    $entry = $listbox.Items[$idx]
    if (-not $entry) { return }
    try {
        [System.Windows.Forms.Clipboard]::SetText($entry.Path)
        $status.Text = "Chemin copie : $($entry.Path)"
    } catch {
        $status.Text = "Echec de la copie : $($_.Exception.Message)"
    }
})

$form.Add_Deactivate({ $form.Hide() })
$form.Add_FormClosing({
    param($s, $e)
    # Cache au lieu de fermer (sauf si l'app quitte)
    if ($e.CloseReason -eq [System.Windows.Forms.CloseReason]::UserClosing) {
        $e.Cancel = $true
        $form.Hide()
    }
})

$notify.Add_MouseClick({
    param($s, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Show-Launcher }
})

$mOpen.Add_Click({ Show-Launcher })
$mRoot.Add_Click({ Start-Process explorer.exe "`"$ProjectsRoot`"" })
$mLocal.Add_Click({ Start-Chrome -Url "http://127.0.0.1" })
$mRefresh.Add_Click({ Refresh-Folders; $status.Text = "Liste rafraichie ($($script:AllFolders.Count) dossiers)" })
$mExit.Add_Click({
    $notify.Visible = $false
    $notify.Dispose()
    try { $script:Mutex.ReleaseMutex() } catch {}
    [System.Windows.Forms.Application]::Exit()
})

# Chargement initial
Refresh-Folders

# ===== Run ======================================================
[System.Windows.Forms.Application]::Run()
