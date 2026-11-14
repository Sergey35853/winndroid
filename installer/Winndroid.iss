#define MyAppName "Winndroid"
#ifndef MyAppVersion
  #define MyAppVersion "0.1.1"
#endif
#define MyAppPublisher "Sergey35853"
#define MyAppURL "https://github.com/Sergey35853/winndroid"
#define MyAppExeName "Winndroid.cmd"

[Setup]
AppId={{7B255843-360F-4186-9FF3-5EC09BCE31F6}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}/issues
AppUpdatesURL={#MyAppURL}/releases
DefaultDirName={autopf}\Winndroid
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
LicenseFile=..\LICENSE
OutputDir=..\dist
OutputBaseFilename=Winndroid-Setup-{#MyAppVersion}
SetupIconFile=..\assets\winndroid.ico
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=lowest
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayIcon={app}\assets\winndroid.ico
MinVersion=10.0.19041

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional icons:"
Name: "downloadadb"; Description: "Download Android platform-tools (adb)"; GroupDescription: "Components:"; Flags: checkedonce

[Files]
Source: "..\Winndroid.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\Winndroid.cmd"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\README.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\LICENSE"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\config.example.json"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\assets\winndroid.ico"; DestDir: "{app}\assets"; Flags: ignoreversion
Source: "..\docs\screenshot-manager.png"; DestDir: "{app}\docs"; Flags: ignoreversion
Source: "Setup-ADB.ps1"; DestDir: "{app}\installer"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; IconFilename: "{app}\assets\winndroid.ico"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; IconFilename: "{app}\assets\winndroid.ico"; Tasks: desktopicon

[Run]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\installer\Setup-ADB.ps1"""; StatusMsg: "Downloading Android platform-tools..."; Flags: runhidden waituntilterminated; Tasks: downloadadb
Filename: "{app}\{#MyAppExeName}"; Description: "Launch {#MyAppName}"; Flags: nowait postinstall skipifsilent

[Code]
function InitializeSetup(): Boolean;
var
  ResultCode: Integer;
begin
  Result := True;
  if not Exec('pwsh.exe', '-NoProfile -Command "exit 0"', '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then
  begin
    if MsgBox('PowerShell 7 was not found.' + #13#10 + #13#10 +
              'Winndroid needs PowerShell 7. Install it from https://aka.ms/powershell, then run Winndroid again.' + #13#10 + #13#10 +
              'Continue the installation anyway?', mbConfirmation, MB_YESNO) = IDNO then
      Result := False;
  end;
end;
