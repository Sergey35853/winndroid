Option Explicit

Dim fso, sh, baseDir, app, cmd, i
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("WScript.Shell")

baseDir = fso.GetParentFolderName(WScript.ScriptFullName)
app = fso.BuildPath(baseDir, "Winoid.ps1")
If Not fso.FileExists(app) Then
    MsgBox "Winoid.ps1 was not found next to this launcher.", vbExclamation, "Winoid"
    WScript.Quit 1
End If

sh.CurrentDirectory = baseDir
cmd = "pwsh.exe -NoProfile -Sta -ExecutionPolicy Bypass -WindowStyle Hidden -File " & Quote(app)
For i = 0 To WScript.Arguments.Count - 1
    cmd = cmd & " " & Quote(WScript.Arguments(i))
Next

On Error Resume Next
sh.Run cmd, 0, False
If Err.Number <> 0 Then
    MsgBox "PowerShell 7 (pwsh.exe) was not found. Install it from https://aka.ms/powershell.", vbExclamation, "Winoid"
End If

Function Quote(value)
    Quote = """" & Replace(value, """", """""") & """"
End Function
