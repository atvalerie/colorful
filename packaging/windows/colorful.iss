#ifndef SourceDir
  #error SourceDir must point to the staged colorful directory
#endif
#ifndef OutputDir
  #define OutputDir "."
#endif
#ifndef AppVersion
  #define AppVersion "0.1.0"
#endif
#ifndef Commit
  #define Commit "unknown"
#endif

[Setup]
AppId={{E85A677C-2A51-4D06-87C6-A2788D50AEF8}
AppName=colorful
AppVersion={#AppVersion}
AppPublisher=valerie.sh
DefaultDirName={localappdata}\Programs\colorful
DefaultGroupName=colorful
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir={#OutputDir}
OutputBaseFilename=colorful-windows-x64-{#AppVersion}-{#Commit}-setup
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
UninstallDisplayIcon={app}\colorful.exe
LicenseFile={#SourceDir}\LICENSE

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\colorful"; Filename: "{app}\colorful.exe"
Name: "{autodesktop}\colorful"; Filename: "{app}\colorful.exe"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Shortcuts:"

[Run]
Filename: "{app}\colorful.exe"; Description: "Launch colorful"; Flags: nowait postinstall skipifsilent
