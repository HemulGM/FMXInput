program InputTests;

{$APPTYPE CONSOLE}
{$Q+}{$R+}

uses System.SysUtils, System.Classes, FMXInput;

type
  TFakeBackend = class(TInputBackend)
    Values: TArray<TInputValue>;
    RefreshCount: Integer;
    procedure Refresh; override;
    function Poll: TArray<TInputValue>; override;
    procedure Reset; override;
  end;

procedure TFakeBackend.Refresh;
begin Inc(RefreshCount); end;
function TFakeBackend.Poll: TArray<TInputValue>;
begin Result := Copy(Values); end;
procedure TFakeBackend.Reset;
begin Values := nil; end;

procedure Check(Value: Boolean; const Message: string);
begin if not Value then raise Exception.Create(Message); end;

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
      Stream.Clear;
      var Bad := TEncoding.UTF8.GetBytes('{"version":1,"bindings":[{"kind":99}]}');
      Stream.WriteBuffer(Bad[0], Length(Bad)); Stream.Position := 0;
      var Failed := False;
      try Manager.LoadBindings(Stream); except on E: Exception do Failed := True; end;
      Check(Failed and (Length(Manager.Bindings) = Length(Before)), 'Invalid profile must not replace bindings');
    finally Stream.Free; end;

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
  try Run;
  except on E: Exception do begin Writeln(E.ClassName, ': ', E.Message); Halt(1); end; end;
end.
