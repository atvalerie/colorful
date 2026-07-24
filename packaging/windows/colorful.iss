#ifndef SourceDir
  #error SourceDir must point to the staged colorful directory
#endif
#ifndef OutputDir
  #define OutputDir "."
#endif
#ifndef AppVersion
  #error AppVersion must be supplied from the repository VERSION file
#endif
#ifndef Commit
  #define Commit "unknown"
#endif
#define AppPackedVersion StrToVersion(AppVersion + ".0")

[Setup]
; This identity is permanent. Changing it makes upgrades appear as a second app.
AppId={{E85A677C-2A51-4D06-87C6-A2788D50AEF8}
AppName=colorful
AppVersion={#AppVersion}
AppVerName=colorful {#AppVersion}
AppPublisher=valerie.sh
AppPublisherURL=https://github.com/atvalerie/colorful
AppSupportURL=https://github.com/atvalerie/colorful/issues
AppUpdatesURL=https://github.com/atvalerie/colorful/releases
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
CloseApplications=yes
RestartApplications=no
UsePreviousAppDir=yes
SetupLogging=yes
UninstallDisplayIcon={app}\colorful.exe
UninstallDisplayName=colorful {#AppVersion}
LicenseFile={#SourceDir}\LICENSE
VersionInfoVersion={#AppVersion}.0
VersionInfoProductVersion={#AppVersion}
VersionInfoCompany=valerie.sh
VersionInfoDescription=colorful installer
VersionInfoCopyright=colorful contributors

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\colorful"; Filename: "{app}\colorful.exe"
Name: "{autodesktop}\colorful"; Filename: "{app}\colorful.exe"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Shortcuts:"

[Run]
Filename: "{app}\colorful.exe"; Description: "Launch colorful"; Flags: nowait postinstall skipifsilent

[Code]
function InitializeSetup(): Boolean;
var
  InstallLocation: String;
  InstalledVersion: Int64;
begin
  Result := True;
  if RegQueryStringValue(
       HKCU,
       'Software\Microsoft\Windows\CurrentVersion\Uninstall\{E85A677C-2A51-4D06-87C6-A2788D50AEF8}_is1',
       'InstallLocation',
       InstallLocation) and
     GetPackedVersion(AddBackslash(InstallLocation) + 'colorful.exe', InstalledVersion) and
     (ComparePackedVersion(InstalledVersion, {#AppPackedVersion}) > 0) then
  begin
    MsgBox(
      'A newer version of colorful is already installed. Uninstall it first if you intentionally want to downgrade.',
      mbError,
      MB_OK);
    Result := False;
  end;
end;
