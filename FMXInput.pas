unit FMXInput;

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections;

{$SCOPEDENUMS ON}

type
  TInputDeviceKind = (Keyboard, Controller, Mouse);

  TInputElementKind = (Key, Button, Axis, Hat, RelativeAxis);

  TInputDeviceListMode = (Gaming, AllInterfaces);

  TInputElement = record
    Kind: TInputElementKind;
    Code: Integer;
    Name: string;
    // Axis values are normalized to [-1, 1]. Hat values are -1 (neutral)
    // or clockwise directions 0..7, starting at up. Keys use USB HID usages.
    // RelativeAxis values are raw motion counts / fractional wheel detents.
  end;

  TInputDevice = record
    Id, Name, Serial, Error: string;
    PhysicalId: string; // Same physical parent/container, never vendor/product alone.
    IsVirtual, IsAuxiliary: Boolean;
    Kind: TInputDeviceKind;
    VendorId, ProductId: Word;
    Available: Boolean;
    RumbleSupported: Boolean; // Backend/driver reports at least one vibration motor.
    Elements: TArray<TInputElement>;
  end;

  TInputValue = record
    DeviceId: string;
    Kind: TInputElementKind;
    Code: Integer;
    Value: Single;
    class function Create(const DeviceId: string; Kind: TInputElementKind; Code: Integer; Value: Single): TInputValue; static;
  end;

  // Backends return complete current snapshots, not only changed values.
  // Missing values mean released/neutral. Calls must use the creation thread.
  // RelativeAxis is an accumulated delta consumed by each backend Poll.
  TInputBackend = class abstract
  private
    FPublishedValid: Boolean;
    FPublishedMode: TInputDeviceListMode;
    FPublishedSources, FPublishedDevices: TArray<TInputDevice>;
    FPublishedIds: TDictionary<string, string>;
    function PublishedDevicesCurrent: Boolean;
    function BuildPublishedDevices: TArray<TInputDevice>;
    procedure EnsurePublishedDevices;
  protected
    FDevices: TArray<TInputDevice>;
    function PublishValues(const Values: TArray<TInputValue>): TArray<TInputValue>;
  public
    DeviceListMode: TInputDeviceListMode; // Only affects controller interfaces; desktop input is always combined.
    destructor Destroy; override;
    procedure Refresh; virtual; abstract;
    // Periodic discovery may use cached topology; explicit Refresh stays complete.
    procedure RefreshIfNeeded; virtual;
    function Poll: TArray<TInputValue>; virtual; abstract;
    procedure Reset; virtual;
    // Finite pulse, motor speeds 0..65535. Zero duration or both speeds zero stops.
    // Unsupported/disconnected pulses return False. A new pulse replaces the old.
    function SetRumble(const DeviceId: string; LowFrequency, HighFrequency: Word;
      DurationMs: UInt16): Boolean; virtual;
    // Empty ID stops all effects owned by this backend.
    procedure StopRumble(const DeviceId: string = ''); virtual;
    function Devices: TArray<TInputDevice>;
    function RawDevices: TArray<TInputDevice>;
  end;

  TInputBinding = record
    Action: Integer; // Opaque application-defined action, e.g. player 2 / A.
    DeviceId: string;
    Kind: TInputElementKind;
    Code: Integer;
    Direction: Integer; // Axis/RelativeAxis: -1/+1. Hat: 0..7. Key/button: ignored.
    AxisOrigin: Single; // Rest position: 0 for sticks, often -1/+1 for triggers.
    PressThreshold, ReleaseThreshold: Single;
    class function Create(Action: Integer; const Value: TInputValue): TInputBinding; static;
  end;

  TInputManager = class
  private
    FBackend: TInputBackend;
    FOwnsBackend, FEnabled, FCapturing, FCapturePointerMotion: Boolean;
    FThreadId: TThreadID;
    FLastRefresh: UInt64;
    FValues: TDictionary<string, Single>;
    FCurrentValues: TArray<TInputValue>;
    FBlocked: TDictionary<string, Boolean>;
    FCaptureOrigins: TDictionary<string, Single>;
    FBindings: TList<TInputBinding>;
    FActiveBindings: TList<Boolean>;
    FCaptureDevice: string;
    FCaptureAction: Integer;
    FCaptured: TInputBinding;
    FHasCaptured: Boolean;
    procedure CheckThread;
    procedure SetEnabled(Value: Boolean);
    function BindingPressed(const Binding: TInputBinding; WasPressed: Boolean): Boolean;
  public
    constructor Create(Backend: TInputBackend; OwnsBackend: Boolean = True);
    destructor Destroy; override;
    procedure Refresh;
    procedure Poll;
    function SetRumble(const DeviceId: string; LowFrequency, HighFrequency: Word;
      DurationMs: UInt16): Boolean;
    procedure StopRumble(const DeviceId: string = '');
    procedure ClearBindings;
    procedure AddBinding(const Binding: TInputBinding);
    procedure RemoveBindings(Action: Integer);
    function Bindings: TArray<TInputBinding>;
    function Devices: TArray<TInputDevice>;
    function Values: TArray<TInputValue>;
    function IsPressed(Action: Integer): Boolean;
    procedure BeginCapture(Action: Integer; const DeviceId: string = ''; IncludePointerMotion: Boolean = False);
    procedure CancelCapture;
    function TakeCaptured(out Binding: TInputBinding): Boolean;
    procedure SaveBindings(Stream: TStream);
    procedure LoadBindings(Stream: TStream);
    property Enabled: Boolean read FEnabled write SetEnabled;
    property Capturing: Boolean read FCapturing;
  end;

// Native factory is desktop-only. No FMX/VCL/RetroMul dependencies.
function CreateFMXInputBackend(ListMode: TInputDeviceListMode = TInputDeviceListMode.Gaming): TInputBackend;

const
  SystemKeyboardId = 'system:keyboard';
  SystemMouseId = 'system:mouse';
  MouseLeft = 0;
  MouseRight = 1;
  MouseMiddle = 2;
  MouseBack = 3;
  MouseForward = 4;
  MouseX = 0;
  MouseY = 1;
  MouseWheel = 2;
  MouseHorizontalWheel = 3;

function InputDeviceKindName(Kind: TInputDeviceKind): string;

function MouseElementName(Kind: TInputElementKind; Code: Integer): string;

function IsGamingInputDevice(const Device: TInputDevice): Boolean;

function InputDeviceId(const Device: TInputDevice; Mode: TInputDeviceListMode): string;

function InputValueKey(const DeviceId: string; Kind: TInputElementKind; Code: Integer): string;

function NormalizeAxis(Value, Minimum, Maximum: Int64): Single;

function ScanCodeToHid(ScanCode: Word; Extended: Boolean): Word;

function LinuxKeyToHid(Code: Word): Word;

function MacKeyToHid(Code: Word): Word;

function DesktopInputDevice(Kind: TInputDeviceKind): TInputDevice;

function InputKeyName(Code: Integer): string;

implementation

uses
  System.Math,
  {$IF Defined(MSWINDOWS)}
  FMXInput.Windows,
  {$ELSEIF Defined(LINUX) and not Defined(ANDROID)}
  FMXInput.Linux,
  {$ELSEIF Defined(MACOS) and not Defined(IOS)}
  FMXInput.MacOS,
  {$ELSE}
  System.Types,
  {$ENDIF}
  System.JSON;

function CreateFMXInputBackend(ListMode: TInputDeviceListMode): TInputBackend;
begin
  {$IF Defined(MSWINDOWS)}
  Result := TWindowsInputBackend.Create;
  {$ELSEIF Defined(LINUX) and not Defined(ANDROID)}
  Result := TLinuxInputBackend.Create;
  {$ELSEIF Defined(MACOS) and not Defined(IOS)}
  Result := TMacOSInputBackend.Create;
  {$ELSE}
  raise ENotSupportedException.Create('FMXInput supports Windows, Linux and macOS desktops');
  {$ENDIF}
  Result.DeviceListMode := ListMode;
end;

function InputDeviceKindName(Kind: TInputDeviceKind): string;
begin
  case Kind of
    TInputDeviceKind.Keyboard:
      Result := 'Keyboard';
    TInputDeviceKind.Controller:
      Result := 'Controller';
    TInputDeviceKind.Mouse:
      Result := 'Mouse';
  end;
end;

function MouseElementName(Kind: TInputElementKind; Code: Integer): string;
const
  Buttons: array[0..4] of string = ('Left button', 'Right button', 'Middle button', 'Back button', 'Forward button');
  Axes: array[0..3] of string = ('Mouse X', 'Mouse Y', 'Wheel', 'Horizontal wheel');
begin
  if (Kind = TInputElementKind.Button) and (Code >= 0) and (Code <= High(Buttons)) then
    Exit(Buttons[Code]);
  if (Kind = TInputElementKind.RelativeAxis) and (Code >= 0) and (Code <= High(Axes)) then
    Exit(Axes[Code]);
  Result := 'Mouse button ' + IntToStr(Code + 1);
end;

function IsGamingInputDevice(const Device: TInputDevice): Boolean;
begin
  Result := not Device.IsAuxiliary and (Length(Device.Elements) > 0);
  if not Result then
    Exit;
  if Device.Kind = TInputDeviceKind.Mouse then
  begin
    var X, Y, Button: Boolean;
    X := False;
    Y := False;
    Button := False;
    for var E in Device.Elements do
    begin
      if E.Kind = TInputElementKind.RelativeAxis then
        case E.Code of
          MouseX:
            X := True;
          MouseY:
            Y := True;
        end;
      if (E.Kind = TInputElementKind.Button) and (E.Code = MouseLeft) then
        Button := True;
    end;
    Result := X and Y and Button;
  end;
  if Device.Kind = TInputDeviceKind.Keyboard then
  begin
    var A, Q, Enter, Space: Boolean;
    A := False;
    Q := False;
    Enter := False;
    Space := False;
    for var E in Device.Elements do
      if E.Kind = TInputElementKind.Key then
        case E.Code of
          4:
            A := True;
          20:
            Q := True;
          40:
            Enter := True;
          44:
            Space := True;
        end;
    Result := A and Q and Enter and Space;
  end;
end;

function InputDeviceId(const Device: TInputDevice; Mode: TInputDeviceListMode): string;
begin
  if Device.Kind = TInputDeviceKind.Keyboard then
    Exit(SystemKeyboardId);
  if Device.Kind = TInputDeviceKind.Mouse then
    Exit(SystemMouseId);
  Result := Device.Id;
  if (Mode = TInputDeviceListMode.Gaming) and (Device.PhysicalId <> '') then
    Result := Device.PhysicalId + ':' + InputDeviceKindName(Device.Kind).ToLower;
end;

function InputValueKey(const DeviceId: string; Kind: TInputElementKind; Code: Integer): string;
begin
  Result := IntToStr(Length(DeviceId)) + ':' + DeviceId + ':' +
    IntToStr(Ord(Kind)) + ':' + IntToStr(Code);
end;

function NormalizeAxis(Value, Minimum, Maximum: Int64): Single;
begin
  if Maximum <= Minimum then
    Exit(0);
  Result := EnsureRange(2.0 * (Double(Value) - Double(Minimum)) /
    (Double(Maximum) - Double(Minimum)) - 1.0, -1.0, 1.0);
end;

function ScanCodeToHid(ScanCode: Word; Extended: Boolean): Word;
const
  // PC set-1 make codes 0..88 -> USB keyboard usage IDs. Independent of layout.
  Codes: array[0..88] of Byte = (
    0, 41, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 45, 46, 42, 43,
    20, 26, 8, 21, 23, 28, 24, 12, 18, 19, 47, 48, 40, 224, 4, 22,
    7, 9, 10, 11, 13, 14, 15, 51, 52, 53, 225, 49, 29, 27, 6, 25,
    5, 17, 16, 54, 55, 56, 229, 85, 226, 44, 57, 58, 59, 60, 61, 62,
    63, 64, 65, 66, 67, 83, 71, 95, 96, 97, 86, 92, 93, 94, 87, 89,
    90, 91, 98, 99, 0, 0, 100, 68, 69);
begin
  if Extended then
    case ScanCode of
      $1C:
        Exit(88);
      $1D:
        Exit(228);
      $35:
        Exit(84);
      $37:
        Exit(70);
      $38:
        Exit(230);
      $47:
        Exit(74);
      $48:
        Exit(82);
      $49:
        Exit(75);
      $4B:
        Exit(80);
      $4D:
        Exit(79);
      $4F:
        Exit(77);
      $50:
        Exit(81);
      $51:
        Exit(78);
      $52:
        Exit(73);
      $53:
        Exit(76);
      $5B:
        Exit(227);
      $5C:
        Exit(231);
      $5D:
        Exit(101);
    else
      Exit(0);
    end;
  if ScanCode <= High(Codes) then
    Result := Codes[ScanCode]
  else
    Result := 0;
end;

function LinuxKeyToHid(Code: Word): Word;
begin
  if Code <= 88 then
    Exit(ScanCodeToHid(Code, False));
  case Code of
    96:
      Result := 88;
    97:
      Result := 228;
    98:
      Result := 84;
    99:
      Result := 70;
    100:
      Result := 230;
    102:
      Result := 74;
    103:
      Result := 82;
    104:
      Result := 75;
    105:
      Result := 80;
    106:
      Result := 79;
    107:
      Result := 77;
    108:
      Result := 81;
    109:
      Result := 78;
    110:
      Result := 73;
    111:
      Result := 76;
    119:
      Result := 72;
    125:
      Result := 227;
    126:
      Result := 231;
    127:
      Result := 101;
  else
    Result := 0;
  end;
end;

class function TInputValue.Create(const DeviceId: string; Kind: TInputElementKind; Code: Integer; Value: Single): TInputValue;
begin
  Result.DeviceId := DeviceId;
  Result.Kind := Kind;
  Result.Code := Code;
  Result.Value := Value;
end;

function InputKeyName(Code: Integer): string;
begin
  if (Code >= 4) and (Code <= 29) then
    Exit(Char(Ord('A') + Code - 4));
  if (Code >= 30) and (Code <= 38) then
    Exit(IntToStr(Code - 29));
  if (Code >= 58) and (Code <= 69) then
    Exit('F' + IntToStr(Code - 57));
  case Code of
    39:
      Result := '0';
    40:
      Result := 'Enter';
    41:
      Result := 'Escape';
    42:
      Result := 'Backspace';
    43:
      Result := 'Tab';
    44:
      Result := 'Space';
    45:
      Result := '-';
    46:
      Result := '=';
    47:
      Result := '[';
    48:
      Result := ']';
    49:
      Result := '\';
    51:
      Result := ';';
    52:
      Result := '''';
    53:
      Result := '`';
    54:
      Result := ',';
    55:
      Result := '.';
    56:
      Result := '/';
    57:
      Result := 'Caps Lock';
    70:
      Result := 'Print Screen';
    71:
      Result := 'Scroll Lock';
    72:
      Result := 'Pause';
    73:
      Result := 'Insert';
    74:
      Result := 'Home';
    75:
      Result := 'Page Up';
    76:
      Result := 'Delete';
    77:
      Result := 'End';
    78:
      Result := 'Page Down';
    79:
      Result := 'Right';
    80:
      Result := 'Left';
    81:
      Result := 'Down';
    82:
      Result := 'Up';
    83:
      Result := 'Num Lock';
    84:
      Result := 'Keypad /';
    85:
      Result := 'Keypad *';
    86:
      Result := 'Keypad -';
    87:
      Result := 'Keypad +';
    88:
      Result := 'Keypad Enter';
    89..97:
      Result := 'Keypad ' + IntToStr(Code - 88);
    98:
      Result := 'Keypad 0';
    99:
      Result := 'Keypad .';
    100:
      Result := 'ISO extra key';
    101:
      Result := 'Menu';
    224:
      Result := 'Left Ctrl';
    225:
      Result := 'Left Shift';
    226:
      Result := 'Left Alt';
    227:
      Result := 'Left Meta';
    228:
      Result := 'Right Ctrl';
    229:
      Result := 'Right Shift';
    230:
      Result := 'Right Alt';
    231:
      Result := 'Right Meta';
  else
    Result := 'HID key ' + IntToStr(Code);
  end;
end;

function MacKeyToHid(Code: Word): Word;
const
  // AppKit virtual key codes are physical positions, independent of text layout.
  Codes: array[0..127] of Byte = (
    4, 22, 7, 9, 11, 10, 29, 27, 6, 25, 100, 5, 20, 26, 8, 21,
    28, 23, 30, 31, 32, 33, 35, 34, 46, 38, 36, 45, 37, 39, 48, 18,
    24, 47, 12, 19, 40, 15, 13, 52, 14, 51, 49, 54, 56, 17, 16, 55,
    43, 44, 53, 42, 0, 41, 231, 227, 225, 57, 226, 224, 229, 230, 228, 0,
    108, 99, 0, 85, 0, 87, 0, 83, 0, 0, 0, 84, 88, 0, 86, 109,
    110, 103, 98, 89, 90, 91, 92, 93, 94, 95, 111, 96, 97, 0, 0, 0,
    62, 63, 64, 60, 65, 66, 0, 68, 0, 104, 107, 105, 0, 67, 0, 69,
    0, 106, 73, 74, 75, 76, 61, 77, 59, 78, 58, 80, 79, 81, 82, 0);
begin
  if Code <= High(Codes) then
    Result := Codes[Code]
  else
    Result := 0;
end;

function DesktopInputDevice(Kind: TInputDeviceKind): TInputDevice;
begin
  if Kind = TInputDeviceKind.Controller then
    raise EArgumentException.Create('A controller is not an aggregate desktop source');
  Result := Default(TInputDevice);
  Result.Kind := Kind;
  Result.Id := InputDeviceId(Result, TInputDeviceListMode.Gaming);
  Result.Name := InputDeviceKindName(Kind);
  Result.Available := True;
  if Kind = TInputDeviceKind.Keyboard then
    for var Code := 4 to 231 do
    begin
      var E: TInputElement;
      E.Kind := TInputElementKind.Key;
      E.Code := Code;
      E.Name := InputKeyName(Code);
      Result.Elements := Result.Elements + [E];
    end
  else
  begin
    for var Code := 0 to 31 do
    begin
      var E: TInputElement;
      E.Kind := TInputElementKind.Button;
      E.Code := Code;
      E.Name := MouseElementName(E.Kind, Code);
      Result.Elements := Result.Elements + [E];
    end;
    for var Code := 0 to 3 do
    begin
      var E: TInputElement;
      E.Kind := TInputElementKind.RelativeAxis;
      E.Code := Code;
      E.Name := MouseElementName(E.Kind, Code);
      Result.Elements := Result.Elements + [E];
    end;
  end;
end;

procedure TInputBackend.RefreshIfNeeded;
begin
  Refresh;
end;

procedure TInputBackend.Reset;
begin
  StopRumble;
end;

function TInputBackend.SetRumble(const DeviceId: string; LowFrequency, HighFrequency: Word;
  DurationMs: UInt16): Boolean;
begin
  Result := False;
end;

procedure TInputBackend.StopRumble(const DeviceId: string);
begin
end;

function TInputBackend.RawDevices: TArray<TInputDevice>;
begin
  Result := Copy(FDevices);
  for var i := 0 to High(Result) do
    Result[i].Elements := Copy(Result[i].Elements);
end;

destructor TInputBackend.Destroy;
begin
  FPublishedIds.Free;
  inherited;
end;

function TInputBackend.PublishedDevicesCurrent: Boolean;
begin
  Result := False;
  if not FPublishedValid or (FPublishedMode <> DeviceListMode) or
    (Length(FPublishedSources) <> Length(FDevices)) then
    Exit;
  // Backends can replace snapshots or update availability in place. Compare
  // their contents so hotplug, errors and mutable element lists stay current.
  for var I := 0 to High(FDevices) do
  begin
    if (FDevices[I].Id <> FPublishedSources[I].Id) or
      (FDevices[I].Name <> FPublishedSources[I].Name) or
      (FDevices[I].Serial <> FPublishedSources[I].Serial) or
      (FDevices[I].Error <> FPublishedSources[I].Error) or
      (FDevices[I].PhysicalId <> FPublishedSources[I].PhysicalId) or
      (FDevices[I].IsVirtual <> FPublishedSources[I].IsVirtual) or
      (FDevices[I].IsAuxiliary <> FPublishedSources[I].IsAuxiliary) or
      (FDevices[I].Kind <> FPublishedSources[I].Kind) or
      (FDevices[I].VendorId <> FPublishedSources[I].VendorId) or
      (FDevices[I].ProductId <> FPublishedSources[I].ProductId) or
      (FDevices[I].Available <> FPublishedSources[I].Available) or
      (FDevices[I].RumbleSupported <> FPublishedSources[I].RumbleSupported) or
      (Length(FDevices[I].Elements) <> Length(FPublishedSources[I].Elements)) then
      Exit;
    for var J := 0 to High(FDevices[I].Elements) do
      if (FDevices[I].Elements[J].Kind <> FPublishedSources[I].Elements[J].Kind) or
        (FDevices[I].Elements[J].Code <> FPublishedSources[I].Elements[J].Code) or
        (FDevices[I].Elements[J].Name <> FPublishedSources[I].Elements[J].Name) then
        Exit;
  end;
  Result := True;
end;

procedure TInputBackend.EnsurePublishedDevices;
begin
  if PublishedDevicesCurrent then
    Exit;
  FPublishedValid := False;
  FPublishedDevices := BuildPublishedDevices;
  if FPublishedIds = nil then
    FPublishedIds := TDictionary<string, string>.Create;
  FPublishedIds.Clear;
  for var Device in FDevices do
    for var Visible in FPublishedDevices do
      if Visible.Id = InputDeviceId(Device, DeviceListMode) then
        FPublishedIds.AddOrSetValue(Device.Id, Visible.Id);
  FPublishedSources := RawDevices;
  FPublishedMode := DeviceListMode;
  FPublishedValid := True;
end;

function TInputBackend.Devices: TArray<TInputDevice>;
begin
  EnsurePublishedDevices;
  // Public snapshots must not let callers modify the cache.
  Result := Copy(FPublishedDevices);
  for var I := 0 to High(Result) do
    Result[I].Elements := Copy(Result[I].Elements);
end;

function TInputBackend.BuildPublishedDevices: TArray<TInputDevice>;
const
  Order: array[0..2] of TInputDeviceKind = (TInputDeviceKind.Keyboard, TInputDeviceKind.Mouse, TInputDeviceKind.Controller);
begin
  Result := nil;
  for var Kind in Order do
  begin
    var Present := Kind = TInputDeviceKind.Controller;
    if not Present then
      for var Source in FDevices do
        if (Source.Kind = Kind) and IsGamingInputDevice(Source) then
          Present := True;
    if not Present then
      Continue;
    for var Item in FDevices do
    begin
      var Device := Item;
      if Device.Kind <> Kind then
        Continue;
      if (Kind = TInputDeviceKind.Controller) and
        (DeviceListMode = TInputDeviceListMode.Gaming) and not IsGamingInputDevice(Device) then
        Continue;
      Device.Id := InputDeviceId(Device, DeviceListMode);
      if Kind <> TInputDeviceKind.Controller then
      begin
        Device.Name := InputDeviceKindName(Kind);
        Device.PhysicalId := '';
        Device.Serial := '';
        Device.VendorId := 0;
        Device.ProductId := 0;
        Device.IsVirtual := False;
        Device.IsAuxiliary := False;
      end;
      var Index := -1;
      for var I := 0 to High(Result) do
        if Result[I].Id = Device.Id then
        begin
          Index := I;
          Break;
        end;
      if Index < 0 then
      begin
        Device.Elements := Copy(Device.Elements);
        Result := Result + [Device];
        if Device.Available then
          Result[High(Result)].Error := '';
      end
      else
      begin
        Result[Index].RumbleSupported := Result[Index].RumbleSupported or Device.RumbleSupported;
        Result[Index].Available := Result[Index].Available or Device.Available;
        if Result[Index].Available then
          Result[Index].Error := '';
        for var E in Device.Elements do
        begin
          var Found := False;
          for var Existing in Result[Index].Elements do
            if (Existing.Kind = E.Kind) and (Existing.Code = E.Code) then
            begin
              Found := True;
              Break;
            end;
          if not Found then
            Result[Index].Elements := Result[Index].Elements + [E];
        end;
      end;
    end;
  end;
end;

function TInputBackend.PublishValues(const Values: TArray<TInputValue>): TArray<TInputValue>;
begin
  var Indices := TDictionary<string, Integer>.Create;
  var Output := TList<TInputValue>.Create;
  try
    EnsurePublishedDevices;
    for var Item in Values do
    begin
      var Value := Item;
      var Id: string;
      if not FPublishedIds.TryGetValue(Value.DeviceId, Id) then
        Continue;
      Value.DeviceId := Id;
      var Key := InputValueKey(Id, Value.Kind, Value.Code);
      var Index: Integer;
      if not Indices.TryGetValue(Key, Index) then
      begin
        Indices.Add(Key, Output.Count);
        Output.Add(Value);
      end
      else
      begin
        var Existing := Output[Index];
        if Value.Kind = TInputElementKind.RelativeAxis then
          Existing.Value := Existing.Value + Value.Value
        else if Value.Kind in [TInputElementKind.Key, TInputElementKind.Button] then
          Existing.Value := Max(Existing.Value, Value.Value);
        Output[Index] := Existing;
      end;
    end;
    Result := Output.ToArray;
  finally
    Output.Free;
    Indices.Free;
  end;
end;

class function TInputBinding.Create(Action: Integer; const Value: TInputValue): TInputBinding;
begin
  Result.Action := Action;
  Result.DeviceId := Value.DeviceId;
  Result.Kind := Value.Kind;
  Result.Code := Value.Code;
  Result.Direction := 0;
  Result.AxisOrigin := 0;
  if Value.Kind in [TInputElementKind.Axis, TInputElementKind.RelativeAxis] then
    if Value.Value < 0 then
      Result.Direction := -1
    else
      Result.Direction := 1;
  if Value.Kind = TInputElementKind.Hat then
    Result.Direction := Round(Value.Value);
  Result.PressThreshold := 0.65;
  Result.ReleaseThreshold := 0.45;
  if Value.Kind = TInputElementKind.RelativeAxis then
  begin
    Result.PressThreshold := 1;
    if Value.Code in [MouseWheel, MouseHorizontalWheel] then
      Result.PressThreshold := 0.001;
    Result.ReleaseThreshold := 0;
  end;
end;

constructor TInputManager.Create(Backend: TInputBackend; OwnsBackend: Boolean);
begin
  inherited Create;
  if Backend = nil then
    raise EArgumentNilException.Create('Backend');
  FBackend := Backend;
  FOwnsBackend := OwnsBackend;
  FThreadId := TThread.CurrentThread.ThreadID;
  FValues := TDictionary<string, Single>.Create;
  FBlocked := TDictionary<string, Boolean>.Create;
  FCaptureOrigins := TDictionary<string, Single>.Create;
  FBindings := TList<TInputBinding>.Create;
  FActiveBindings := TList<Boolean>.Create;
  FEnabled := True;
  Refresh;
  Poll;
end;

destructor TInputManager.Destroy;
begin
  if FBackend <> nil then FBackend.StopRumble;
  FActiveBindings.Free;
  FBindings.Free;
  FCaptureOrigins.Free;
  FBlocked.Free;
  FValues.Free;
  if FOwnsBackend then
    FBackend.Free;
  inherited;
end;

procedure TInputManager.CheckThread;
begin
  if TThread.CurrentThread.ThreadID <> FThreadId then
    raise EInvalidOperation.Create('FMXInput must be called on its creation thread');
end;

procedure TInputManager.Refresh;
begin
  CheckThread;
  FBackend.Refresh;
  FLastRefresh := TThread.GetTickCount64;
end;

procedure TInputManager.SetEnabled(Value: Boolean);
begin
  CheckThread;
  if FEnabled = Value then
    Exit;
  FEnabled := Value;
  FValues.Clear;
  FCurrentValues := nil;
  for var i := 0 to FActiveBindings.Count - 1 do
    FActiveBindings[i] := False;
  CancelCapture;
  FBackend.StopRumble;
  FBackend.Reset;
end;

function TInputManager.BindingPressed(const Binding: TInputBinding; WasPressed: Boolean): Boolean;
var
  Value: Single;
begin
  if not FValues.TryGetValue(InputValueKey(Binding.DeviceId, Binding.Kind, Binding.Code), Value) then
    Exit(False);
  case Binding.Kind of
    TInputElementKind.RelativeAxis:
      Result := Value * Binding.Direction >= Binding.PressThreshold;
    TInputElementKind.Axis:
      begin
        var Travel := 1.0 - Binding.AxisOrigin * Binding.Direction;
        if Travel <= 0 then
          Exit(False);
        Value := (Value - Binding.AxisOrigin) * Binding.Direction / Travel;
        if WasPressed then
          Result := Value >= Binding.ReleaseThreshold
        else
          Result := Value >= Binding.PressThreshold;
      end;
    TInputElementKind.Hat:
      // Diagonals also activate both neighbouring cardinal directions.
      Result := (Round(Value) >= 0) and
        ((Round(Value) = Binding.Direction) or
        (((Binding.Direction and 1) = 0) and
        (((Round(Value) + 1) mod 8 = Binding.Direction) or
        ((Round(Value) + 7) mod 8 = Binding.Direction))));
  else
    Result := Value > 0.5;
  end;
end;

procedure TInputManager.Poll;
begin
  CheckThread;
  if TThread.GetTickCount64 - FLastRefresh >= 1000 then
  begin
    FBackend.RefreshIfNeeded;
    FLastRefresh := TThread.GetTickCount64;
  end;
  var Values := FBackend.Poll;
  FValues.Clear;
  if not FEnabled then
    Exit;
  FCurrentValues := Copy(Values);
  var Candidate: Boolean;
  for var V in Values do
  begin
    var Key := InputValueKey(V.DeviceId, V.Kind, V.Code);
    FValues.AddOrSetValue(Key, V.Value);
    if not FCapturing or ((FCaptureDevice <> '') and (FCaptureDevice <> V.DeviceId)) then
      Continue;
    case V.Kind of
      TInputElementKind.RelativeAxis:
        if V.Code in [MouseX, MouseY] then
          Candidate := FCapturePointerMotion and (Abs(V.Value) >= 1)
        else
          Candidate := Abs(V.Value) >= 0.001;
      TInputElementKind.Axis:
        begin
          var Origin: Single := 0;
          FCaptureOrigins.TryGetValue(Key, Origin);
          var Delta := V.Value - Origin;
          var Direction := 1;
          if Delta < 0 then
            Direction := -1;
          Candidate := (1.0 - Origin * Direction > 0) and
            (Abs(Delta) >= 0.65 * (1.0 - Origin * Direction));
        end;
      TInputElementKind.Hat:
        Candidate := V.Value >= 0;
    else
      Candidate := V.Value > 0.5;
    end;
    if FBlocked.ContainsKey(Key) then
    begin
      // Held controls must return to neutral before they can be captured.
      if ((V.Kind = TInputElementKind.Axis) and (Abs(V.Value) <= 0.25)) or
        ((V.Kind = TInputElementKind.Hat) and (V.Value < 0)) or
        ((V.Kind in [TInputElementKind.Key, TInputElementKind.Button]) and not Candidate) then
        FBlocked.Remove(Key);
      Continue;
    end;
    if Candidate then
    begin
      FCaptured := TInputBinding.Create(FCaptureAction, V);
      if V.Kind = TInputElementKind.Axis then
      begin
        FCaptureOrigins.TryGetValue(Key, FCaptured.AxisOrigin);
        if V.Value < FCaptured.AxisOrigin then
          FCaptured.Direction := -1
        else
          FCaptured.Direction := 1;
      end;
      FHasCaptured := True;
      FCapturing := False;
    end;
  end;
  // Sparse snapshots omit released keys/buttons.
  for var BlockedKey in FBlocked.Keys.ToArray do
    if not FValues.ContainsKey(BlockedKey) then
      FBlocked.Remove(BlockedKey);
  for var i := 0 to FBindings.Count - 1 do
    FActiveBindings[i] := BindingPressed(FBindings[i], FActiveBindings[i]);
end;

function TInputManager.SetRumble(const DeviceId: string; LowFrequency, HighFrequency: Word;
  DurationMs: UInt16): Boolean;
begin
  CheckThread;
  Result := False;
  if DeviceId = '' then Exit; // Never interpret a missing target as every controller.
  if (DurationMs = 0) or ((LowFrequency = 0) and (HighFrequency = 0)) then
    Exit(FBackend.SetRumble(DeviceId, LowFrequency, HighFrequency, DurationMs));
  if not FEnabled or FCapturing then Exit;
  for var Device in FBackend.Devices do
    if (Device.Id = DeviceId) and Device.Available and Device.RumbleSupported then
      Exit(FBackend.SetRumble(DeviceId, LowFrequency, HighFrequency, DurationMs));
end;

procedure TInputManager.StopRumble(const DeviceId: string);
begin
  CheckThread;
  FBackend.StopRumble(DeviceId);
end;

procedure TInputManager.ClearBindings;
begin
  CheckThread;
  FBackend.StopRumble;
  FBindings.Clear;
  FActiveBindings.Clear;
end;

procedure ValidateBinding(const Binding: TInputBinding);
begin
  if (Binding.DeviceId = '') or (Binding.Code < 0) or
    (Ord(Binding.Kind) < Ord(Low(TInputElementKind))) or
    (Ord(Binding.Kind) > Ord(High(TInputElementKind))) or
    IsNan(Binding.PressThreshold) or IsInfinite(Binding.PressThreshold) or
    IsNan(Binding.ReleaseThreshold) or IsInfinite(Binding.ReleaseThreshold) or
    (Binding.ReleaseThreshold < 0) or (Binding.ReleaseThreshold >= Binding.PressThreshold) or
    (Binding.PressThreshold > 1) or
    IsNan(Binding.AxisOrigin) or IsInfinite(Binding.AxisOrigin) or
    (Abs(Binding.AxisOrigin) > 1) or
    ((Binding.Kind = TInputElementKind.Axis) and (Binding.AxisOrigin * Binding.Direction >= 1)) or
    ((Binding.Kind = TInputElementKind.Axis) and (Binding.Direction <> -1) and (Binding.Direction <> 1)) or
    ((Binding.Kind = TInputElementKind.RelativeAxis) and (Binding.Direction <> -1) and (Binding.Direction <> 1)) or
    ((Binding.Kind = TInputElementKind.Hat) and ((Binding.Direction < 0) or (Binding.Direction > 7))) then
    raise EArgumentException.Create('Invalid input binding');
end;

procedure TInputManager.AddBinding(const Binding: TInputBinding);
begin
  CheckThread;
  ValidateBinding(Binding);
  FBindings.Add(Binding);
  FActiveBindings.Add(BindingPressed(Binding, False));
end;

function TInputManager.Bindings: TArray<TInputBinding>;
begin
  CheckThread;
  Result := FBindings.ToArray;
end;

procedure TInputManager.RemoveBindings(Action: Integer);
begin
  CheckThread;
  FBackend.StopRumble;
  for var i := FBindings.Count - 1 downto 0 do
    if FBindings[i].Action = Action then
    begin
      FBindings.Delete(i);
      FActiveBindings.Delete(i);
    end;
end;

function TInputManager.Values: TArray<TInputValue>;
begin
  CheckThread;
  Result := Copy(FCurrentValues);
end;

function TInputManager.Devices: TArray<TInputDevice>;
begin
  CheckThread;
  Result := FBackend.Devices;
end;

function TInputManager.IsPressed(Action: Integer): Boolean;
begin
  CheckThread;
  Result := False;
  for var i := 0 to FBindings.Count - 1 do
    if (FBindings[i].Action = Action) and FActiveBindings[i] then
      Exit(True);
end;

procedure TInputManager.BeginCapture(Action: Integer; const DeviceId: string; IncludePointerMotion: Boolean);
begin
  CheckThread;
  if not FEnabled then
    raise EInvalidOperation.Create('Input is disabled');
  CancelCapture;
  FBackend.StopRumble;
  Poll;
  var Values := FCurrentValues;
  for var V in Values do
  begin
    var Key := InputValueKey(V.DeviceId, V.Kind, V.Code);
    if V.Kind = TInputElementKind.Axis then
    begin
      var Origin: Single := 0;
      if V.Value <= -0.9 then
        Origin := -1
      else if V.Value >= 0.9 then
        Origin := 1;
      FCaptureOrigins.AddOrSetValue(Key, Origin);
      if (Origin = 0) and (Abs(V.Value) > 0.25) then
        FBlocked.AddOrSetValue(Key, True);
    end
    else if ((V.Kind = TInputElementKind.Hat) and (V.Value >= 0)) or
      ((V.Kind in [TInputElementKind.Key, TInputElementKind.Button]) and (V.Value > 0.5)) then
      FBlocked.AddOrSetValue(Key, True);
  end;
  FCaptureAction := Action;
  FCaptureDevice := DeviceId;
  FCapturePointerMotion := IncludePointerMotion;
  FCapturing := True;
end;

procedure TInputManager.CancelCapture;
begin
  CheckThread;
  FCapturing := False;
  FHasCaptured := False;
  FBlocked.Clear;
  FCaptureOrigins.Clear;
end;

function TInputManager.TakeCaptured(out Binding: TInputBinding): Boolean;
begin
  CheckThread;
  Result := FHasCaptured;
  if Result then
    Binding := FCaptured
  else
    Binding := Default(TInputBinding);
  FHasCaptured := False;
end;

procedure TInputManager.SaveBindings(Stream: TStream);
begin
  CheckThread;
  var Root := TJSONObject.Create;
  try
    Root.AddPair('version', TJSONNumber.Create(1));
    var Items := TJSONArray.Create;
    Root.AddPair('bindings', Items);
    for var B in FBindings do
    begin
      var Item := TJSONObject.Create;
      Items.AddElement(Item);
      Item.AddPair('action', TJSONNumber.Create(B.Action));
      Item.AddPair('device', B.DeviceId);
      Item.AddPair('kind', TJSONNumber.Create(Ord(B.Kind)));
      Item.AddPair('code', TJSONNumber.Create(B.Code));
      Item.AddPair('direction', TJSONNumber.Create(B.Direction));
      Item.AddPair('origin', TJSONNumber.Create(B.AxisOrigin));
      Item.AddPair('press', TJSONNumber.Create(B.PressThreshold));
      Item.AddPair('release', TJSONNumber.Create(B.ReleaseThreshold));
    end;
    var Bytes := TEncoding.UTF8.GetBytes(Root.ToJSON);
    if Length(Bytes) > 0 then
      Stream.WriteBuffer(Bytes[0], Length(Bytes));
  finally
    Root.Free;
  end;
end;

procedure TInputManager.LoadBindings(Stream: TStream);
begin
  CheckThread;
  if (Stream.Size - Stream.Position < 0) or (Stream.Size - Stream.Position > 1024 * 1024) then
    raise EReadError.Create('Input profile is too large');
  var Bytes: TBytes;
  SetLength(Bytes, Stream.Size - Stream.Position);
  if Length(Bytes) > 0 then
    Stream.ReadBuffer(Bytes[0], Length(Bytes));
  var Json := TJSONObject.ParseJSONValue(TEncoding.UTF8.GetString(Bytes));
  var Pending := TList<TInputBinding>.Create;
  try
    if not (Json is TJSONObject) then
      raise EReadError.Create('Invalid input profile');
    var Root := TJSONObject(Json);
    if Root.GetValue<Integer>('version') <> 1 then
      raise EReadError.Create('Unknown input profile version');
    var Items := Root.GetValue<TJSONArray>('bindings');
    if Items = nil then
      raise EReadError.Create('Missing bindings');
    for var Item in Items do
    begin
      if not (Item is TJSONObject) then
        raise EReadError.Create('Invalid binding');
      var Obj := TJSONObject(Item);
      var Kind := Obj.GetValue<Integer>('kind');
      if (Kind < Ord(Low(TInputElementKind))) or (Kind > Ord(High(TInputElementKind))) then
        raise EReadError.Create('Invalid element kind');
      var B: TInputBinding;
      B.Action := Obj.GetValue<Integer>('action');
      B.DeviceId := Obj.GetValue<string>('device');
      B.Kind := TInputElementKind(Kind);
      B.Code := Obj.GetValue<Integer>('code');
      B.Direction := Obj.GetValue<Integer>('direction');
      B.AxisOrigin := Obj.GetValue<Double>('origin');
      B.PressThreshold := Obj.GetValue<Double>('press');
      B.ReleaseThreshold := Obj.GetValue<Double>('release');
      ValidateBinding(B);
      Pending.Add(B);
    end;
    ClearBindings;
    for var B in Pending do
      AddBinding(B);
  finally
    Pending.Free;
    Json.Free;
  end;
end;

end.

