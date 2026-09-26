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
; Self-update (launched by the running app with /PID=<its pid>, see
; windows/runner/update_installer.cpp): relaunch the app once the files are
; in place, with the credentials of the user who started Setup, never the
; elevated ones. A plain [Run] entry (not postinstall) so it runs silently.
Filename: "{app}\{#MyAppExeName}"; Flags: nowait runasoriginaluser; Check: IsUpdateLaunch

[UninstallRun]
Filename: "taskkill"; Parameters: "/im {#MyAppExeName} /f"; Flags: runhidden; RunOnceId: "KillGlimpr"

[Code]
// Self-update handshake. The app launches Setup elevated while it is still
// running (so a declined elevation prompt leaves the app untouched) and
// passes its process id; Setup waits for that process to exit before the
// file-in-use check and the copy. A manual install has no /PID and skips
// all of this.
function OpenProcess(dwDesiredAccess: DWORD; bInheritHandle: BOOL; dwProcessId: DWORD): THandle;
  external 'OpenProcess@kernel32.dll stdcall';
function WaitForSingleObject(hHandle: THandle; dwMilliseconds: DWORD): DWORD;
  external 'WaitForSingleObject@kernel32.dll stdcall';
function CloseHandle(hObject: THandle): BOOL;
  external 'CloseHandle@kernel32.dll stdcall';

function UpdatePid: Integer;
begin
  Result := StrToIntDef(ExpandConstant('{param:PID|0}'), 0);
end;

function IsUpdateLaunch: Boolean;
begin
  Result := UpdatePid <> 0;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  Pid: Integer;
  Handle: THandle;
  Waited: DWORD;
begin
  Result := '';
  Pid := UpdatePid;
  if Pid = 0 then
    Exit;
  // SYNCHRONIZE only; a handle we cannot open means the process is gone.
  Handle := OpenProcess($00100000, False, Pid);
  if Handle = 0 then
    Exit;
  Waited := WaitForSingleObject(Handle, 60000);
  CloseHandle(Handle);
  if Waited <> 0 then
    Result := '{#MyAppName} is still running. Quit it and run the update again.';
end;
