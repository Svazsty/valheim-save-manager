Option Explicit
Dim shell, files, folder, target, command, result
Set shell = CreateObject("WScript.Shell")
Set files = CreateObject("Scripting.FileSystemObject")
folder = files.GetParentFolderName(WScript.ScriptFullName)
target = files.BuildPath(folder, "ValheimSaveManager.ps1")
command = "powershell.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File " & Chr(34) & target & Chr(34)
shell.CurrentDirectory = folder
On Error Resume Next
result = shell.Run(command, 0, False)
If Err.Number <> 0 Then MsgBox "Nie mozna uruchomic aplikacji: " & Err.Description, vbCritical, "Valheim Save Manager"
