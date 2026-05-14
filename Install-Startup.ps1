# Cree un raccourci dans le dossier Demarrage de Windows
# pour lancer Claude Launcher automatiquement a l'ouverture de session.
#
# Utilisation : clic droit sur ce fichier -> "Executer avec PowerShell"

$ErrorActionPreference = "Stop"

$ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$VbsPath     = Join-Path $ScriptDir "Start-Hidden.vbs"
$IconPath    = Join-Path $ScriptDir "icon.ico"
$StartupDir  = [System.Environment]::GetFolderPath('Startup')
$Shortcut    = Join-Path $StartupDir "Claude Launcher.lnk"

if (-not (Test-Path $VbsPath)) {
    Write-Host "Introuvable : $VbsPath" -ForegroundColor Red
    exit 1
}

$wsh = New-Object -ComObject WScript.Shell
$lnk = $wsh.CreateShortcut($Shortcut)
$lnk.TargetPath       = $VbsPath
$lnk.WorkingDirectory = $ScriptDir
if (Test-Path $IconPath) { $lnk.IconLocation = $IconPath }
$lnk.Description      = "Claude Launcher (traybar)"
$lnk.Save()

Write-Host ""
Write-Host "Raccourci cree dans :" -ForegroundColor Green
Write-Host "  $Shortcut"
Write-Host ""
Write-Host "Claude Launcher demarrera automatiquement a la prochaine ouverture de session."
Write-Host "Pour le lancer maintenant, double-clique sur Start-Hidden.vbs"
Write-Host ""
Read-Host "Appuie sur Entree pour fermer"
