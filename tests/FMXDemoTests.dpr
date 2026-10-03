program FMXDemoTests;

{$APPTYPE CONSOLE}
{$Q+}{$R+}

uses
  System.SysUtils, FMX.Forms, FMX.Graphics, FMX.Grid, FMXInput,
  InputDemo.Main in '..\examples\FMXDemo\InputDemo.Main.pas';

type
  TFakeBackend = class(TInputBackend)
    Values: TArray<TInputValue>;
    constructor Create;
    procedure DisconnectSelected;
    procedure DisconnectAll;
    procedure Refresh; override;
    function Poll: TArray<TInputValue>; override;
    procedure Reset; override;
  end;

  TTestForm = class(TInputDemoForm)
  protected
    function CreateBackend: TInputBackend; override;
  end;

var Backend: TFakeBackend;

constructor TFakeBackend.Create;
const TypingCodes: array[0..3] of Integer = (4, 20, 40, 44);
begin
  inherited;
  SetLength(FDevices, 4);
  for var I := 0 to 1 do
  begin
    FDevices[I].Id := 'keyboard:' + IntToStr(I + 1);
    FDevices[I].Name := 'Test keyboard ' + IntToStr(I + 1);
    FDevices[I].Kind := TInputDeviceKind.Keyboard;
    FDevices[I].Available := True;
    SetLength(FDevices[I].Elements, 5);
    FDevices[I].Elements[0].Kind := TInputElementKind.Key;
    FDevices[I].Elements[0].Code := 26;
    FDevices[I].Elements[0].Name := 'W';
    for var J := 0 to 3 do
    begin
      FDevices[I].Elements[J + 1].Kind := TInputElementKind.Key;
      FDevices[I].Elements[J + 1].Code := TypingCodes[J];
      FDevices[I].Elements[J + 1].Name := InputKeyName(TypingCodes[J]);
    end;
  end;
  FDevices[2].Id := 'controller:1';
  FDevices[2].Name := 'Test gamepad';
  FDevices[2].Kind := TInputDeviceKind.Controller;
  FDevices[2].Available := True;
  SetLength(FDevices[2].Elements, 3);
  FDevices[2].Elements[0].Kind := TInputElementKind.Button;
  FDevices[2].Elements[0].Name := 'Button 0';
  FDevices[2].Elements[1].Kind := TInputElementKind.Axis;
  FDevices[2].Elements[1].Name := 'Axis X';
  FDevices[2].Elements[2].Kind := TInputElementKind.Hat;
  FDevices[2].Elements[2].Name := 'D-pad';
  FDevices[3].Id := 'mouse:1'; FDevices[3].Name := 'Test mouse';
  FDevices[3].Kind := TInputDeviceKind.Mouse; FDevices[3].Available := True;
  for var Code := 0 to 4 do
  begin
    var E: TInputElement;
    E.Kind := TInputElementKind.Button; E.Code := Code;
    E.Name := MouseElementName(E.Kind, Code);
    FDevices[3].Elements := FDevices[3].Elements + [E];
  end;
  for var Code := 0 to 3 do
  begin
    var E: TInputElement;
    E.Kind := TInputElementKind.RelativeAxis; E.Code := Code;
    E.Name := MouseElementName(E.Kind, Code);
    FDevices[3].Elements := FDevices[3].Elements + [E];
  end;
end;

procedure TFakeBackend.DisconnectSelected;
begin FDevices := [FDevices[1]]; Values := nil; end;
procedure TFakeBackend.DisconnectAll;
begin FDevices := nil; Values := nil; end;
procedure TFakeBackend.Refresh;
begin end;
function TFakeBackend.Poll: TArray<TInputValue>;
begin
  Result := PublishValues(Values);
  for var I := 0 to High(Values) do
    if Values[I].Kind = TInputElementKind.RelativeAxis then Values[I].Value := 0;
end;
procedure TFakeBackend.Reset;
begin Values := nil; end;
function TTestForm.CreateBackend: TInputBackend;
begin Backend := TFakeBackend.Create; Result := Backend; end;

procedure Check(Value: Boolean; const Message: string);
begin if not Value then raise Exception.Create(Message); end;

procedure Run;
begin
  Application.Initialize;
  var Form := TTestForm.Create(nil);
  try
    Form.PollTimer.Enabled := False;
    Form.Show;
    Application.ProcessMessages;
    Check(Form.DeviceCombo.Items.Count = 3, 'One keyboard, one mouse and one gamepad');
    Check(Form.ValuesGrid.ColumnCount = 4, 'Grid columns must be loaded from FMX');
    Check(Form.ValuesGrid.RowCount = 5, 'Selected device controls');
    Backend.Values := [TInputValue.Create('controller:1', TInputElementKind.Button, 0, 1)];
    Form.PollTimerTimer(nil);
    Check(Form.EventsMemo.Lines.Count = 0, 'Gamepad must not produce keyboard events');
    Check(Form.ValuesGrid.Cells[3, 0] = 'Released', 'Gamepad must not change keyboard grid');
    Form.CaptureButtonClick(nil);
    Form.PollTimerTimer(nil);
    Check(Form.CancelButton.Enabled, 'Gamepad must not complete keyboard capture');
    Backend.Values := [TInputValue.Create('keyboard:2', TInputElementKind.Key, 26, 1)];
    Form.PollTimerTimer(nil);
    Form.PollTimerTimer(nil);
    Check(Form.ValuesGrid.Cells[3, 0] = 'Pressed', 'Second physical keyboard feeds abstract keyboard');
    Check(Form.CaptureLabel.Text = 'Captured: W', 'Abstract keyboard capture');
    Check(Form.BindingStateLabel.Text = 'Captured action: PRESSED', 'Captured action state');
    Check(Pos('CAPTURED W', Form.EventsMemo.Text) > 0, 'Capture event');
    if ParamCount > 0 then
    begin
      Application.ProcessMessages;
      var Bitmap := Form.RootLayout.MakeScreenshot;
      try Bitmap.SaveToFile(ParamStr(1)); finally Bitmap.Free; end;
    end;
    Backend.Values := nil;
    Form.PollTimerTimer(nil);
    Check(Form.ValuesGrid.Cells[3, 0] = 'Released', 'Sparse snapshot releases key');
    Check(Form.BindingStateLabel.Text = 'Captured action: released', 'Action release');
    Backend.Values := [TInputValue.Create('keyboard:1', TInputElementKind.Key, 26, 1)];
    Form.PollTimerTimer(nil);
    Form.FormDeactivate(nil);
    Check(Form.ValuesGrid.Cells[3, 0] = 'Released', 'Focus loss clears grid');
    Check(not Form.CaptureButton.Enabled, 'Inactive capture must be disabled');
    Form.FormActivate(nil);
    Form.DeviceCombo.ItemIndex := 1;
    Check(Form.BindingStateLabel.Text = 'Captured action: not assigned', 'Switch clears binding');
    Form.DeviceCombo.ItemIndex := 2;
    Backend.Values := [TInputValue.Create('controller:1', TInputElementKind.Axis, 0, 0)];
    Form.PollTimerTimer(nil);
    Form.CaptureButtonClick(nil);
    Backend.Values := [TInputValue.Create('controller:1', TInputElementKind.Axis, 0, -0.8),
      TInputValue.Create('controller:1', TInputElementKind.Button, 0, 1),
      TInputValue.Create('controller:1', TInputElementKind.Hat, 0, 2)];
    Form.PollTimerTimer(nil);
    Form.PollTimerTimer(nil);
    Check(Form.ValuesGrid.Cells[3, 0] = 'Pressed', 'Gamepad button display');
    Check(Form.ValuesGrid.Cells[3, 2] = 'Right', 'Gamepad hat display');
    Check(Form.CaptureLabel.Text = 'Captured: Axis X (negative)', 'Gamepad axis capture');
    Check(Form.BindingStateLabel.Text = 'Captured action: PRESSED', 'Gamepad action');
    Backend.Values := nil;
    Form.PollTimerTimer(nil);
    Form.CaptureButtonClick(nil);
    Backend.Values := [TInputValue.Create('controller:1', TInputElementKind.Button, 0, 1)];
    Form.PollTimerTimer(nil);
    Check(Form.CaptureLabel.Text = 'Captured: Button 0', 'Gamepad button capture');
    Form.CaptureButtonClick(nil);
    Form.CancelButtonClick(nil);
    Check(not Form.CancelButton.Enabled, 'Cancel stops capture');
    Form.DeviceCombo.ItemIndex := 1;
    Check(Pos('Mouse', Form.DeviceCombo.Items[1]) > 0, 'Abstract mouse in selector');
    Backend.Values := nil;
    Form.PollTimerTimer(nil);
    Form.CaptureButtonClick(nil);
    Backend.Values := [TInputValue.Create('mouse:1', TInputElementKind.RelativeAxis, MouseX, 12)];
    Form.PollTimerTimer(nil);
    Check(Form.CancelButton.Enabled, 'Pointer movement must not steal button capture');
    Check(Form.ValuesGrid.Cells[3, 5] = '12', 'Relative motion display');
    Form.PollTimerTimer(nil);
    Check(Form.ValuesGrid.Cells[3, 5] = '0', 'Motion is consumed once');
    Backend.Values := [TInputValue.Create('mouse:1', TInputElementKind.Button, MouseBack, 1)];
    Form.PollTimerTimer(nil);
    Check(Form.CaptureLabel.Text = 'Captured: Back button', 'Mouse side button capture');
    Backend.Values := nil; Form.PollTimerTimer(nil);
    Form.CaptureButtonClick(nil);
    Backend.Values := [TInputValue.Create('mouse:1', TInputElementKind.RelativeAxis, MouseWheel, -0.125)];
    Form.PollTimerTimer(nil);
    Check(Form.CaptureLabel.Text = 'Captured: Wheel (negative)', 'Mouse wheel capture');
    Check(Form.BindingStateLabel.Text = 'Captured action: PRESSED', 'Wheel impulse visible in capture frame');
    Form.PollTimerTimer(nil);
    Check(Form.BindingStateLabel.Text = 'Captured action: released', 'Wheel does not stick in UI');
    Form.CaptureMotionCheck.IsChecked := True;
    Form.CaptureButtonClick(nil);
    Backend.Values := [TInputValue.Create('mouse:1', TInputElementKind.RelativeAxis, MouseY, 5)];
    Form.PollTimerTimer(nil);
    Check(Form.CaptureLabel.Text = 'Captured: Mouse Y (positive)', 'Motion capture opt-in');
    Form.DeviceCombo.ItemIndex := 0;
    Backend.DisconnectSelected;
    Form.RefreshButtonClick(nil);
    Check(Form.DeviceCombo.ItemIndex = 0, 'Removing one physical keyboard preserves aggregate selection');
    Backend.DisconnectAll;
    Form.RefreshButtonClick(nil);
    Form.PollTimer.Enabled := False;
    Check(Form.DeviceCombo.ItemIndex = -1, 'Disconnect must not switch device');
    Check(Form.ValuesGrid.RowCount = 0, 'Disconnect clears controls');
    Check(not Form.CaptureButton.Enabled, 'No device cannot capture');
  finally Form.Free; end;
end;

procedure NativeSmoke;
begin
  Application.Initialize;
  var Form := TInputDemoForm.Create(nil);
  try
    Form.Show;
    Application.ProcessMessages;
    Form.PollTimer.Enabled := False;
    Form.PollTimerTimer(nil);
    Check(Pos('Input stopped:', Form.DeviceStatusLabel.Text) <> 1, 'Native poll failed');
    Writeln('Native devices: ', Form.DeviceCombo.Items.Count);
    Writeln('Selected: ', Form.DeviceIdLabel.Text);
    Writeln(Form.DeviceStatusLabel.Text);
    if ParamCount > 1 then
    begin
      var Bitmap := Form.RootLayout.MakeScreenshot;
      try Bitmap.SaveToFile(ParamStr(2)); finally Bitmap.Free; end;
    end;
  finally Form.Free; end;
end;

begin
  try
    if ParamStr(1) = '--native' then NativeSmoke else Run;
    Writeln('PASS: FMX demo');
  except
    on E: Exception do begin Writeln(E.ClassName + ': ' + E.Message); ExitCode := 1; end;
  end;
end.
