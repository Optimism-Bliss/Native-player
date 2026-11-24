; Inno Setup script for TorBox STRM (Windows x64).
; Built by CI: iscc /DAppVersion=<x.y.z> /DSourceDir=<Release folder> /DOutputDir=<dist> installer.iss
; Per-user install (no administrator rights), like most media apps.

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif

[Setup]
AppId={{6B1B2F6E-6C1E-4B7A-9F3F-3C2B5D8E4A17}
AppName=TorBox STRM
AppVersion={#AppVersion}
AppPublisher=Optimism-Bliss
AppPublisherURL=https://github.com/Optimism-Bliss/Native-player
DefaultDirName={localappdata}\Programs\TorBox STRM
DefaultGroupName=TorBox STRM
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir={#OutputDir}
OutputBaseFilename=TorBox-STRM-windows-x64-setup
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
CloseApplications=force
RestartApplications=no
UninstallDisplayIcon={app}\TorBoxSTRM.exe
LicenseFile=..\..\LICENSE

[Languages]
Name: "en"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\TorBox STRM"; Filename: "{app}\TorBoxSTRM.exe"
Name: "{autodesktop}\TorBox STRM"; Filename: "{app}\TorBoxSTRM.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\TorBoxSTRM.exe"; Description: "{cm:LaunchProgram,TorBox STRM}"; Flags: nowait postinstall
