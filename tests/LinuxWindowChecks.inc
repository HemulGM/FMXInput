procedure TestLinuxWindowInput;
type
  TX11Event = record
    EventType: Integer;
    Serial: NativeUInt;
    SendEvent: Integer;
    Display: Pointer;
    Window, Root, Subwindow, Time: NativeUInt;
    X, Y, RootX, RootY: Integer;
    State, Detail: Cardinal;
    SameScreen: Integer;
  end;
  TXIEvent = record
    EventType: Integer;
    Serial: NativeUInt;
    SendEvent: Integer;
    Display: Pointer;
    Extension, EventSubtype: Integer;
    Time: NativeUInt;
    DeviceId, SourceId, Detail: Integer;
    Root, Window, Child: NativeUInt;
    RootX, RootY, X, Y: Double;
    Flags: Integer;
  end;
  function ValueOf(const Values: TArray<TInputValue>; const Id: string; Kind: TInputElementKind; Code: Integer): Single;
  begin
    for var V in Values do
      if (V.DeviceId = Id) and (V.Kind = Kind) and (V.Code = Code) then Exit(V.Value);
    raise Exception.Create('Missing window input value');
  end;
begin
  var Backend := TLinuxInputBackend.Create;
  try
    Backend.SetWindowInputPresence(True, True);
    Check(Length(Backend.Devices) >= 2, 'Host seat announces keyboard and pointer');
    var Event := Default(TX11Event);
    Check(SizeOf(Event) = 96, 'XKeyEvent/XButtonEvent Linux64 ABI');
    Event.EventType := 2; Event.Detail := 25; // Xorg W position = evdev 17 + 8.
    Backend.ProcessX11Event(@Event);
    Backend.MouseButtonEvent(MouseBack, True);
    Event.EventType := 6; Event.Window := 1; Event.RootX := 100; Event.RootY := 200;
    Backend.ProcessX11Event(@Event);
    Event.RootX := 112; Event.RootY := 197; Backend.ProcessX11Event(@Event);
    Event.EventType := 4; Event.Detail := 5; Backend.ProcessX11Event(@Event);
    Event.Detail := 7; Backend.ProcessX11Event(@Event);
    var Values := Backend.Poll;
    Check(ValueOf(Values, SystemKeyboardId, TInputElementKind.Key, 26) = 1, 'Layout independent W');
    Check(ValueOf(Values, SystemMouseId, TInputElementKind.Button, MouseBack) = 1, 'Mouse side button');
    Check(ValueOf(Values, SystemMouseId, TInputElementKind.RelativeAxis, MouseX) = 12, 'Window movement X');
    Check(ValueOf(Values, SystemMouseId, TInputElementKind.RelativeAxis, MouseY) = -3, 'Window movement Y');
    Check(ValueOf(Values, SystemMouseId, TInputElementKind.RelativeAxis, MouseWheel) = -1, 'Wheel down');
    Check(ValueOf(Values, SystemMouseId, TInputElementKind.RelativeAxis, MouseHorizontalWheel) = 1, 'Wheel right');
    Values := Backend.Poll;
    Check(ValueOf(Values, SystemMouseId, TInputElementKind.RelativeAxis, MouseX) = 0, 'Deltas consumed once');
    Event.EventType := 3; Event.Detail := 25; Backend.ProcessX11Event(@Event);
    Check(ValueOf(Backend.Poll, SystemKeyboardId, TInputElementKind.Key, 26) = 0, 'Key release');
    Backend.KeyEvent(17, True); Backend.MouseMotionEvent(2, 3);
    Event.EventType := 10; Backend.ProcessX11Event(@Event);
    Values := Backend.Poll;
    Check(ValueOf(Values, SystemKeyboardId, TInputElementKind.Key, 26) = 0, 'Focus loss releases keys');
    Check(ValueOf(Values, SystemMouseId, TInputElementKind.Button, MouseBack) = 0, 'Focus loss releases buttons');
    Check(ValueOf(Values, SystemMouseId, TInputElementKind.RelativeAxis, MouseY) = 0, 'Focus loss drops motion');
    var XI := Default(TXIEvent);
    Check(SizeOf(XI) = 128, 'XInput2 device event prefix ABI');
    XI.EventSubtype := 2; XI.Detail := 25; Backend.ProcessXInput2Event(@XI);
    Check(ValueOf(Backend.Poll, SystemKeyboardId, TInputElementKind.Key, 26) = 1, 'XInput2 physical key press');
    XI.EventSubtype := 6; XI.Window := 2; XI.RootX := 10.5; XI.RootY := 20;
    Backend.ProcessXInput2Event(@XI);
    XI.RootX := 11; XI.RootY := 19.75; Backend.ProcessXInput2Event(@XI);
    Values := Backend.Poll;
    Check(ValueOf(Values, SystemMouseId, TInputElementKind.RelativeAxis, MouseX) = 0.5, 'XInput2 fractional movement');
    Check(ValueOf(Values, SystemMouseId, TInputElementKind.RelativeAxis, MouseY) = -0.25, 'XInput2 signed fractional movement');
    XI.EventSubtype := 10; Backend.ProcessXInput2Event(@XI);
    Check(ValueOf(Backend.Poll, SystemKeyboardId, TInputElementKind.Key, 26) = 0, 'XInput2 focus loss');
    Backend.SetWindowInputPresence(False, False);
    for var Device in Backend.Devices do Check(Device.Kind = TInputDeviceKind.Controller, 'Absent seat has no desktop sources');
  finally Backend.Free; end;
end;
