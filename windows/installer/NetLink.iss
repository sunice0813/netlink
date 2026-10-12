; NetLink 的 Windows 安装包。一次装好全部依赖：应用、后台服务、openconnect（含 Wintun 驱动和 vpnc-script）。
; 安装时弹一次 UAC，用来注册以 SYSTEM 运行的后台服务；之后连接、断开 VPN 都不再要管理员权限。
; 用法：ISCC.exe /DAppVersion=1.2.3 /O<输出目录> NetLink.iss（scripts\build.ps1 会先准备好 ..\out 里的文件）

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#define Out "..\out"
#define Service "NetLinkService"

[Setup]
AppId={{6E0B4C1A-3F7D-4E52-9B8C-2D1F5A7E9C40}
AppName=NetLink
AppVersion={#AppVersion}
AppVerName=NetLink {#AppVersion}
AppPublisher=NetLink
AppPublisherURL=https://github.com/sunice0813/netlink
DefaultDirName={autopf}\NetLink
DefaultGroupName=NetLink
DisableProgramGroupPage=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=admin
; Windows 10 1809 起自带 OpenSSH 客户端。
MinVersion=10.0.17763
OutputBaseFilename=NetLink-{#AppVersion}-x64-setup
SetupIconFile=..\src\NetLink.App\Assets\netlink.ico
UninstallDisplayIcon={app}\NetLink.exe
UninstallDisplayName=NetLink
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no
LicenseFile=..\..\LICENSE

[Languages]
Name: "en"; MessagesFile: "compiler:Default.isl"
#if FileExists(AddBackslash(CompilerPath) + "Languages\ChineseSimplified.isl")
Name: "zh"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"
#endif

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#Out}\app\NetLink.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#Out}\service\NetLink.Service.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#Out}\openconnect\*"; DestDir: "{app}\openconnect"; Flags: ignoreversion recursesubdirs
Source: "..\THIRD-PARTY-NOTICES.txt"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\LICENSE"; DestDir: "{app}"; DestName: "LICENSE.txt"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\NetLink"; Filename: "{app}\NetLink.exe"
Name: "{autodesktop}\NetLink"; Filename: "{app}\NetLink.exe"; Tasks: desktopicon

[Registry]
; 卸载时去掉「登录后打开」（应用设置里写的是当前用户的 Run 键）。
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueName: "NetLink"; ValueType: none; Flags: uninsdeletevalue dontcreatekey

[Run]
; 已经有这个服务（升级安装）时 create 会失败，紧接着的 config 会把路径和启动方式改对。
Filename: "{sys}\sc.exe"; Parameters: "create {#Service} binPath= ""{app}\NetLink.Service.exe"" start= auto DisplayName= ""NetLink Service"""; Flags: runhidden waituntilterminated; StatusMsg: "Registering the NetLink service..."
Filename: "{sys}\sc.exe"; Parameters: "config {#Service} binPath= ""{app}\NetLink.Service.exe"" start= auto"; Flags: runhidden waituntilterminated
Filename: "{sys}\sc.exe"; Parameters: "description {#Service} ""Connects the company VPN for NetLink with the bundled openconnect."""; Flags: runhidden waituntilterminated
Filename: "{sys}\sc.exe"; Parameters: "failure {#Service} reset= 86400 actions= restart/5000/restart/5000/restart/30000"; Flags: runhidden waituntilterminated
Filename: "{sys}\sc.exe"; Parameters: "start {#Service}"; Flags: runhidden waituntilterminated; StatusMsg: "Starting the NetLink service..."
Filename: "{app}\NetLink.exe"; Description: "{cm:LaunchProgram,NetLink}"; Flags: nowait postinstall skipifsilent runasoriginaluser

[UninstallRun]
; 先让应用断开隧道和 VPN 后退出，再停掉并删除服务。
Filename: "{app}\NetLink.exe"; Parameters: "--quit"; Flags: runhidden waituntilterminated; RunOnceId: "QuitApp"
Filename: "{sys}\taskkill.exe"; Parameters: "/F /IM NetLink.exe"; Flags: runhidden waituntilterminated; RunOnceId: "KillApp"
Filename: "{sys}\net.exe"; Parameters: "stop {#Service}"; Flags: runhidden waituntilterminated; RunOnceId: "StopService"
Filename: "{sys}\sc.exe"; Parameters: "delete {#Service}"; Flags: runhidden waituntilterminated; RunOnceId: "DeleteService"

[UninstallDelete]
Type: filesandordirs; Name: "{commonappdata}\NetLink"

[Code]
procedure RunHidden(const FileName, Params: String);
var
  ResultCode: Integer;
begin
  Exec(FileName, Params, '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
end;

{ 升级安装前：让正在运行的应用退出、停掉服务，文件才能被替换。 }
function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  if FileExists(ExpandConstant('{app}\NetLink.exe')) then
    RunHidden(ExpandConstant('{app}\NetLink.exe'), '--quit');
  RunHidden(ExpandConstant('{sys}\taskkill.exe'), '/F /IM NetLink.exe');
  RunHidden(ExpandConstant('{sys}\net.exe'), 'stop {#Service}');
  RunHidden(ExpandConstant('{sys}\taskkill.exe'), '/F /IM NetLink.Service.exe');
  Result := '';
end;
