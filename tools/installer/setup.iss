; infrastruct Windows installer (Inno Setup 6)
; Build via tools/installer/build_installer.ps1 — it stages the payload
; (exported game + three PyInstaller-frozen solver backends + dist sidecar
; config) into .tools/dist-build/stage and compiles this script.
; Per-user install: no admin, no UAC, nothing outside {localappdata}.

#define MyAppName "infrastruct"
#define MyAppVersion "0.8.1"
#define MyAppPublisher "infrastruct project"
#define MyAppExeName "infrastruct.exe"
; the build script passes /DStageDir=... /DOutDir=... pointing at a subst'd
; drive letter — the frozen pandapipes tree nests past MAX_PATH otherwise
#ifndef StageDir
  #define StageDir "..\..\.tools\dist-build\stage"
#endif
#ifndef OutDir
  #define OutDir "..\..\.tools\dist-build"
#endif

[Setup]
AppId={{7C1E9A44-52D3-4B7B-9A5E-1F3A78C4E210}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={localappdata}\Programs\{#MyAppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputDir={#OutDir}
OutputBaseFilename=infrastruct-setup-{#MyAppVersion}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
UninstallDisplayIcon={app}\{#MyAppExeName}

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "german"; MessagesFile: "compiler:Languages\German.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; \
  GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#StageDir}\*"; DestDir: "{app}"; \
  Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; \
  Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; \
  Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; \
  Flags: nowait postinstall skipifsilent

[UninstallRun]
; the game supervises the solver processes; make sure none survive
Filename: "{cmd}"; Parameters: "/c taskkill /IM netzsim-frozen.exe /F & taskkill /IM rtheatflow-frozen.exe /F & taskkill /IM rtwaterflow-frozen.exe /F"; \
  Flags: runhidden skipifdoesntexist; RunOnceId: "KillSidecars"

[UninstallDelete]
Type: filesandordirs; Name: "{app}\orchestration\logs"
