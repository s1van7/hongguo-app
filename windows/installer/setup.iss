#define ExecutableName Slug + ".exe"

[Setup]
AppId={#AppId}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
VersionInfoVersion={#NumericVersion}
AppMutex={#AppId}
DefaultDirName={autopf}\{#AppId}
DisableProgramGroupPage=yes
; 目录固定：升级时沿用上次的安装位置，不再让用户（或 {autopf} 的变化）改到别处
DisableDirPage=yes
UsePreviousAppDir=yes
UsePreviousTasks=yes
; 更新前先把正在运行的旧版本关掉，避免文件被占用后装成半新半旧
CloseApplications=yes
CloseApplicationsFilter=*.exe,*.dll
RestartApplications=no
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#ExecutableName}
UninstallDisplayName={#AppName}
OutputDir={#OutputDir}
OutputBaseFilename={#OutputBaseName}
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern

[Languages]
Name: "chinesesimplified"; MessagesFile: "ChineseSimplified.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Dirs]
Name: "{app}"; Flags: uninsalwaysuninstall

[InstallDelete]
Type: files; Name: "{app}\{#ExecutableName}"
Type: files; Name: "{app}\zhenguojian.exe"

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Excludes: "\{#BundleExecutable}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#SourceDir}\{#BundleExecutable}"; DestDir: "{app}"; DestName: "{#ExecutableName}"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#ExecutableName}"
; 桌面图标改到 [Code] 里「没有才建」，免得每次升级重写快捷方式、图标位置乱跳

[UninstallDelete]
Type: files; Name: "{autodesktop}\{#AppName}.lnk"

[Run]
Filename: "{app}\{#ExecutableName}"; Description: "{cm:LaunchProgram,{#StringChange(AppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent

[Code]
var
  DeleteLocalData: Boolean;

/// 桌面快捷方式只在不存在时创建：重写 .lnk 会让 Windows 忘掉图标位置，
/// 用户每次升级都会发现图标跑到别处去了。
procedure EnsureDesktopShortcut();
var
  LinkPath, Target: String;
  Shell, Shortcut: Variant;
begin
  if not WizardIsTaskSelected('desktopicon') then
    Exit;
  LinkPath := ExpandConstant('{autodesktop}\{#AppName}.lnk');
  if FileExists(LinkPath) then
    Exit;
  Target := ExpandConstant('{app}\{#ExecutableName}');
  try
    Shell := CreateOleObject('WScript.Shell');
    Shortcut := Shell.CreateShortcut(LinkPath);
    Shortcut.TargetPath := Target;
    Shortcut.WorkingDirectory := ExpandConstant('{app}');
    Shortcut.IconLocation := Target + ',0';
    Shortcut.Description := '{#AppName}';
    Shortcut.Save;
  except
    Log('创建桌面快捷方式失败：' + LinkPath);
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then
    EnsureDesktopShortcut();
end;

procedure InitializeUninstallProgressForm();
var
  OptionsPage: TNewNotebookPage;
  Prompt, DataNote: TNewStaticText;
  DataCheckBox: TNewCheckBox;
  UninstallButton: TNewButton;
  PageName, PageDescription: String;
  CancelEnabled: Boolean;
  CancelResult: Integer;
begin
  if UninstallSilent then
    Exit;

  OptionsPage := TNewNotebookPage.Create(UninstallProgressForm);
  OptionsPage.Notebook := UninstallProgressForm.InnerNotebook;
  OptionsPage.Parent := UninstallProgressForm.InnerNotebook;
  OptionsPage.Align := alClient;

  Prompt := TNewStaticText.Create(UninstallProgressForm);
  Prompt.Parent := OptionsPage;
  Prompt.Left := UninstallProgressForm.ProgressBar.Left;
  Prompt.Width := UninstallProgressForm.ProgressBar.Width;
  Prompt.WordWrap := True;
  Prompt.Caption := '默认保留本地数据，重新安装后可继续使用。';

  DataCheckBox := TNewCheckBox.Create(UninstallProgressForm);
  DataCheckBox.Parent := OptionsPage;
  DataCheckBox.Top := Prompt.Top + Prompt.Height + ScaleY(16);
  DataCheckBox.Left := Prompt.Left;
  DataCheckBox.Width := Prompt.Width;
  DataCheckBox.Height := ScaleY(22);
  DataCheckBox.Caption := '同时清除本地数据';

  DataNote := TNewStaticText.Create(UninstallProgressForm);
  DataNote.Parent := OptionsPage;
  DataNote.Left := Prompt.Left + ScaleX(18);
  DataNote.Top := DataCheckBox.Top + DataCheckBox.Height + ScaleY(4);
  DataNote.Width := Prompt.Left + Prompt.Width - DataNote.Left;
  DataNote.WordWrap := True;
  DataNote.Caption := '包括设置、追剧、收藏、缓存和默认目录中的下载，清除后无法恢复。';

  UninstallButton := TNewButton.Create(UninstallProgressForm);
  UninstallButton.Parent := UninstallProgressForm;
  UninstallButton.Width := UninstallProgressForm.CancelButton.Width;
  UninstallButton.Height := UninstallProgressForm.CancelButton.Height;
  UninstallButton.Top := UninstallProgressForm.CancelButton.Top;
  UninstallButton.Left := UninstallProgressForm.CancelButton.Left - UninstallButton.Width - ScaleX(10);
  UninstallButton.Caption := '卸载(&U)';
  UninstallButton.ModalResult := mrOk;
  UninstallButton.Default := True;

  PageName := UninstallProgressForm.PageNameLabel.Caption;
  PageDescription := UninstallProgressForm.PageDescriptionLabel.Caption;
  CancelEnabled := UninstallProgressForm.CancelButton.Enabled;
  CancelResult := UninstallProgressForm.CancelButton.ModalResult;

  UninstallProgressForm.PageNameLabel.Caption := '卸载选项';
  UninstallProgressForm.PageDescriptionLabel.Caption := '选择卸载 {#AppName} 时是否保留本地数据。';
  UninstallProgressForm.InnerNotebook.ActivePage := OptionsPage;
  UninstallProgressForm.CancelButton.Enabled := True;
  UninstallProgressForm.CancelButton.ModalResult := mrCancel;
  UninstallButton.TabOrder := 0;

  if UninstallProgressForm.ShowModal() = mrCancel then
    Abort;

  DeleteLocalData := DataCheckBox.Checked;
  UninstallButton.Visible := False;
  UninstallProgressForm.CancelButton.Enabled := CancelEnabled;
  UninstallProgressForm.CancelButton.ModalResult := CancelResult;
  UninstallProgressForm.PageNameLabel.Caption := PageName;
  UninstallProgressForm.PageDescriptionLabel.Caption := PageDescription;
  UninstallProgressForm.InnerNotebook.ActivePage := UninstallProgressForm.InstallingPage;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep <> usPostUninstall then
    Exit;
  DelTree(ExpandConstant('{localappdata}\{#AppId}'), True, True, True);
  if DeleteLocalData then
    DelTree(ExpandConstant('{userappdata}\{#AppId}'), True, True, True);
end;
