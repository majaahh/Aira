#ifndef AppVersion
  #define AppVersion "0.1.0"
#endif
#ifndef AppArch
  #define AppArch "x64"
#endif
#ifndef ProjectRoot
  #define ProjectRoot "..\.."
#endif
#ifndef BuildDir
  #define BuildDir ProjectRoot + "\build\windows\x64\runner\Release"
#endif
#ifndef OutputDir
  #define OutputDir ProjectRoot + "\dist"
#endif
#ifndef OutputBaseFilename
  #define OutputBaseFilename "Aira-v" + AppVersion + "-windows-" + AppArch + "-setup"
#endif
#ifndef SetupIcon
  #define SetupIcon ProjectRoot + "\windows\runner\resources\app_icon.ico"
#endif

[Setup]
AppId={{D37E84B1-026B-4D88-82CE-7BD969EAE59B}
AppName=Aira
AppVersion={#AppVersion}
AppPublisher=Maja Błaszczak
AppPublisherURL=https://github.com/majaahh/aira
AppSupportURL=https://github.com/majaahh/aira/issues
AppUpdatesURL=https://github.com/majaahh/aira/releases
DefaultDirName={autopf}\Aira
DefaultGroupName=Aira
AllowNoIcons=yes
OutputDir={#OutputDir}
OutputBaseFilename={#OutputBaseFilename}
SetupIconFile={#SetupIcon}
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog commandline
ArchitecturesAllowed={#AppArch == "arm64" ? "arm64" : "x64compatible"}
ArchitecturesInstallIn64BitMode={#AppArch == "arm64" ? "arm64" : "x64compatible"}
CloseApplications=force
RestartApplications=yes
UninstallDisplayIcon={app}\aira.exe

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked
Name: "autostart"; Description: "Start Aira in system tray on Windows login"; GroupDescription: "Startup Options:"; Flags: unchecked

[Files]
Source: "{#BuildDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Aira"; Filename: "{app}\aira.exe"
Name: "{autodesktop}\Aira"; Filename: "{app}\aira.exe"; Tasks: desktopicon
Name: "{userstartup}\Aira"; Filename: "{app}\aira.exe"; Parameters: "--tray"; Tasks: autostart

[Run]
Filename: "{app}\aira.exe"; Description: "{cm:LaunchProgram,Aira}"; Flags: nowait postinstall skipifsilent
