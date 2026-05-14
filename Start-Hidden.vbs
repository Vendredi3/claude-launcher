' Lance ClaudeLauncher.ps1 sans afficher de fenetre console.
' Double-clique sur ce fichier pour demarrer l'app dans la traybar.
Set fso   = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
ps1Path   = scriptDir & "\ClaudeLauncher.ps1"
shell.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & ps1Path & """", 0, False
