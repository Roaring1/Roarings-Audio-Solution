Option Explicit
Dim sh, fso, appDir, scriptPath, command, rc
Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
appDir = fso.GetParentFolderName(WScript.ScriptFullName)
scriptPath = fso.BuildPath(appDir, "RoaringMic.ps1")
command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & scriptPath & """"
' Keep Task Scheduler attached to the actual tray lifetime, and propagate exit.
rc = sh.Run(command, 0, True)
WScript.Quit rc
