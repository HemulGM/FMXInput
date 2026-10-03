program InputTests;

{$APPTYPE CONSOLE}
{$Q+}{$R+}

uses System.SysUtils, System.Classes, FMXInput
  {$IFDEF LINUX}, FMXInput.Linux{$ENDIF}
  {$IFDEF FMXINPUT_TESTS}, FMXInput.Windows{$ENDIF};

type
  TFakeBackend = class(TInputBackend)
    Values: TArray<TInputValue>;
    RefreshCount: Integer;
    procedure Refresh; override;
    function Poll: TArray<TInputValue>; override;
    procedure Reset; override;
    procedure SetDevices(const Devices: TArray<TInputDevice>);
    function Publish(const Snapshot: TArray<TInputValue>): TArray<TInputValue>;
  end;

procedure TFakeBackend.Refresh;
begin Inc(RefreshCount); end;
function TFakeBackend.Poll: TArray<TInputValue>;
begin Result := Copy(Values); end;
procedure TFakeBackend.Reset;
begin Values := nil; end;
procedure TFakeBackend.SetDevices(const Devices: TArray<TInputDevice>);
begin FDevices := Devices; end;
function TFakeBackend.Publish(const Snapshot: TArray<TInputValue>): TArray<TInputValue>;
begin Result := PublishValues(Snapshot); end;

procedure Check(Value: Boolean; const Message: string);
begin if not Value then raise Exception.Create(Message); end;

{$I SysfsReadChecks.inc}
{$I AggregateInputChecks.inc}
{$IFDEF LINUX}
{$I LinuxWindowChecks.inc}
{$ENDIF}

procedure Run;
begin
  Check(ScanCodeToHid($11, False) = 26, 'W physical usage');
  Check(LinuxKeyToHid(17) = 26, 'Linux W physical usage');
  Check(ScanCodeToHid($1C, True) = 88, 'Keypad Enter');
  Check(ScanCodeToHid($1D, False) = 224, 'Left Ctrl');
  Check(ScanCodeToHid($1D, True) = 228, 'Right Ctrl');
  Check(ScanCodeToHid(1000, False) = 0, 'Unknown scan code');
  Check(InputKeyName(26) = 'W', 'Readable physical key name');
  Check(Abs(NormalizeAxis(50, 0, 100)) < 0.001, 'Axis center');
  Check(NormalizeAxis(200, 0, 100) = 1, 'Axis clamp');
  Check(NormalizeAxis(10, 10, 10) = 0, 'Invalid axis range');
  var Backend := TFakeBackend.Create;
  var Manager := TInputManager.Create(Backend);
  try
    var Key := TInputValue.Create('keyboard:one', TInputElementKind.Key, 26, 1);
    var Button := TInputValue.Create('controller:one', TInputElementKind.Button, 3, 1);
    Manager.AddBinding(TInputBinding.Create(1, Key));
    Manager.AddBinding(TInputBinding.Create(1, Button));
    Backend.Values := [Key, Button]; Manager.Poll;
    Check(Manager.IsPressed(1), 'Combined sources');
    var Snapshot := Manager.Values;
    Snapshot[0].Value := 0;
    Check(Manager.Values[0].Value = 1, 'Snapshots must not expose internal arrays');
    Backend.Values := [Button]; Manager.Poll;
    Check(Manager.IsPressed(1), 'Release one source must not release another');
    Backend.Values := nil; Manager.Poll;
    Check(not Manager.IsPressed(1), 'Disconnect clears state');

    Backend.Values := [Key]; Manager.Poll;
    Manager.BeginCapture(2, 'keyboard:one'); Manager.Poll;
    var Binding: TInputBinding;
    Check(not Manager.TakeCaptured(Binding), 'Held key must not be captured');
    Backend.Values := [Button]; Manager.Poll;
    Check(not Manager.TakeCaptured(Binding), 'Capture device filter');
    Backend.Values := [Key]; Manager.Poll;
    Check(Manager.TakeCaptured(Binding) and (Binding.Code = 26) and (Binding.Action = 2), 'Capture after release');
    Check(not Manager.TakeCaptured(Binding), 'Capture delivered once');

    var Axis := TInputValue.Create('controller:one', TInputElementKind.Axis, 0, 0);
    Backend.Values := [Axis]; Manager.Poll;
    Manager.BeginCapture(3); Manager.Poll;
    Check(not Manager.TakeCaptured(Binding), 'Centered axis must not capture');
    Axis.Value := -0.8; Backend.Values := [Axis]; Manager.Poll;
    Check(Manager.TakeCaptured(Binding) and (Binding.Direction = -1), 'Capture negative axis');
    Manager.AddBinding(Binding); Manager.Poll;
    Check(Manager.IsPressed(3), 'Axis above threshold');
    Axis.Value := -0.5; Backend.Values := [Axis]; Manager.Poll;
    Check(Manager.IsPressed(3), 'Axis hysteresis');
    Axis.Value := -0.4; Backend.Values := [Axis]; Manager.Poll;
    Check(not Manager.IsPressed(3), 'Axis release threshold');

    Axis.Value := -1; Backend.Values := [Axis]; Manager.Poll;
    Manager.BeginCapture(4); Manager.Poll;
    Check(not Manager.TakeCaptured(Binding), 'Resting trigger must not capture');
    Axis.Value := 0.8; Backend.Values := [Axis]; Manager.Poll;
    Check(Manager.TakeCaptured(Binding) and (Binding.AxisOrigin = -1) and
      (Binding.Direction = 1), 'Capture trigger travel from its rest position');
    Manager.AddBinding(Binding); Manager.Poll;
    Check(Manager.IsPressed(4), 'Trigger pressed');
    Axis.Value := -1; Backend.Values := [Axis]; Manager.Poll;
    Check(not Manager.IsPressed(4), 'Trigger released');

    var Hat := TInputValue.Create('controller:one', TInputElementKind.Hat, 0, 0);
    Manager.AddBinding(TInputBinding.Create(5, Hat));
    Hat.Value := 1; Backend.Values := [Hat]; Manager.Poll;
    Check(Manager.IsPressed(5), 'Hat diagonal includes up');
    Hat.Value := -1; Backend.Values := [Hat]; Manager.Poll;
    Check(not Manager.IsPressed(5), 'Hat neutral');

    Backend.Values := nil;
    Manager.BeginCapture(20, 'mouse:one');
    var Motion := TInputValue.Create('mouse:one', TInputElementKind.RelativeAxis, MouseX, -10);
    Backend.Values := [Motion]; Manager.Poll;
    Check(not Manager.TakeCaptured(Binding), 'Mouse motion is opt-in during capture');
    var Wheel := TInputValue.Create('mouse:one', TInputElementKind.RelativeAxis, MouseWheel, -0.125);
    Backend.Values := [Wheel]; Manager.Poll;
    Check(Manager.TakeCaptured(Binding) and (Binding.Direction = -1), 'High-resolution negative wheel capture');
    Manager.AddBinding(Binding); Manager.Poll;
    Check(Manager.IsPressed(20), 'Wheel pulse activates action');
    Backend.Values := nil; Manager.Poll;
    Check(not Manager.IsPressed(20), 'Wheel pulse does not stick');
    Manager.RemoveBindings(20);
    Manager.BeginCapture(21, 'mouse:one', True);
    Backend.Values := [Motion]; Manager.Poll;
    Check(Manager.TakeCaptured(Binding) and (Binding.Code = MouseX) and (Binding.Direction = -1), 'Explicit mouse motion capture');

    var Keyboard := Default(TInputDevice);
    Keyboard.Id := 'raw:keyboard:1'; Keyboard.PhysicalId := 'physical:keyboard:1';
    Keyboard.Kind := TInputDeviceKind.Keyboard; Keyboard.Available := True;
    Keyboard.VendorId := 1; Keyboard.ProductId := 2;
    for var Code in [4, 20, 40, 44] do
    begin
      var Element: TInputElement;
      Element.Kind := TInputElementKind.Key; Element.Code := Code;
      Keyboard.Elements := Keyboard.Elements + [Element];
    end;
    var Duplicate := Keyboard; Duplicate.Id := 'raw:keyboard:2';
    var Twin := Keyboard; Twin.Id := 'raw:keyboard:3'; Twin.PhysicalId := 'physical:keyboard:2';
    var VirtualKeyboard := Keyboard; VirtualKeyboard.Id := 'virtual'; VirtualKeyboard.IsVirtual := True;
    var Hotkeys := Keyboard; Hotkeys.Id := 'hotkeys'; Hotkeys.Elements := Copy(Keyboard.Elements, 0, 1);
    var Auxiliary := Keyboard; Auxiliary.Id := 'auxiliary'; Auxiliary.IsAuxiliary := True;
    Backend.SetDevices([Keyboard, Duplicate, Twin, VirtualKeyboard, Hotkeys, Auxiliary]);
    Check(Length(Backend.Devices) = 1, 'All typing keyboards share one abstract source');
    var Grouped := Backend.Publish([
      TInputValue.Create(Keyboard.Id, TInputElementKind.Key, 4, 0),
      TInputValue.Create(Duplicate.Id, TInputElementKind.Key, 4, 1),
      TInputValue.Create(VirtualKeyboard.Id, TInputElementKind.Key, 4, 1)]);
    Check((Length(Grouped) = 1) and (Grouped[0].Value = 1) and
      (Grouped[0].DeviceId = Backend.Devices[0].Id), 'Grouped values match device IDs and OR held states');
    Backend.DeviceListMode := TInputDeviceListMode.AllInterfaces;
    Check(Length(Backend.Devices) = 1, 'Diagnostic mode also combines keyboards');
    Check(Backend.Publish([TInputValue.Create(Keyboard.Id, TInputElementKind.Key, 4, 1)])[0].DeviceId = SystemKeyboardId,
      'Keyboard bindings have stable abstract IDs in every mode');
    Backend.DeviceListMode := TInputDeviceListMode.Gaming;
    var Mouse := Default(TInputDevice);
    Mouse.Id := 'raw:mouse:1'; Mouse.PhysicalId := 'physical:mouse:1';
    Mouse.Kind := TInputDeviceKind.Mouse; Mouse.Available := True;
    for var Code := 0 to 1 do
    begin
      var E: TInputElement;
      E.Kind := TInputElementKind.RelativeAxis; E.Code := Code;
      Mouse.Elements := Mouse.Elements + [E];
    end;
    var Left: TInputElement;
    Left.Kind := TInputElementKind.Button; Left.Code := MouseLeft;
    Mouse.Elements := Mouse.Elements + [Left];
    var MouseInterface := Mouse; MouseInterface.Id := 'raw:mouse:2';
    Backend.SetDevices([Mouse, MouseInterface]);
    Grouped := Backend.Publish([
      TInputValue.Create(Mouse.Id, TInputElementKind.RelativeAxis, MouseX, 2),
      TInputValue.Create(MouseInterface.Id, TInputElementKind.RelativeAxis, MouseX, -5)]);
    Check((Length(Backend.Devices) = 1) and (Length(Grouped) = 1) and
      (Grouped[0].Value = -3), 'Physical mouse interfaces sum relative samples');
    var Controller := Default(TInputDevice);
    Controller.Id := 'virtual:controller'; Controller.Kind := TInputDeviceKind.Controller;
    Controller.IsVirtual := True; Controller.Elements := [Left];
    Backend.SetDevices([Controller]);
    Check(Length(Backend.Devices) = 1, 'Virtual gamepads remain legitimate gaming devices');
    Backend.SetDevices(nil);

    Manager.AddBinding(TInputBinding.Create(22, Wheel));

    var Stream := TMemoryStream.Create;
    try
      Manager.SaveBindings(Stream);
      var Before := Manager.Bindings;
      Manager.ClearBindings; Stream.Position := 0;
      var RefreshCount := Backend.RefreshCount;
      Manager.LoadBindings(Stream);
      Check(Length(Manager.Bindings) = Length(Before), 'Profile round trip');
      Check(Backend.RefreshCount = RefreshCount, 'Profile load must not touch native devices');
      Check(Manager.Bindings[3].AxisOrigin = -1, 'Trigger origin persisted');
      Check((Manager.Bindings[High(Manager.Bindings)].Kind = TInputElementKind.RelativeAxis) and
        (Manager.Bindings[High(Manager.Bindings)].Direction = -1), 'Relative wheel binding persisted');
      Stream.Clear;
      var Bad := TEncoding.UTF8.GetBytes('{"version":1,"bindings":[{"kind":99}]}');
      Stream.WriteBuffer(Bad[0], Length(Bad)); Stream.Position := 0;
      var Failed := False;
      try Manager.LoadBindings(Stream); except on E: Exception do Failed := True; end;
      Check(Failed and (Length(Manager.Bindings) = Length(Before)), 'Invalid profile must not replace bindings');
    finally Stream.Free; end;
    Manager.RemoveBindings(22);

    Backend.Values := [Key]; Manager.Poll; Manager.BeginCapture(6);
    Manager.Enabled := False;
    Check(not Manager.IsPressed(1) and not Manager.Capturing, 'Focus loss clears bindings/capture');
    Backend.Values := [Key]; Manager.Poll;
    Check(not Manager.IsPressed(1), 'Disabled input stays neutral');
    Manager.Enabled := True; Manager.Poll;
    Check(not Manager.IsPressed(1), 'Backend reset clears stale keys');
    Manager.RemoveBindings(1);
    Backend.Values := [Key, Button]; Manager.Poll;
    Check(not Manager.IsPressed(1) and (Length(Manager.Bindings) = 3), 'Remove action bindings');
    Writeln('PASS physical keys, snapshots, multiple sources, capture, axes, triggers, hats, focus and transactional profiles');
  finally Manager.Free; end;
end;

begin
  try
    TestSysfsReads;
    TestAggregateInput;
    {$IFDEF LINUX}
    TestLinuxWindowInput;
    Writeln('PASS Linux window events: physical keys, mouse buttons/motion/wheel, focus and consumption');
    {$ENDIF}
    Writeln('PASS abstract keyboard/mouse, hotplug, independent controllers and physical Mac key positions');
    Writeln('PASS sysfs short reads, nominal size, EOF and UTF-8');
    if ParamCount > 0 then
    begin
      var Stream := TFileStream.Create(ParamStr(1), fmOpenRead or fmShareDenyNone);
      try
        var Text := ReadSysfsText(Stream);
        Check(Text <> '', 'Live sysfs attribute must be readable');
        Writeln('PASS live sysfs attribute: ', ParamStr(1), ' (', Length(Text), ' characters)');
      finally Stream.Free; end;
    end;
    Run;
    {$IFDEF FMXINPUT_TESTS} TestWindowsMouseInput; Writeln('PASS Windows Raw Input mouse packets'); {$ENDIF}
  except on E: Exception do begin Writeln(E.ClassName, ': ', E.Message); Halt(1); end; end;
end.
