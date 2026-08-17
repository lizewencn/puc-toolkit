Option Explicit

Dim shell, fileSystem, scriptDirectory, launcher, command, quote, extraArguments, waitForExit, exitCode
Set shell = CreateObject("WScript.Shell")
Set fileSystem = CreateObject("Scripting.FileSystemObject")
scriptDirectory = fileSystem.GetParentFolderName(WScript.ScriptFullName)
launcher = scriptDirectory & "\Invoke-PucScript.cmd"
quote = Chr(34)
extraArguments = ""
waitForExit = False
If WScript.Arguments.Count > 0 Then
    If LCase(WScript.Arguments(0)) = "selftest" Then
        extraArguments = " -SelfTest"
        waitForExit = True
    End If
End If
command = "cmd.exe /d /s /c " & quote & quote & launcher & quote & " PucConfigLauncher.ps1" & extraArguments & quote
exitCode = shell.Run(command, 0, waitForExit)
If waitForExit Then WScript.Quit exitCode
