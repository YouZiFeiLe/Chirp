#define AppVersion GetVersionNumbersString(ChirpSourceDir + "\Chirp.dll")
#define Scheme "cn.youzifeile.chirp.windows"
#define AppDataPublisher "cn.youzifeile.Chirp"
#define LocalSettingsKey "Software\Classes\Local Settings\Software\" + AppDataPublisher

[Setup]
AppId={#Scheme}
AppName=Chirp
AppVersion={#AppVersion}
AppPublisher=Chirp
VersionInfoVersion={#AppVersion}
PrivilegesRequired=lowest
SetupArchitecture=x64
ArchitecturesAllowed=x64os
ArchitecturesInstallIn64BitMode=x64os
MinVersion=10.0.26100
DefaultDirName={localappdata}\Programs\Chirp
DefaultGroupName=Chirp
DisableDirPage=yes
DisableProgramGroupPage=yes
AppMutex=Local\cn.youzifeile.Chirp.Desktop.Running
RestartApplications=no
ChangesAssociations=yes
SetupIconFile=..\Chirp\Assets\AppIcon.ico
UninstallDisplayName=Chirp
UninstallDisplayIcon={app}\Chirp.exe
OutputBaseFilename=Chirp-Windows-{#AppVersion}-x64-Setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "chinesesimp"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"

[Messages]
english.ConfirmUninstall=Uninstall %1 and delete this PC's Chirp device identities, settings and cache?
chinesesimp.ConfirmUninstall=卸载 %1 并删除此电脑上的 Chirp 设备身份、设置和缓存吗？
english.UninstallAppRunningError=%1 is running. Close its window, then click OK to continue.
chinesesimp.UninstallAppRunningError=%1 正在运行。请关闭 Chirp 窗口，再点“确定”继续卸载。

[Files]
Source: "{#ChirpSourceDir}\*"; DestDir: "{app}"; Excludes: "*.pdb"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{userdesktop}\Chirp"; Filename: "{app}\Chirp.exe"; WorkingDir: "{app}"
Name: "{group}\Chirp"; Filename: "{app}\Chirp.exe"; WorkingDir: "{app}"
Name: "{group}\{cm:UninstallProgram,Chirp}"; Filename: "{uninstallexe}"; Flags: preventpinning

[Registry]
Root: HKCU; Subkey: "Software\Classes\{#Scheme}"; ValueType: string; ValueData: "URL:Chirp"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\{#Scheme}"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\{#Scheme}\DefaultIcon"; ValueType: string; ValueData: """{app}\Chirp.exe"",0"
Root: HKCU; Subkey: "Software\Classes\{#Scheme}\shell\open\command"; ValueType: string; ValueData: """{app}\Chirp.exe"" ""----ms-protocol:%1"""
Root: HKCU; Subkey: "{#LocalSettingsKey}"; Flags: dontcreatekey uninsdeletekeyifempty
Root: HKCU; Subkey: "{#LocalSettingsKey}\Windows"; Flags: dontcreatekey uninsdeletekey
Root: HKCU; Subkey: "Software\Microsoft\Windows\Shell\Associations\UrlAssociations\{#Scheme}"; Flags: dontcreatekey uninsdeletekeyifempty

[UninstallDelete]
Type: filesandordirs; Name: "{localappdata}\{#AppDataPublisher}\Windows"
Type: dirifempty; Name: "{localappdata}\{#AppDataPublisher}"
