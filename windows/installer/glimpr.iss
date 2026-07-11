; Glimpr Windows installer (Inno Setup 6). Compiled by CI:
;   ISCC /DMyAppVersion=1.0.0 /DBuildDir=<abs Release dir> /O<out dir> glimpr.iss
#define MyAppName "Glimpr"
#define MyAppPublisher "Howar31"
#define MyAppURL "https://github.com/howar31/glimpr"
#define MyAppExeName "glimpr.exe"
#ifndef MyAppVersion
  #define MyAppVersion "0.0.0"
#endif
#ifndef BuildDir
  #define BuildDir "..\..\build\windows\x64\runner\Release"
#endif

[Setup]
AppId={{FA7E5DB0-A63A-4538-80F4-2E03416E3CFF}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}/issues
AppUpdatesURL={#MyAppURL}/releases
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
LicenseFile=..\..\LICENSE
OutputBaseFilename=Glimpr-Setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
AppMutex=Glimpr_SingleInstance_8F3A
CloseApplications=yes
PrivilegesRequired=admin

[Tasks]
Name: "launchatlogin"; Description: "Launch {#MyAppName} at login"; Flags: unchecked

[Files]
Source: "{#BuildDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\Uninstall {#MyAppName}"; Filename: "{uninstallexe}"

[Registry]
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "Glimpr"; ValueData: """{app}\{#MyAppExeName}"""; Tasks: launchatlogin; Flags: uninsdeletevalue

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "Launch {#MyAppName}"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "taskkill"; Parameters: "/im {#MyAppExeName} /f"; Flags: runhidden; RunOnceId: "KillGlimpr"
