// Included only in FMXInput.Windows test builds; no production API.
procedure TestWindowsMouseInput;
  procedure Check(Condition: Boolean; const Message: string);
  begin if not Condition then raise Exception.Create(Message); end;
  function Find(const Values: TArray<TInputValue>; Kind: TInputElementKind; Code: Integer): Single;
  begin
    for var V in Values do if (V.Kind = Kind) and (V.Code = Code) then Exit(V.Value);
    raise Exception.Create('Missing mouse value');
  end;
begin
  Check(SizeOf(TRawMouse) = 24, 'RAWMOUSE ABI');
  Check(SizeOf(THidCaps) = 64, 'HIDP_CAPS ABI');
  Check(SizeOf(THidButtonCaps) = 72, 'HIDP_BUTTON_CAPS ABI');
  var Backend := TWindowsInputBackend.Create;
  try
    var State := TWindowsState(Backend.FImpl);
    var Mouse := TMouse.Create;
    Mouse.Handle := 1;
    Mouse.Info.Id := 'test:mouse';
    Mouse.Info.Kind := TInputDeviceKind.Mouse;
    Mouse.Info.Available := True;
    for var Code := 0 to 4 do
    begin
      var E: TInputElement;
      E.Kind := TInputElementKind.Button; E.Code := Code;
      Mouse.Info.Elements := Mouse.Info.Elements + [E];
    end;
    for var Code := 0 to 3 do
    begin
      var E: TInputElement;
      E.Kind := TInputElementKind.RelativeAxis; E.Code := Code;
      Mouse.Info.Elements := Mouse.Info.Elements + [E];
    end;
    State.Mice.Add(Mouse);
    var Packet := Default(TRawMousePacket);
    Packet.Header.Device := Mouse.Handle;
    Packet.Mouse.X := 27; Packet.Mouse.Y := -13;
    Packet.Mouse.Buttons := $FF880400 or $40; // -120 vertical wheel and back down
    State.ReadMouse(Packet);
    Packet.Mouse.X := 3; Packet.Mouse.Y := 2; Packet.Mouse.Buttons := 0;
    State.ReadMouse(Packet);
    var Values := Backend.Poll;
    Check(Find(Values, TInputElementKind.RelativeAxis, MouseX) = 30, 'Mouse X sums reports');
    Check(Find(Values, TInputElementKind.RelativeAxis, MouseY) = -11, 'Mouse Y preserves sign');
    Check(Find(Values, TInputElementKind.RelativeAxis, MouseWheel) = -1, 'Signed wheel detents');
    Check(Find(Values, TInputElementKind.Button, MouseBack) = 1, 'Side button down');
    Values := Backend.Poll;
    Check(Find(Values, TInputElementKind.RelativeAxis, MouseX) = 0, 'Relative samples consumed once');
    Check(Find(Values, TInputElementKind.Button, MouseBack) = 1, 'Button state persists across polls');
    Packet.Mouse.Buttons := $80; State.ReadMouse(Packet);
    Values := Backend.Poll;
    Check(Find(Values, TInputElementKind.Button, MouseBack) = 0, 'Side button up');
    Packet.Mouse.Flags := 1; Packet.Mouse.Buttons := $003C0800; // half-detent horizontal wheel
    State.ReadMouse(Packet); Values := Backend.Poll;
    Check(Find(Values, TInputElementKind.RelativeAxis, MouseX) = 0, 'Absolute reports do not become deltas');
    Check(Find(Values, TInputElementKind.RelativeAxis, MouseHorizontalWheel) = 0.5, 'Horizontal high-resolution wheel');
    Packet.Mouse.Flags := 0; Packet.Mouse.X := 0; Packet.Mouse.Y := 0;
    for var Code := 0 to 4 do
    begin
      Packet.Mouse.Buttons := 1 shl (Code * 2); State.ReadMouse(Packet);
      Values := Backend.Poll;
      Check(Find(Values, TInputElementKind.Button, Code) = 1, 'Standard mouse button down');
      Packet.Mouse.Buttons := 2 shl (Code * 2); State.ReadMouse(Packet);
      Values := Backend.Poll;
      Check(Find(Values, TInputElementKind.Button, Code) = 0, 'Standard mouse button up');
    end;
    Packet.Mouse.X := 3;
    Packet.Mouse.Flags := 0; Packet.Mouse.Buttons := 1; State.ReadMouse(Packet);
    Backend.Reset; Values := Backend.Poll;
    Check(Find(Values, TInputElementKind.Button, MouseLeft) = 0, 'Focus reset releases buttons');
    Check(Find(Values, TInputElementKind.RelativeAxis, MouseX) = 0, 'Focus reset discards deltas');
  finally Backend.Free; end;
end;
