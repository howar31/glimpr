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
; Dual mode: a fresh install goes to the current account (no elevation);
; "all accounts" is offered by the mode dialog and by /ALLUSERS. An
; existing install keeps its mode (UsePreviousPrivileges, the default), so
; updates never switch scope on their own; the app passes the explicit
; flag anyway (windows/runner/install_scope.h).
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog commandline

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
; The self-update relaunch (Setup launched by the running app with
; /PID=<its pid>) is NOT a [Run] entry: plain [Run] entries execute before
; ssPostInstall, where the other scope's copy is removed, and that copy's
; uninstaller ends any running glimpr.exe. The relaunch lives at the end of
; CurStepChanged(ssPostInstall) in [Code].

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

// --- One scope at a time ----------------------------------------------------
// Both install modes share the AppId, so a machine copy (HKLM) and a
// per-user copy (HKCU) could coexist and drift apart. After this mode's
// files are in place (ssPostInstall), the OTHER mode's copy is uninstalled
// silently, the launch-at-login value (deleted by that uninstall) is
// written again with this mode's path, and only then is the app relaunched
// for a self-update. Order is install-new-then-remove-old-then-relaunch: a
// working copy exists at every moment and the relaunched app is never the
// old uninstaller's taskkill target.

const
  UninstallKey = 'Software\Microsoft\Windows\CurrentVersion\Uninstall\{FA7E5DB0-A63A-4538-80F4-2E03416E3CFF}_is1';
  RunKey = 'Software\Microsoft\Windows\CurrentVersion\Run';
  RunValue = 'Glimpr';

var
  HadLaunchAtLogin: Boolean;

function OtherScopeRoot: Integer;
begin
  if IsAdminInstallMode then
    Result := HKEY_CURRENT_USER
  else
    Result := HKEY_LOCAL_MACHINE;
end;

function OtherScopeUninstaller: String;
var
  Cmd: String;
begin
  Result := '';
  if RegQueryStringValue(OtherScopeRoot, UninstallKey, 'UninstallString', Cmd) then
    Result := RemoveQuotes(Cmd);
end;

function InitializeSetup: Boolean;
begin
  HadLaunchAtLogin := RegValueExists(HKEY_CURRENT_USER, RunKey, RunValue);
  Result := True;
end;

// Runs the other scope's uninstaller and waits. Removing a machine copy
// from an un-elevated per-user Setup needs elevation (one prompt); an
// elevated or administrative Setup removes either copy without a prompt.
function RemoveOtherScope(const Uninstaller: String): Boolean;
var
  Code: Integer;
  Params: String;
begin
  Params := '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART';
  if (not IsAdminInstallMode) and (not IsAdmin) then
    Result := ShellExec('runas', Uninstaller, Params, '', SW_HIDE, ewWaitUntilTerminated, Code)
  else
    Result := Exec(Uninstaller, Params, '', SW_HIDE, ewWaitUntilTerminated, Code);
  Result := Result and (Code = 0);
end;

// Self-update relaunch with the desktop user's own (un-elevated) token.
// Setup itself may be elevated from the start (the app launches it with
// the runas verb whenever a machine scope is involved), and then Inno's
// runasoriginaluser has no un-elevated instance to fall back on; the shell
// always starts its children with the interactive user's token. The app
// takes no arguments, so passing only the path is enough.
procedure RelaunchApp;
var
  Code: Integer;
begin
  ShellExec('', ExpandConstant('{win}\explorer.exe'),
    '"' + ExpandConstant('{app}\{#MyAppExeName}') + '"', '', SW_SHOWNORMAL,
    ewNoWait, Code);
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  Uninstaller: String;
  Exe: String;
begin
  if CurStep <> ssPostInstall then
    Exit;
  Uninstaller := OtherScopeUninstaller;
  if (Uninstaller <> '') and FileExists(Uninstaller) then
  begin
    if not RemoveOtherScope(Uninstaller) then
    begin
      if not WizardSilent then
        MsgBox('The copy of {#MyAppName} installed for the other scope could not be removed. Uninstall it from Apps & features.', mbInformation, MB_OK);
    end;
  end;
  // The other copy's uninstall deletes the shared launch-at-login value;
  // restore it against THIS copy when the user had it on, or ticked the
  // task in this very run (the [Registry] entry wrote it before the
  // removal deleted it again).
  if HadLaunchAtLogin or WizardIsTaskSelected('launchatlogin') then
  begin
    Exe := '"' + ExpandConstant('{app}\{#MyAppExeName}') + '"';
    RegWriteStringValue(HKEY_CURRENT_USER, RunKey, RunValue, Exe);
  end;
  if IsUpdateLaunch then
    RelaunchApp;
end;
