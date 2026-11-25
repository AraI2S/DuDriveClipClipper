' Double-click to start without a console or Windows Terminal window.
Option Explicit
Dim shell, files, folder, powershell, command
Set shell = CreateObject("WScript.Shell")
Set files = CreateObject("Scripting.FileSystemObject")
folder = files.GetParentFolderName(WScript.ScriptFullName)
powershell = shell.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"
command = Chr(34) & powershell & Chr(34) & " -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -File " & Chr(34) & folder & "\Main.ps1" & Chr(34)
shell.Run command, 0, False
