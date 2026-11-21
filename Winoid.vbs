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
    WScript.Quit 1
End If

' Quote for the Windows command line (CommandLineToArgvW rules):
' - a literal backslash is doubled, so a trailing backslash does not escape
'   the closing quote of the argument;
' - a literal quote is written as backslash + quote;
' - the argument is wrapped in quotes.
Function Quote(value)
    value = CStr(value)
    Dim esc, i, c, bs, q
    bs = Chr(92)
    q = Chr(34)
    esc = ""
    For i = 1 To Len(value)
        c = Mid(value, i, 1)
        If c = q Then
            esc = esc & bs & q
        Else
            If c = bs Then
                esc = esc & bs & bs
            Else
                esc = esc & c
            End If
        End If
    Next
    Quote = q & esc & q
End Function
