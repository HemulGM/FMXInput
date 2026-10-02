unit FMXInput.Windows;

interface

uses FMXInput;

{$IFDEF MSWINDOWS}
type
  TWindowsInputBackend = class(TInputBackend)
  private
    FImpl: TObject;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Refresh; override;
    function Poll: TArray<TInputValue>; override;
    procedure Reset; override;
  end;
{$ENDIF}

implementation

{$IFDEF MSWINDOWS}
uses
  System.SysUtils, System.Classes, System.Generics.Collections,
  System.Win.Registry, Winapi.Windows, Winapi.Messages, Winapi.DirectInput;

type
  TRawDevice = record
    Handle: THandle;
    DeviceType: Cardinal;
  end;
  TRawRegistration = record
    UsagePage, Usage: Word;
    Flags: Cardinal;
    Target: HWND;
  end;
  TRawHeader = record
    InputType, Size: Cardinal;
    Device: THandle;
    Param: WPARAM;
  end;
  TRawKey = record
    MakeCode, Flags, Reserved, VKey: Word;
    Message, Extra: Cardinal;
  end;
  TRawKeyboardPacket = record
    Header: TRawHeader;
    Key: TRawKey;
  end;
  PRawKeyboardPacket = ^TRawKeyboardPacket;
  TXInputGamepad = record
    Buttons: Word;
    LeftTrigger, RightTrigger: Byte;
    LeftX, LeftY, RightX, RightY: SmallInt;
  end;
  TXInputState = record
    Packet: Cardinal;
    Gamepad: TXInputGamepad;
  end;
  TXInputGetState = function(Index: Cardinal; out State: TXInputState): Cardinal; stdcall;
  TXInputDevice = class
    Slot: Cardinal;
    Info: TInputDevice;
  end;

function RawDeviceList(List: Pointer; var Count: Cardinal; Size: Cardinal): Cardinal; stdcall;
  external 'user32.dll' name 'GetRawInputDeviceList';
function RawDeviceInfo(Device: THandle; Command: Cardinal; Data: Pointer; var Size: Cardinal): Cardinal; stdcall;
  external 'user32.dll' name 'GetRawInputDeviceInfoW';
function RawData(Input: THandle; Command: Cardinal; Data: Pointer; var Size: Cardinal; HeaderSize: Cardinal): Cardinal; stdcall;
  external 'user32.dll' name 'GetRawInputData';
function RawRegister(Devices: Pointer; Count, Size: Cardinal): BOOL; stdcall;
  external 'user32.dll' name 'RegisterRawInputDevices';

type
  TKeyboard = class
    Handle: THandle;
    Info: TInputDevice;
    Down: TDictionary<Integer, Boolean>;
    constructor Create;
    destructor Destroy; override;
  end;
  TController = class
    Info: TInputDevice;
    Device: IDirectInputDevice8W;
    Ranges: TDictionary<Integer, TDIPropRange>;
    Seen: Boolean;
    constructor Create;
    destructor Destroy; override;
  end;
  TWindowsState = class
    Window: HWND;
    Input: IDirectInput8W;
    Keyboards: TObjectList<TKeyboard>;
    Controllers: TObjectList<TController>;
    XPads: TObjectList<TXInputDevice>;
    XProducts: TDictionary<Cardinal, Boolean>;
    XModule: HMODULE;
    XGetState: TXInputGetState;
    procedure WindowProc(var Msg: TMessage);
    procedure ReadKey(Handle: THandle);
    procedure Enumerate;
    constructor Create;
    destructor Destroy; override;
  end;

var
  RawOwner: HWND;

constructor TKeyboard.Create;
begin inherited; Down := TDictionary<Integer, Boolean>.Create; end;
destructor TKeyboard.Destroy;
begin Down.Free; inherited; end;
constructor TController.Create;
begin inherited; Ranges := TDictionary<Integer, TDIPropRange>.Create; end;
destructor TController.Destroy;
begin
  if Device <> nil then Device.Unacquire;
  Device := nil; Ranges.Free; inherited;
end;

function EnumObjects(var Obj: TDIDeviceObjectInstanceW; Context: Pointer): BOOL; stdcall;
var
  Element: TInputElement;
  Range: TDIPropRange;
begin
  Result := DIENUM_CONTINUE;
  var Controller := TController(Context);
  if (Obj.dwType and DIDFT_BUTTON) <> 0 then Element.Kind := TInputElementKind.Button
  else if (Obj.dwType and DIDFT_POV) <> 0 then Element.Kind := TInputElementKind.Hat
  else if (Obj.dwType and DIDFT_ABSAXIS) <> 0 then Element.Kind := TInputElementKind.Axis
  else Exit;
  Element.Code := Obj.dwOfs;
  Element.Name := PWideChar(@Obj.tszName[0]);
  if (Element.Code < 0) or (Element.Code >= SizeOf(TDIJoyState2)) then Exit;
  if Element.Kind = TInputElementKind.Axis then
  begin
    Range := Default(TDIPropRange);
    Range.diph.dwSize := SizeOf(Range);
    Range.diph.dwHeaderSize := SizeOf(Range.diph);
    Range.diph.dwObj := Obj.dwOfs; Range.diph.dwHow := DIPH_BYOFFSET;
    Range.lMin := 0; Range.lMax := 65535;
    Controller.Device.GetProperty(DIPROP_RANGE, Range.diph);
    Controller.Ranges.AddOrSetValue(Element.Code, Range);
  end;
  Controller.Info.Elements := Controller.Info.Elements + [Element];
end;

function EnumControllers(var Instance: TDIDeviceInstanceW; Context: Pointer): BOOL; stdcall;
begin
  Result := DIENUM_CONTINUE;
  var State := TWindowsState(Context);
  // XUSB controllers expose a second DirectInput interface. Use XInput for
  // these devices so triggers stay independent and devices are listed once.
  if State.XProducts.ContainsKey(Instance.guidProduct.D1) then Exit;
  var Id := 'windows:directinput:' + GUIDToString(Instance.guidInstance);
  for var Existing in State.Controllers do
    if Existing.Info.Id = Id then
    begin Existing.Seen := True; Exit; end;
  var Controller := TController.Create;
  try
    Controller.Info.Id := Id;
    Controller.Info.Name := PWideChar(@Instance.tszProductName[0]);
    Controller.Info.Kind := TInputDeviceKind.Controller;
    Controller.Info.VendorId := Word(Instance.guidProduct.D1 and $FFFF);
    Controller.Info.ProductId := Word(Instance.guidProduct.D1 shr 16);
    var Status := State.Input.CreateDevice(Instance.guidInstance, Controller.Device, nil);
    if Succeeded(Status) then Status := Controller.Device.SetDataFormat(c_dfDIJoystick2);
    if Succeeded(Status) then Status := Controller.Device.SetCooperativeLevel(State.Window,
      DISCL_BACKGROUND or DISCL_NONEXCLUSIVE);
    Controller.Info.Available := Succeeded(Status);
    if Controller.Info.Available then
    begin
      Controller.Device.EnumObjects(EnumObjects, Controller, DIDFT_ALL);
      Controller.Device.Acquire;
    end
    else Controller.Info.Error := Format('DirectInput HRESULT %.8x', [Cardinal(Status)]);
    Controller.Seen := True;
    State.Controllers.Add(Controller);
    Controller := nil;
  finally Controller.Free; end;
end;

constructor TWindowsState.Create;
begin
  inherited;
  if RawOwner <> 0 then raise EInvalidOperation.Create('Use one native Windows backend per process');
  Keyboards := TObjectList<TKeyboard>.Create;
  Controllers := TObjectList<TController>.Create;
  XPads := TObjectList<TXInputDevice>.Create;
  XProducts := TDictionary<Cardinal, Boolean>.Create;
  XModule := LoadLibraryEx('xinput1_4.dll', 0, $800); // system32 only
  if XModule = 0 then XModule := LoadLibraryEx('xinput9_1_0.dll', 0, $800);
  if XModule <> 0 then XGetState := TXInputGetState(GetProcAddress(XModule, 'XInputGetState'));
  Window := AllocateHWnd(WindowProc);
  var Registration: TRawRegistration;
  Registration.UsagePage := 1; Registration.Usage := 6;
  // Nonexclusive registration: ordinary FMX/VCL keyboard input remains enabled.
  Registration.Flags := $100 or $2000; // INPUTSINK | DEVNOTIFY
  Registration.Target := Window;
  if not RawRegister(@Registration, 1, SizeOf(Registration)) then RaiseLastOSError;
  RawOwner := Window;
  var Status := DirectInput8Create(HInstance, $0800, IID_IDirectInput8W, Input, nil);
  if Failed(Status) then raise EInvalidOperation.CreateFmt('DirectInput initialization: %.8x', [Cardinal(Status)]);
end;

destructor TWindowsState.Destroy;
begin
  if (Window <> 0) and (RawOwner = Window) then
  begin
    var Registration := Default(TRawRegistration);
    Registration.UsagePage := 1; Registration.Usage := 6;
    Registration.Flags := 1; // RIDEV_REMOVE, null target required
    RawRegister(@Registration, 1, SizeOf(Registration));
    RawOwner := 0;
  end;
  Controllers.Free; Keyboards.Free; XPads.Free; XProducts.Free; Input := nil;
  if XModule <> 0 then FreeLibrary(XModule);
  if Window <> 0 then DeallocateHWnd(Window);
  inherited;
end;

procedure TWindowsState.WindowProc(var Msg: TMessage);
begin
  try
    if Msg.Msg = WM_INPUT then ReadKey(THandle(Msg.LParam));
  except
    // Never let Pascal exceptions cross the Windows callback boundary.
    for var Keyboard in Keyboards do Keyboard.Down.Clear;
  end;
  Msg.Result := DefWindowProc(Window, Msg.Msg, Msg.WParam, Msg.LParam);
end;

procedure TWindowsState.ReadKey(Handle: THandle);
begin
  var Size: Cardinal := 0;
  if RawData(Handle, $10000003, nil, Size, SizeOf(TRawHeader)) = High(Cardinal) then Exit;
  if Size < SizeOf(TRawKeyboardPacket) then Exit;
  var Data: TBytes;
  SetLength(Data, Size);
  if RawData(Handle, $10000003, @Data[0], Size, SizeOf(TRawHeader)) = High(Cardinal) then Exit;
  var Packet := PRawKeyboardPacket(@Data[0]);
  if Packet.Header.InputType <> 1 then Exit;
  var Code := ScanCodeToHid(Packet.Key.MakeCode, (Packet.Key.Flags and 2) <> 0);
  if (Packet.Key.Flags and 4) <> 0 then Code := 72; // E1 / Pause
  if Code = 0 then Exit;
  for var Keyboard in Keyboards do
    if Keyboard.Handle = Packet.Header.Device then
    begin
      if (Packet.Key.Flags and 1) <> 0 then Keyboard.Down.Remove(Code)
      else Keyboard.Down.AddOrSetValue(Code, True);
      Exit;
    end;
end;

function DevicePathName(Handle: THandle): string;
begin
  Result := '';
  var Size: Cardinal := 0;
  if RawDeviceInfo(Handle, $20000007, nil, Size) = High(Cardinal) then Exit;
  var Name: TArray<WideChar>;
  SetLength(Name, Size + 1);
  if RawDeviceInfo(Handle, $20000007, @Name[0], Size) <> High(Cardinal) then
    Result := PWideChar(@Name[0]);
end;

function PathHexId(const Path, Prefix: string): Word;
begin
  var Position := Pos(Prefix, UpperCase(Path));
  if Position > 0 then Result := Word(StrToIntDef('$' + Copy(Path, Position + Length(Prefix), 4), 0))
  else Result := 0;
end;

function KeyboardName(const Path: string): string;
begin
  Result := 'Keyboard';
  var Parts := Path.Split(['#']);
  if Length(Parts) < 3 then Exit;
  var Reg := TRegistry.Create(KEY_READ);
  try
    Reg.RootKey := HKEY_LOCAL_MACHINE;
    var Bus := Parts[0];
    if Copy(Bus, 1, 4) = '\\?\' then Delete(Bus, 1, 4);
    if Reg.OpenKeyReadOnly('SYSTEM\CurrentControlSet\Enum\' + Bus + '\' + Parts[1] + '\' + Parts[2]) then
    begin
      if Reg.ValueExists('FriendlyName') then Result := Reg.ReadString('FriendlyName')
      else if Reg.ValueExists('DeviceDesc') then
      begin
        Result := Reg.ReadString('DeviceDesc');
        var Index := LastDelimiter(';', Result);
        if Index > 0 then Result := Copy(Result, Index + 1, MaxInt);
      end;
    end;
  finally Reg.Free; end;
end;

procedure TWindowsState.Enumerate;
begin
  var Count: Cardinal := 0;
  if RawDeviceList(nil, Count, SizeOf(TRawDevice)) = High(Cardinal) then RaiseLastOSError;
  var Devices: TArray<TRawDevice>;
  SetLength(Devices, Count);
  if Count > 0 then
  begin
    var ReadCount := RawDeviceList(@Devices[0], Count, SizeOf(TRawDevice));
    if ReadCount = High(Cardinal) then RaiseLastOSError;
    SetLength(Devices, ReadCount);
  end;
  XProducts.Clear;
  if Assigned(XGetState) then
    for var D in Devices do
    begin
      if D.DeviceType <> 2 then Continue;
      var Path := DevicePathName(D.Handle);
      if Pos('IG_', UpperCase(Path)) = 0 then Continue;
      var Vendor := PathHexId(Path, 'VID_');
      var Product := PathHexId(Path, 'PID_');
      if (Vendor <> 0) and (Product <> 0) then
        XProducts.AddOrSetValue(Cardinal(Vendor) or (Cardinal(Product) shl 16), True);
    end;
  for var I := Keyboards.Count - 1 downto 0 do
  begin
    var Found := False;
    for var D in Devices do
      if (D.DeviceType = 1) and (D.Handle = Keyboards[I].Handle) then Found := True;
    if not Found then Keyboards.Delete(I);
  end;
  for var D in Devices do
  begin
    if D.DeviceType <> 1 then Continue;
    var Found := False;
    for var Existing in Keyboards do if Existing.Handle = D.Handle then Found := True;
    if Found then Continue;
    var Path := DevicePathName(D.Handle);
    if Path = '' then Continue;
    var Keyboard := TKeyboard.Create;
    Keyboard.Handle := D.Handle;
    Keyboard.Info.Id := 'windows:raw:' + Path;
    Keyboard.Info.Name := KeyboardName(Path);
    Keyboard.Info.VendorId := PathHexId(Path, 'VID_');
    Keyboard.Info.ProductId := PathHexId(Path, 'PID_');
    Keyboard.Info.Kind := TInputDeviceKind.Keyboard; Keyboard.Info.Available := True;
    // Raw Input does not enumerate individual keyboard HID elements.
    for var Code := 4 to 231 do
    begin
      var Element: TInputElement;
      Element.Kind := TInputElementKind.Key; Element.Code := Code;
      Element.Name := InputKeyName(Code);
      Keyboard.Info.Elements := Keyboard.Info.Elements + [Element];
    end;
    Keyboards.Add(Keyboard);
  end;
  for var Controller in Controllers do Controller.Seen := False;
  if Failed(Input.EnumDevices(DI8DEVCLASS_GAMECTRL, EnumControllers, Self, DIEDFL_ATTACHEDONLY)) then
    raise EInvalidOperation.Create('DirectInput enumeration failed');
  for var I := Controllers.Count - 1 downto 0 do
    if not Controllers[I].Seen then Controllers.Delete(I);
  if Assigned(XGetState) then
  begin
    for var I := XPads.Count - 1 downto 0 do
    begin
      var Data: TXInputState;
      if XGetState(XPads[I].Slot, Data) <> 0 then XPads.Delete(I);
    end;
    for var Slot := 0 to 3 do
    begin
      var Data: TXInputState;
      if XGetState(Slot, Data) <> 0 then Continue;
      var Found := False;
      for var Pad in XPads do if Pad.Slot = Cardinal(Slot) then Found := True;
      if Found then Continue;
      var Pad := TXInputDevice.Create;
      Pad.Slot := Slot;
      // XInput exposes slots, not persistent physical identities.
      Pad.Info.Id := 'windows:xinput:slot:' + IntToStr(Slot);
      Pad.Info.Name := 'XInput controller ' + IntToStr(Slot + 1);
      Pad.Info.Kind := TInputDeviceKind.Controller; Pad.Info.Available := True;
      for var Bit := 0 to 15 do
        if not (Bit in [10, 11]) then
        begin
          var Element: TInputElement;
          Element.Kind := TInputElementKind.Button; Element.Code := Bit;
          Element.Name := 'Button bit ' + IntToStr(Bit);
          Pad.Info.Elements := Pad.Info.Elements + [Element];
        end;
      for var Axis := 0 to 5 do
      begin
        var Element: TInputElement;
        Element.Kind := TInputElementKind.Axis; Element.Code := Axis;
        Element.Name := 'Axis ' + IntToStr(Axis);
        Pad.Info.Elements := Pad.Info.Elements + [Element];
      end;
      XPads.Add(Pad);
    end;
  end;
end;

constructor TWindowsInputBackend.Create;
begin inherited; FImpl := TWindowsState.Create; end;
destructor TWindowsInputBackend.Destroy;
begin FImpl.Free; inherited; end;

procedure TWindowsInputBackend.Refresh;
begin
  var State := TWindowsState(FImpl);
  State.Enumerate;
  FDevices := nil;
  for var Keyboard in State.Keyboards do FDevices := FDevices + [Keyboard.Info];
  for var Controller in State.Controllers do FDevices := FDevices + [Controller.Info];
  for var Pad in State.XPads do FDevices := FDevices + [Pad.Info];
end;

procedure TWindowsInputBackend.Reset;
begin
  var State := TWindowsState(FImpl);
  var Message: TMsg;
  while PeekMessage(Message, State.Window, 0, 0, PM_REMOVE) do DispatchMessage(Message);
  for var Keyboard in State.Keyboards do Keyboard.Down.Clear;
end;

function TWindowsInputBackend.Poll: TArray<TInputValue>;
begin
  var State := TWindowsState(FImpl);
  var Message: TMsg;
  // Process only our hidden window, without pumping the application's UI.
  while PeekMessage(Message, State.Window, 0, 0, PM_REMOVE) do DispatchMessage(Message);
  var Values := TList<TInputValue>.Create;
  try
    for var Keyboard in State.Keyboards do
      for var Code in Keyboard.Down.Keys do
        Values.Add(TInputValue.Create(Keyboard.Info.Id, TInputElementKind.Key, Code, 1));
    for var Controller in State.Controllers do
    begin
      if Controller.Device = nil then Continue;
      var Status := Controller.Device.Poll;
      if Failed(Status) then
      begin Controller.Device.Acquire; Status := Controller.Device.Poll; end;
      var Data: TDIJoyState2;
      if Succeeded(Status) then Status := Controller.Device.GetDeviceState(SizeOf(Data), @Data);
      Controller.Info.Available := Succeeded(Status);
      if Failed(Status) then
      begin
        Controller.Info.Error := Format('DirectInput read HRESULT %.8x', [Cardinal(Status)]);
        Continue;
      end;
      Controller.Info.Error := '';
      for var Element in Controller.Info.Elements do
      begin
        var Address := PByte(@Data) + Element.Code;
        var Value: Single := 0;
        case Element.Kind of
          TInputElementKind.Button: if Address^ and $80 <> 0 then Value := 1;
          TInputElementKind.Hat:
            if PCardinal(Address)^ = High(Cardinal) then Value := -1
            else Value := ((PCardinal(Address)^ + 2250) div 4500) mod 8;
          TInputElementKind.Axis:
            begin
              var Range: TDIPropRange;
              if Controller.Ranges.TryGetValue(Element.Code, Range) then
                Value := NormalizeAxis(PInteger(Address)^, Range.lMin, Range.lMax);
            end;
        end;
        Values.Add(TInputValue.Create(Controller.Info.Id, Element.Kind, Element.Code, Value));
      end;
    end;
    for var Pad in State.XPads do
    begin
      var Data: TXInputState;
      Pad.Info.Available := State.XGetState(Pad.Slot, Data) = 0;
      if not Pad.Info.Available then
      begin Pad.Info.Error := 'XInput controller disconnected'; Continue; end;
      Pad.Info.Error := '';
      for var Element in Pad.Info.Elements do
      begin
        var Value: Single := 0;
        if Element.Kind = TInputElementKind.Button then
        begin
          if Data.Gamepad.Buttons and (1 shl Element.Code) <> 0 then Value := 1;
        end
        else
          case Element.Code of
            0: Value := NormalizeAxis(Data.Gamepad.LeftX, -32768, 32767);
            1: Value := NormalizeAxis(Data.Gamepad.LeftY, -32768, 32767);
            2: Value := NormalizeAxis(Data.Gamepad.RightX, -32768, 32767);
            3: Value := NormalizeAxis(Data.Gamepad.RightY, -32768, 32767);
            4: Value := Data.Gamepad.LeftTrigger / 255.0;
            5: Value := Data.Gamepad.RightTrigger / 255.0;
          end;
        Values.Add(TInputValue.Create(Pad.Info.Id, Element.Kind, Element.Code, Value));
      end;
    end;
    FDevices := nil;
    for var Keyboard in State.Keyboards do FDevices := FDevices + [Keyboard.Info];
    for var Controller in State.Controllers do FDevices := FDevices + [Controller.Info];
    for var Pad in State.XPads do FDevices := FDevices + [Pad.Info];
    Result := Values.ToArray;
  finally Values.Free; end;
end;
{$ENDIF}

end.
