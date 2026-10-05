unit FMXInput.Linux;

interface

uses
  FMXInput;

{$IF Defined(LINUX) and not Defined(ANDROID)}
type
  TLinuxInputBackend = class(TInputBackend)
  private
    FImpl: TObject;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Refresh; override;
    function Poll: TArray<TInputValue>; override;
    procedure Reset; override;
    // For hosts with their own X11/Wayland event loop. Codes are evdev key codes,
    // mouse buttons are FMXInput codes, deltas use right/down and up/right.
    procedure KeyEvent(Code: Word; Pressed: Boolean);
    procedure MouseButtonEvent(Code: Integer; Pressed: Boolean);
    procedure MouseMotionEvent(X, Y: Single);
    procedure MouseWheelEvent(Vertical, Horizontal: Single);
    procedure SetWindowInputPresence(Keyboard, Mouse: Boolean);
    procedure ProcessX11Event(Event: Pointer);
    procedure ProcessXInput2Event(Event: Pointer);
  end;
{$ENDIF}

implementation

{$IF Defined(LINUX) and not Defined(ANDROID)}

uses
  System.SysUtils, System.Classes, System.IOUtils, System.Generics.Collections,
  Posix.Errno, Posix.Dlfcn;

function EvOpen(Path: MarshaledAString; Flags: Integer): Integer; cdecl; external 'libc.so.6' name 'open';

function EvClose(Fd: Integer): Integer; cdecl; external 'libc.so.6' name 'close';

function EvIoctl(Fd: Integer; Request: NativeUInt; Data: Pointer): Integer; cdecl; external 'libc.so.6' name 'ioctl';

function RealPath(Path, Resolved: MarshaledAString): Pointer; cdecl; external 'libc.so.6' name 'realpath';

type
  TX11InputEvent = record
    EventType: Integer;
    Serial: NativeUInt;
    SendEvent: Integer;
    Display: Pointer;
    Window, Root, Subwindow, Time: NativeUInt;
    X, Y, RootX, RootY: Integer;
    State, Detail: Cardinal;
    SameScreen: Integer;
  end;

  PX11InputEvent = ^TX11InputEvent;

  TXGenericCookie = record
    EventType: Integer;
    Serial: NativeUInt;
    SendEvent: Integer;
    Display: Pointer;
    Extension, EventSubtype: Integer;
    Cookie: Cardinal;
    Data: Pointer;
  end;

  PXGenericCookie = ^TXGenericCookie;
  // Prefix shared by XIDeviceEvent and XIEnter/Leave/Focus events (Linux64).

  TXInput2Event = record
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

  PXInput2Event = ^TXInput2Event;

  TGdkFilter = function(XEvent, GdkEvent, Data: Pointer): Integer; cdecl;

  TGdkFilterProc = procedure(Window: Pointer; Filter: TGdkFilter; Data: Pointer); cdecl;

  TGdkGetDisplay = function: Pointer; cdecl;

  TGdkGetSeat = function(Display: Pointer): Pointer; cdecl;

  TGdkCapabilities = function(Seat: Pointer): Cardinal; cdecl;

  TTypeName = function(Instance: Pointer): MarshaledAString; cdecl;

  TXQueryExtension = function(Display: Pointer; Name: MarshaledAString; out Opcode, FirstEvent, FirstError: Integer): Integer; cdecl;

  TAbsInfo = record
    Value, Minimum, Maximum, Fuzz, Flat, Resolution: Integer;
  end;

  TLinuxDevice = class
    Fd: Integer;
    Path: string;
    Info: TInputDevice;
    constructor Create;
    destructor Destroy; override;
  end;

  TLinuxState = class
    Devices: TObjectList<TLinuxDevice>;
    Backend: TLinuxInputBackend;
    HasKeyboard, HasMouse, WindowInputReady, HavePointer: Boolean;
    PresenceOverride: Boolean;
    Keys: array[0..255] of Boolean;
    Buttons: array[0..31] of Boolean;
    Delta: array[0..3] of Single;
    LastX, LastY: Double;
    LastWindow: NativeUInt;
    XInputOpcode: Integer;
    Gdk: NativeUInt;
    RemoveFilter: TGdkFilterProc;
    GetDisplay: TGdkGetDisplay;
    GetSeat: TGdkGetSeat;
    SeatCapabilities: TGdkCapabilities;
    procedure InstallWindowInput;
    procedure ResetDesktop;
    function DesktopDevices: TArray<TInputDevice>;
    constructor Create;
    destructor Destroy; override;
  end;

function ReadRequest(Number, Size: Cardinal): NativeUInt;
begin
  Result := NativeUInt($80000000) or (NativeUInt(Size) shl 16) or ($45 shl 8) or Number;
end;

function WindowFilter(XEvent, GdkEvent, Data: Pointer): Integer; cdecl;
begin
  Result := 0; // GDK_FILTER_CONTINUE: never consume FMX/GTK's event.
  try
    TLinuxState(Data).Backend.ProcessX11Event(XEvent);
  except
  end;
end;

procedure TLinuxState.InstallWindowInput;
begin
  if Gdk <> 0 then
    Exit;
  // Integrate only with an already loaded host toolkit; do not initialize GTK.
  Gdk := dlopen('libgdk-3.so.0', RTLD_LAZY or $4); // Linux RTLD_NOLOAD
  if Gdk = 0 then
    Exit;
  GetDisplay := TGdkGetDisplay(dlsym(Gdk, 'gdk_display_get_default'));
  GetSeat := TGdkGetSeat(dlsym(Gdk, 'gdk_display_get_default_seat'));
  SeatCapabilities := TGdkCapabilities(dlsym(Gdk, 'gdk_seat_get_capabilities'));
  var TypeName: TTypeName := TTypeName(dlsym(Gdk, 'g_type_name_from_instance'));
  var AddFilter: TGdkFilterProc := TGdkFilterProc(dlsym(Gdk, 'gdk_window_add_filter'));
  RemoveFilter := TGdkFilterProc(dlsym(Gdk, 'gdk_window_remove_filter'));
  if Assigned(GetDisplay) and Assigned(TypeName) and Assigned(AddFilter) and Assigned(RemoveFilter) then
  begin
    var Display := GetDisplay();
    if (Display <> nil) and (UTF8ToString(TypeName(Display)) = 'GdkX11Display') then
    begin
      var NativeDisplay: TGdkGetSeat := TGdkGetSeat(dlsym(Gdk, 'gdk_x11_display_get_xdisplay'));
      var QueryExtension: TXQueryExtension := TXQueryExtension(dlsym(Gdk, 'XQueryExtension'));
      if Assigned(NativeDisplay) and Assigned(QueryExtension) then
      begin
        var FirstEvent, FirstError: Integer;
        QueryExtension(NativeDisplay(Display), 'XInputExtension', XInputOpcode, FirstEvent, FirstError);
      end;
      AddFilter(nil, WindowFilter, Self);
      WindowInputReady := True;
      Exit;
    end;
  end;
  dlclose(Gdk);
  Gdk := 0;
  RemoveFilter := nil;
  GetDisplay := nil;
  GetSeat := nil;
  SeatCapabilities := nil;
end;

procedure TLinuxState.ResetDesktop;
begin
  FillChar(Keys, SizeOf(Keys), 0);
  FillChar(Buttons, SizeOf(Buttons), 0);
  FillChar(Delta, SizeOf(Delta), 0);
  HavePointer := False;
end;

function TLinuxState.DesktopDevices: TArray<TInputDevice>;
begin
  Result := nil;
  if HasKeyboard then
    Result := Result + [DesktopInputDevice(TInputDeviceKind.Keyboard)];
  if HasMouse then
    Result := Result + [DesktopInputDevice(TInputDeviceKind.Mouse)];
  if not WindowInputReady then
    for var I := 0 to High(Result) do
    begin
      Result[I].Available := False;
      Result[I].Error := 'No window input adapter: use GTK3/X11 or forward native window events to the Linux backend';
    end;
end;

function BitSet(const Bits: TBytes; Code: Integer): Boolean;
begin
  Result := (Code >= 0) and (Code div 8 < Length(Bits)) and
    ((Bits[Code div 8] and (1 shl (Code mod 8))) <> 0);
end;

// sysfs reports a nominal file size, not the length of the generated attribute.
// Do not use Stream.Size, Seek or ReadBuffer here. Short reads are valid.
function ReadSysfsText(Stream: TStream): string;
const
  MaxAttributeBytes = 65536;
var
  Chunk: array[0..4095] of Byte;
begin
  var Data := TMemoryStream.Create;
  try
    while True do
    begin
      var Count := Stream.Read(Chunk, SizeOf(Chunk));
      if Count < 0 then
        raise EReadError.Create('Cannot read sysfs attribute');
      if Count = 0 then
        Break;
      if Data.Size + Count > MaxAttributeBytes then
        raise EReadError.Create('Sysfs attribute exceeds the read limit');
      Data.WriteBuffer(Chunk, Count);
    end;
    var Bytes: TBytes;
    SetLength(Bytes, Data.Size);
    if Length(Bytes) > 0 then
      Move(Data.Memory^, Bytes[0], Length(Bytes));
    Result := TEncoding.UTF8.GetString(Bytes).Trim;
  finally
    Data.Free;
  end;
end;

function SysText(const Path: string): string;
begin
  Result := '';
  try
    var Stream := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
    try
      Result := ReadSysfsText(Stream);
    finally
      Stream.Free;
    end;
  except
    on E: EInOutError do
      Result := '';
    on E: EFOpenError do
      Result := '';
    on E: EReadError do
      Result := '';
  end;
end;

function SysBits(const Path: string; Size: Integer): TBytes;
begin
  SetLength(Result, Size);
  var Parts := SysText(Path).Split([' '], TStringSplitOptions.ExcludeEmpty);
  for var I := 0 to High(Parts) do
  begin
    var Bits: UInt64;
    if not TryStrToUInt64('$' + Parts[High(Parts) - I], Bits) then
      Continue;
    for var J := 0 to 7 do
      if I * 8 + J < Size then
        Result[I * 8 + J] := Byte((Bits shr (J * 8)) and $FF);
  end;
end;

constructor TLinuxDevice.Create;
begin
  inherited;
  Fd := -1;
end;

destructor TLinuxDevice.Destroy;
begin
  if Fd >= 0 then
    EvClose(Fd);
  inherited;
end;

constructor TLinuxState.Create;
begin
  inherited;
  Devices := TObjectList<TLinuxDevice>.Create;
end;

destructor TLinuxState.Destroy;
begin
  if Gdk <> 0 then
  begin
    if Assigned(RemoveFilter) then
      RemoveFilter(nil, WindowFilter, Self);
    dlclose(Gdk);
  end;
  Devices.Free;
  inherited;
end;

constructor TLinuxInputBackend.Create;
begin
  inherited;
  FImpl := TLinuxState.Create;
  TLinuxState(FImpl).Backend := Self;
  TLinuxState(FImpl).InstallWindowInput;
end;

destructor TLinuxInputBackend.Destroy;
begin
  FImpl.Free;
  inherited;
end;

procedure TLinuxInputBackend.Refresh;
begin
  var State := TLinuxState(FImpl);
  State.InstallWindowInput;
  if not State.PresenceOverride then
  begin
    State.HasKeyboard := False;
    State.HasMouse := False;
  end;
  var Paths: TArray<string>;
  if TDirectory.Exists('/sys/class/input') then
    Paths := TDirectory.GetDirectories('/sys/class/input', 'event*');
  for var I := State.Devices.Count - 1 downto 0 do
  begin
    var Found := False;
    for var Path in Paths do
      if '/dev/input/' + TPath.GetFileName(Path) = State.Devices[I].Path then
        Found := True;
    if not Found then
      State.Devices.Delete(I);
  end;
  for var Path in Paths do
  begin
    var NativePath := '/dev/input/' + TPath.GetFileName(Path);
    var Keys := SysBits(Path + '/device/capabilities/key', 96);
    var Axes := SysBits(Path + '/device/capabilities/abs', 8);
    var Relative := SysBits(Path + '/device/capabilities/rel', 2);
    var IsMouse := BitSet(Keys, $110) and BitSet(Relative, 0) and BitSet(Relative, 1);
    var IsKeyboard := BitSet(Keys, 30) and BitSet(Keys, 16); // A and Q positions
    var IsController := False;
    for var Code := $120 to $13F do
      if BitSet(Keys, Code) then
        IsController := True;
    // Wheel shifters and button boxes need not have joystick/gamepad buttons.
    IsController := IsController or BitSet(Keys, $150) or BitSet(Keys, $151);
    for var Code := $2C0 to $2E7 do
      IsController := IsController or BitSet(Keys, Code);
    // Pedals/throttles may expose only absolute gaming axes. Exclude tablet,
    // touch and accelerometer interfaces instead of inventing a gamepad for them.
    var Properties := SysBits(Path + '/device/properties', 1);
    if not IsMouse and not IsKeyboard and not BitSet(Properties, 6) and
      not BitSet(Keys, $140) and not BitSet(Keys, $145) and not BitSet(Keys, $14A) then
      for var Axis := 0 to 10 do
        IsController := IsController or BitSet(Axes, Axis);
    // Keyboard/mouse presence is metadata only. Never open their evdev nodes.
    if not State.PresenceOverride then
    begin
      State.HasKeyboard := State.HasKeyboard or IsKeyboard;
      State.HasMouse := State.HasMouse or IsMouse;
    end;
    if not IsController then
      Continue;
    var Device: TLinuxDevice := nil;
    for var Existing in State.Devices do
      if Existing.Path = NativePath then
        Device := Existing;
    if Device = nil then
    begin
      Device := TLinuxDevice.Create;
      Device.Path := NativePath;
      Device.Info.Name := SysText(Path + '/device/name');
      Device.Info.Serial := SysText(Path + '/device/uniq');
      Device.Info.VendorId := Word(StrToIntDef('$' + SysText(Path + '/device/id/vendor'), 0));
      Device.Info.ProductId := Word(StrToIntDef('$' + SysText(Path + '/device/id/product'), 0));
      var Identity := Device.Info.Serial;
      if Identity = '' then
        Identity := SysText(Path + '/device/phys');
      if Identity = '' then
        Identity := NativePath;
      Device.Info.Id := 'linux:evdev:' + IntToHex(Device.Info.VendorId, 4) + ':' +
        IntToHex(Device.Info.ProductId, 4) + ':' + Identity;
      var Resolved: array[0..4095] of AnsiChar;
      var EncodedPath := UTF8String(Path + '/device');
      var Physical := '';
      if RealPath(MarshaledAString(EncodedPath), @Resolved[0]) <> nil then
      begin
        Physical := UTF8ToString(PAnsiChar(@Resolved[0]));
        Device.Info.IsVirtual := Physical.Contains('/devices/virtual/');
        // Strip the input/inputN child: sibling HID interfaces share a parent.
        var InputIndex := Pos('/input/input', Physical);
        if InputIndex > 0 then
          Physical := Copy(Physical, 1, InputIndex - 1);
        // HID instance suffix/interface differs; use the USB device parent when present.
        var HidIndex := Pos('/0003:', Physical);
        if HidIndex > 0 then
        begin
          Physical := Copy(Physical, 1, HidIndex - 1);
          var LastSlash := LastDelimiter('/', Physical);
          var Leaf := Copy(Physical, LastSlash + 1, MaxInt);
          if Leaf.Contains(':') then
            Physical := Copy(Physical, 1, LastSlash - 1);
        end;
      end;
      if Physical <> '' then
        Device.Info.PhysicalId := 'linux:physical:' + Physical;
      Device.Info.Kind := TInputDeviceKind.Controller;
      for var Existing in State.Devices do
        if Existing.Info.Id = Device.Info.Id then
          Device.Info.Id := Device.Info.Id + ':' + NativePath;
      for var Code := 0 to 767 do
        if BitSet(Keys, Code) then
        begin
          var Element: TInputElement;
          if Code < 256 then
          begin
            Element.Kind := TInputElementKind.Key;
            Element.Code := LinuxKeyToHid(Code);
            if Element.Code = 0 then
              Continue;
            Element.Name := InputKeyName(Element.Code);
          end
          else
          begin
            Element.Kind := TInputElementKind.Button;
            Element.Code := Code;
            Element.Name := 'Button ' + IntToStr(Code);
          end;
          Device.Info.Elements := Device.Info.Elements + [Element];
        end;
      for var Code := 0 to 63 do
        if BitSet(Axes, Code) then
        begin
          var Element: TInputElement;
          Element.Kind := TInputElementKind.Axis;
          Element.Code := Code;
          Element.Name := 'Axis ' + IntToStr(Code);
          // evdev represents the D-pad as two independent signed axes.
          if (Code >= 16) and (Code <= 23) then
            Element.Name := 'D-pad axis ' + IntToStr(Code - 16);
          Device.Info.Elements := Device.Info.Elements + [Element];
        end;
      State.Devices.Add(Device);
    end;
    if Device.Fd < 0 then
    begin
      var Encoded := UTF8String(NativePath);
      Device.Fd := EvOpen(MarshaledAString(Encoded), $800 or $80000); // RDONLY | NONBLOCK | CLOEXEC
      if Device.Fd < 0 then
      begin
        var ErrorCode := errno;
        Device.Info.Error := Format('Cannot open %s (%d: %s); check session/device permissions',
          [NativePath, ErrorCode, SysErrorMessage(ErrorCode)]);
      end;
    end;
    Device.Info.Available := Device.Fd >= 0;
    if Device.Info.Available then
      Device.Info.Error := '';
  end;
  if not State.PresenceOverride and Assigned(State.GetDisplay) and Assigned(State.GetSeat) and Assigned(State.SeatCapabilities) then
  begin
    var Display := State.GetDisplay();
    if Display <> nil then
    begin
      var Seat := State.GetSeat(Display);
      if Seat <> nil then
      begin
        var Caps := State.SeatCapabilities(Seat);
        State.HasKeyboard := (Caps and 8) <> 0;
        State.HasMouse := (Caps and 1) <> 0;
      end;
    end;
  end;
  if not State.HasKeyboard then
    FillChar(State.Keys, SizeOf(State.Keys), 0);
  if not State.HasMouse then
  begin
    FillChar(State.Buttons, SizeOf(State.Buttons), 0);
    FillChar(State.Delta, SizeOf(State.Delta), 0);
    State.HavePointer := False;
  end;
  FDevices := State.DesktopDevices;
  for var Device in State.Devices do
    FDevices := FDevices + [Device.Info];
end;

function TLinuxInputBackend.Poll: TArray<TInputValue>;
begin
  var Values := TList<TInputValue>.Create;
  try
    var State := TLinuxState(FImpl);
    FDevices := State.DesktopDevices;
    for var Device in FDevices do
      if Device.Available then
        for var Element in Device.Elements do
        begin
          var Value: Single := 0;
          case Element.Kind of
            TInputElementKind.Key:
              if State.Keys[Element.Code] then
                Value := 1;
            TInputElementKind.Button:
              if State.Buttons[Element.Code] then
                Value := 1;
            TInputElementKind.RelativeAxis:
              Value := State.Delta[Element.Code];
          end;
          Values.Add(TInputValue.Create(Device.Id, Element.Kind, Element.Code, Value));
        end;
    FillChar(State.Delta, SizeOf(State.Delta), 0);
    for var Device in TLinuxState(FImpl).Devices do
    begin
      if Device.Fd >= 0 then
      begin
        var Keys: TBytes;
        SetLength(Keys, 96);
        if EvIoctl(Device.Fd, ReadRequest($18, Length(Keys)), @Keys[0]) < 0 then
        begin
          Device.Info.Available := False;
          Device.Info.Error := 'evdev state read failed; device will be reopened on refresh';
          EvClose(Device.Fd);
          Device.Fd := -1;
        end
        else
        begin
          Device.Info.Available := True;
          Device.Info.Error := '';
          var HidDown: array[0..255] of Boolean;
          FillChar(HidDown, SizeOf(HidDown), 0);
          for var Code := 1 to 255 do
          begin
            var Hid := LinuxKeyToHid(Code);
            if (Hid <> 0) and BitSet(Keys, Code) then
              HidDown[Hid] := True;
          end;
          // Query the authoritative current state. This does not depend on the
          // event queue, so SYN_DROPPED cannot leave stuck buttons behind.
          for var Element in Device.Info.Elements do
          begin
            var Value: Single := 0;
            case Element.Kind of
              TInputElementKind.Key:
                begin
                  if HidDown[Element.Code] then
                    Value := 1;
                end;
              TInputElementKind.Button:
                if BitSet(Keys, Element.Code) then
                  Value := 1;
              TInputElementKind.Axis:
                begin
                  var Info: TAbsInfo;
                  if EvIoctl(Device.Fd, ReadRequest($40 + Element.Code, SizeOf(Info)), @Info) < 0 then
                    Continue;
                  Value := NormalizeAxis(Info.Value, Info.Minimum, Info.Maximum);
                end;
            end;
            Values.Add(TInputValue.Create(Device.Info.Id, Element.Kind, Element.Code, Value));
          end;
        end;
      end;
      FDevices := FDevices + [Device.Info];
    end;
    Result := PublishValues(Values.ToArray);
  finally
    Values.Free;
  end;
end;

procedure TLinuxInputBackend.SetWindowInputPresence(Keyboard, Mouse: Boolean);
begin
  var State := TLinuxState(FImpl);
  State.PresenceOverride := True;
  State.HasKeyboard := Keyboard;
  State.HasMouse := Mouse;
  State.WindowInputReady := True;
  State.ResetDesktop;
  Refresh;
end;

procedure TLinuxInputBackend.KeyEvent(Code: Word; Pressed: Boolean);
begin
  var Hid := LinuxKeyToHid(Code);
  if Hid <> 0 then
    TLinuxState(FImpl).Keys[Hid] := Pressed;
end;

procedure TLinuxInputBackend.MouseButtonEvent(Code: Integer; Pressed: Boolean);
begin
  if (Code >= 0) and (Code <= High(TLinuxState(FImpl).Buttons)) then
    TLinuxState(FImpl).Buttons[Code] := Pressed;
end;

procedure TLinuxInputBackend.MouseMotionEvent(X, Y: Single);
begin
  var State := TLinuxState(FImpl);
  State.Delta[MouseX] := State.Delta[MouseX] + X;
  State.Delta[MouseY] := State.Delta[MouseY] + Y;
end;

procedure TLinuxInputBackend.MouseWheelEvent(Vertical, Horizontal: Single);
begin
  var State := TLinuxState(FImpl);
  State.Delta[MouseWheel] := State.Delta[MouseWheel] + Vertical;
  State.Delta[MouseHorizontalWheel] := State.Delta[MouseHorizontalWheel] + Horizontal;
end;

procedure TLinuxInputBackend.ProcessX11Event(Event: Pointer);
begin
  if Event = nil then
    Exit;
  var Native := PX11InputEvent(Event);
  var State := TLinuxState(FImpl);
  case Native.EventType of
    35: // GDK has already obtained the cookie; do not own/free its data.
      begin
        var Cookie := PXGenericCookie(Event);
        if (State.XInputOpcode <> 0) and (Cookie.Extension = State.XInputOpcode) and (Cookie.Data <> nil) then
          ProcessXInput2Event(Cookie.Data);
      end;
    2, 3: // KeyPress / KeyRelease: standard Xorg/XWayland evdev keycode offset.
      if (Native.Detail >= 8) and (Native.Detail < 256) then
        KeyEvent(Native.Detail - 8, Native.EventType = 2);
    4, 5: // ButtonPress / ButtonRelease; wheel buttons produce pulses on press.
      case Native.Detail of
        1:
          MouseButtonEvent(MouseLeft, Native.EventType = 4);
        2:
          MouseButtonEvent(MouseMiddle, Native.EventType = 4);
        3:
          MouseButtonEvent(MouseRight, Native.EventType = 4);
        4:
          if Native.EventType = 4 then
            MouseWheelEvent(1, 0);
        5:
          if Native.EventType = 4 then
            MouseWheelEvent(-1, 0);
        6:
          if Native.EventType = 4 then
            MouseWheelEvent(0, -1);
        7:
          if Native.EventType = 4 then
            MouseWheelEvent(0, 1);
        8..36:
          MouseButtonEvent(Native.Detail - 5, Native.EventType = 4);
      end;
    6: // MotionNotify: window events, not global raw monitoring.
      begin
        if State.HavePointer and (State.LastWindow = Native.Window) then
          MouseMotionEvent(Native.RootX - State.LastX, Native.RootY - State.LastY);
        State.LastX := Native.RootX;
        State.LastY := Native.RootY;
        State.LastWindow := Native.Window;
        State.HavePointer := True;
      end;
    8:
      State.HavePointer := False; // LeaveNotify: don't bridge unrelated windows.
      10:
      State.ResetDesktop; // FocusOut
  end;
end;

procedure TLinuxInputBackend.ProcessXInput2Event(Event: Pointer);
begin
  if Event = nil then
    Exit;
  var Native := PXInput2Event(Event);
  var State := TLinuxState(FImpl);
  case Native.EventSubtype of
    2, 3:
      if (Native.Detail >= 8) and (Native.Detail < 256) then
        KeyEvent(Native.Detail - 8, Native.EventSubtype = 2);
    4, 5:
      case Native.Detail of
        1:
          MouseButtonEvent(MouseLeft, Native.EventSubtype = 4);
        2:
          MouseButtonEvent(MouseMiddle, Native.EventSubtype = 4);
        3:
          MouseButtonEvent(MouseRight, Native.EventSubtype = 4);
        4:
          if Native.EventSubtype = 4 then
            MouseWheelEvent(1, 0);
        5:
          if Native.EventSubtype = 4 then
            MouseWheelEvent(-1, 0);
        6:
          if Native.EventSubtype = 4 then
            MouseWheelEvent(0, -1);
        7:
          if Native.EventSubtype = 4 then
            MouseWheelEvent(0, 1);
        8..36:
          MouseButtonEvent(Native.Detail - 5, Native.EventSubtype = 4);
      end;
    6:
      begin
        if State.HavePointer and (State.LastWindow = Native.Window) then
          MouseMotionEvent(Native.RootX - State.LastX, Native.RootY - State.LastY);
        State.LastX := Native.RootX;
        State.LastY := Native.RootY;
        State.LastWindow := Native.Window;
        State.HavePointer := True;
      end;
    8:
      State.HavePointer := False;
    10:
      State.ResetDesktop;
  end;
end;

procedure TLinuxInputBackend.Reset;
begin
  TLinuxState(FImpl).ResetDesktop;
end;
{$ENDIF}

end.

