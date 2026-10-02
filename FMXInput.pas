unit FMXInput;

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections;

{$SCOPEDENUMS ON}

type
  TInputDeviceKind = (Keyboard, Controller);
  TInputElementKind = (Key, Button, Axis, Hat);

  TInputElement = record
    Kind: TInputElementKind;
    Code: Integer;
    Name: string;
    // Axis values are normalized to [-1, 1]. Hat values are -1 (neutral)
    // or clockwise directions 0..7, starting at up. Keys use USB HID usages.
  end;

  TInputDevice = record
    Id, Name, Serial, Error: string;
    Kind: TInputDeviceKind;
    VendorId, ProductId: Word;
    Available: Boolean;
    Elements: TArray<TInputElement>;
  end;

  TInputValue = record
    DeviceId: string;
    Kind: TInputElementKind;
    Code: Integer;
    Value: Single;
    class function Create(const DeviceId: string; Kind: TInputElementKind;
      Code: Integer; Value: Single): TInputValue; static;
  end;

  // Backends return complete current snapshots, not only changed values.
  // Missing values mean released/neutral. Calls must use the creation thread.
  TInputBackend = class abstract
  protected
    FDevices: TArray<TInputDevice>;
  public
    procedure Refresh; virtual; abstract;
    function Poll: TArray<TInputValue>; virtual; abstract;
    procedure Reset; virtual;
    function Devices: TArray<TInputDevice>;
  end;

  TInputBinding = record
    Action: Integer; // Opaque application-defined action, e.g. player 2 / A.
    DeviceId: string;
    Kind: TInputElementKind;
    Code: Integer;
    Direction: Integer; // Axis: -1/+1. Hat: 0..7. Key/button: ignored.
    AxisOrigin: Single; // Rest position: 0 for sticks, often -1/+1 for triggers.
    PressThreshold, ReleaseThreshold: Single;
    class function Create(Action: Integer; const Value: TInputValue): TInputBinding; static;
  end;

  TInputManager = class
  private
    FBackend: TInputBackend;
    FOwnsBackend, FEnabled, FCapturing: Boolean;
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
    procedure ClearBindings;
    procedure AddBinding(const Binding: TInputBinding);
    procedure RemoveBindings(Action: Integer);
    function Bindings: TArray<TInputBinding>;
    function Devices: TArray<TInputDevice>;
    function Values: TArray<TInputValue>;
    function IsPressed(Action: Integer): Boolean;
    procedure BeginCapture(Action: Integer; const DeviceId: string = '');
    procedure CancelCapture;
    function TakeCaptured(out Binding: TInputBinding): Boolean;
    procedure SaveBindings(Stream: TStream);
    procedure LoadBindings(Stream: TStream);
    property Enabled: Boolean read FEnabled write SetEnabled;
    property Capturing: Boolean read FCapturing;
  end;

// Native factory is desktop-only. No window/framework/RetroMul dependencies.
function CreateFMXInputBackend: TInputBackend;
function InputValueKey(const DeviceId: string; Kind: TInputElementKind; Code: Integer): string;
function NormalizeAxis(Value, Minimum, Maximum: Int64): Single;
function ScanCodeToHid(ScanCode: Word; Extended: Boolean): Word;
function LinuxKeyToHid(Code: Word): Word;
function InputKeyName(Code: Integer): string;

implementation

uses
  System.Math, System.JSON,
  {$IF Defined(MSWINDOWS)}
  FMXInput.Windows;
  {$ELSEIF Defined(LINUX) and not Defined(ANDROID)}
  FMXInput.Linux;
  {$ELSEIF Defined(MACOS) and not Defined(IOS)}
  FMXInput.MacOS;
  {$ELSE}
  System.Types;
  {$ENDIF}

function CreateFMXInputBackend: TInputBackend;
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
end;

function InputValueKey(const DeviceId: string; Kind: TInputElementKind; Code: Integer): string;
begin
  Result := IntToStr(Length(DeviceId)) + ':' + DeviceId + ':' +
    IntToStr(Ord(Kind)) + ':' + IntToStr(Code);
end;

function NormalizeAxis(Value, Minimum, Maximum: Int64): Single;
begin
  if Maximum <= Minimum then Exit(0);
  Result := EnsureRange(2.0 * (Double(Value) - Double(Minimum)) /
    (Double(Maximum) - Double(Minimum)) - 1.0, -1.0, 1.0);
end;

function ScanCodeToHid(ScanCode: Word; Extended: Boolean): Word;
const
  // PC set-1 make codes 0..88 -> USB keyboard usage IDs. Independent of layout.
  Codes: array[0..88] of Byte = (
    0,41,30,31,32,33,34,35,36,37,38,39,45,46,42,43,
    20,26,8,21,23,28,24,12,18,19,47,48,40,224,4,22,
    7,9,10,11,13,14,15,51,52,53,225,49,29,27,6,25,
    5,17,16,54,55,56,229,85,226,44,57,58,59,60,61,62,
    63,64,65,66,67,83,71,95,96,97,86,92,93,94,87,89,
    90,91,98,99,0,0,100,68,69);
begin
  if Extended then
    case ScanCode of
      $1C: Exit(88); $1D: Exit(228); $35: Exit(84); $37: Exit(70);
      $38: Exit(230); $47: Exit(74); $48: Exit(82); $49: Exit(75);
      $4B: Exit(80); $4D: Exit(79); $4F: Exit(77); $50: Exit(81);
      $51: Exit(78); $52: Exit(73); $53: Exit(76);
      $5B: Exit(227); $5C: Exit(231); $5D: Exit(101);
      else Exit(0);
    end;
  if ScanCode <= High(Codes) then Result := Codes[ScanCode] else Result := 0;
end;

function LinuxKeyToHid(Code: Word): Word;
begin
  if Code <= 88 then Exit(ScanCodeToHid(Code, False));
  case Code of
    96: Result := 88; 97: Result := 228; 98: Result := 84;
    99: Result := 70; 100: Result := 230; 102: Result := 74;
    103: Result := 82; 104: Result := 75; 105: Result := 80;
    106: Result := 79; 107: Result := 77; 108: Result := 81;
    109: Result := 78; 110: Result := 73; 111: Result := 76;
    119: Result := 72; 125: Result := 227; 126: Result := 231;
    127: Result := 101;
    else Result := 0;
  end;
end;

class function TInputValue.Create(const DeviceId: string; Kind: TInputElementKind;
  Code: Integer; Value: Single): TInputValue;
begin
  Result.DeviceId := DeviceId; Result.Kind := Kind;
  Result.Code := Code; Result.Value := Value;
end;

function InputKeyName(Code: Integer): string;
begin
  if (Code >= 4) and (Code <= 29) then Exit(Char(Ord('A') + Code - 4));
  if (Code >= 30) and (Code <= 38) then Exit(IntToStr(Code - 29));
  if (Code >= 58) and (Code <= 69) then Exit('F' + IntToStr(Code - 57));
  case Code of
    39: Result := '0'; 40: Result := 'Enter'; 41: Result := 'Escape';
    42: Result := 'Backspace'; 43: Result := 'Tab'; 44: Result := 'Space';
    45: Result := '-'; 46: Result := '='; 47: Result := '['; 48: Result := ']';
    49: Result := '\'; 51: Result := ';'; 52: Result := ''''; 53: Result := '`';
    54: Result := ','; 55: Result := '.'; 56: Result := '/'; 57: Result := 'Caps Lock';
    70: Result := 'Print Screen'; 71: Result := 'Scroll Lock'; 72: Result := 'Pause';
    73: Result := 'Insert'; 74: Result := 'Home'; 75: Result := 'Page Up';
    76: Result := 'Delete'; 77: Result := 'End'; 78: Result := 'Page Down';
    79: Result := 'Right'; 80: Result := 'Left'; 81: Result := 'Down'; 82: Result := 'Up';
    83: Result := 'Num Lock'; 84: Result := 'Keypad /'; 85: Result := 'Keypad *';
    86: Result := 'Keypad -'; 87: Result := 'Keypad +'; 88: Result := 'Keypad Enter';
    89..97: Result := 'Keypad ' + IntToStr(Code - 88);
    98: Result := 'Keypad 0'; 99: Result := 'Keypad .'; 100: Result := 'ISO extra key';
    101: Result := 'Menu'; 224: Result := 'Left Ctrl'; 225: Result := 'Left Shift';
    226: Result := 'Left Alt'; 227: Result := 'Left Meta'; 228: Result := 'Right Ctrl';
    229: Result := 'Right Shift'; 230: Result := 'Right Alt'; 231: Result := 'Right Meta';
    else Result := 'HID key ' + IntToStr(Code);
  end;
end;

procedure TInputBackend.Reset;
begin
end;

function TInputBackend.Devices: TArray<TInputDevice>;
begin
  Result := Copy(FDevices);
  for var I := 0 to High(Result) do Result[I].Elements := Copy(Result[I].Elements);
end;

class function TInputBinding.Create(Action: Integer; const Value: TInputValue): TInputBinding;
begin
  Result.Action := Action; Result.DeviceId := Value.DeviceId;
  Result.Kind := Value.Kind; Result.Code := Value.Code;
  Result.Direction := 0;
  Result.AxisOrigin := 0;
  if Value.Kind = TInputElementKind.Axis then
    if Value.Value < 0 then Result.Direction := -1 else Result.Direction := 1;
  if Value.Kind = TInputElementKind.Hat then Result.Direction := Round(Value.Value);
  Result.PressThreshold := 0.65; Result.ReleaseThreshold := 0.45;
end;

constructor TInputManager.Create(Backend: TInputBackend; OwnsBackend: Boolean);
begin
  inherited Create;
  if Backend = nil then raise EArgumentNilException.Create('Backend');
  FBackend := Backend; FOwnsBackend := OwnsBackend;
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
  FActiveBindings.Free; FBindings.Free; FCaptureOrigins.Free; FBlocked.Free; FValues.Free;
  if FOwnsBackend then FBackend.Free;
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
  if FEnabled = Value then Exit;
  FEnabled := Value;
  FValues.Clear;
  FCurrentValues := nil;
  for var I := 0 to FActiveBindings.Count - 1 do FActiveBindings[I] := False;
  CancelCapture;
  FBackend.Reset;
end;

function TInputManager.BindingPressed(const Binding: TInputBinding; WasPressed: Boolean): Boolean;
var
  Value: Single;
begin
  if not FValues.TryGetValue(InputValueKey(Binding.DeviceId, Binding.Kind, Binding.Code), Value) then
    Exit(False);
  case Binding.Kind of
    TInputElementKind.Axis:
      begin
        var Travel := 1.0 - Binding.AxisOrigin * Binding.Direction;
        if Travel <= 0 then Exit(False);
        Value := (Value - Binding.AxisOrigin) * Binding.Direction / Travel;
        if WasPressed then Result := Value >= Binding.ReleaseThreshold
        else Result := Value >= Binding.PressThreshold;
      end;
    TInputElementKind.Hat:
      // Diagonals also activate both neighbouring cardinal directions.
      Result := (Round(Value) >= 0) and
        ((Round(Value) = Binding.Direction) or
        (((Binding.Direction and 1) = 0) and
        (((Round(Value) + 1) mod 8 = Binding.Direction) or
         ((Round(Value) + 7) mod 8 = Binding.Direction))));
    else Result := Value > 0.5;
  end;
end;

procedure TInputManager.Poll;
var
  Key: string;
  Candidate: Boolean;
begin
  CheckThread;
  if TThread.GetTickCount64 - FLastRefresh >= 1000 then Refresh;
  var Values := FBackend.Poll;
  FValues.Clear;
  if not FEnabled then Exit;
  FCurrentValues := Copy(Values);
  for var V in Values do
  begin
    Key := InputValueKey(V.DeviceId, V.Kind, V.Code);
    FValues.AddOrSetValue(Key, V.Value);
    if not FCapturing or ((FCaptureDevice <> '') and (FCaptureDevice <> V.DeviceId)) then Continue;
    case V.Kind of
      TInputElementKind.Axis:
        begin
          var Origin: Single := 0;
          FCaptureOrigins.TryGetValue(Key, Origin);
          var Delta := V.Value - Origin;
          var Direction := 1;
          if Delta < 0 then Direction := -1;
          Candidate := (1.0 - Origin * Direction > 0) and
            (Abs(Delta) >= 0.65 * (1.0 - Origin * Direction));
        end;
      TInputElementKind.Hat: Candidate := V.Value >= 0;
      else Candidate := V.Value > 0.5;
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
        if V.Value < FCaptured.AxisOrigin then FCaptured.Direction := -1
        else FCaptured.Direction := 1;
      end;
      FHasCaptured := True; FCapturing := False;
    end;
  end;
  // Sparse snapshots omit released keys/buttons.
  for var BlockedKey in FBlocked.Keys.ToArray do
    if not FValues.ContainsKey(BlockedKey) then FBlocked.Remove(BlockedKey);
  for var I := 0 to FBindings.Count - 1 do
    FActiveBindings[I] := BindingPressed(FBindings[I], FActiveBindings[I]);
end;

procedure TInputManager.ClearBindings;
begin
  CheckThread; FBindings.Clear; FActiveBindings.Clear;
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
    ((Binding.Kind = TInputElementKind.Hat) and ((Binding.Direction < 0) or (Binding.Direction > 7))) then
    raise EArgumentException.Create('Invalid input binding');
end;

procedure TInputManager.AddBinding(const Binding: TInputBinding);
begin
  CheckThread;
  ValidateBinding(Binding);
  FBindings.Add(Binding); FActiveBindings.Add(False);
end;

function TInputManager.Bindings: TArray<TInputBinding>;
begin
  CheckThread; Result := FBindings.ToArray;
end;

procedure TInputManager.RemoveBindings(Action: Integer);
begin
  CheckThread;
  for var I := FBindings.Count - 1 downto 0 do
    if FBindings[I].Action = Action then
    begin FBindings.Delete(I); FActiveBindings.Delete(I); end;
end;

function TInputManager.Values: TArray<TInputValue>;
begin
  CheckThread; Result := Copy(FCurrentValues);
end;

function TInputManager.Devices: TArray<TInputDevice>;
begin
  CheckThread; Result := FBackend.Devices;
end;

function TInputManager.IsPressed(Action: Integer): Boolean;
begin
  CheckThread;
  Result := False;
  for var I := 0 to FBindings.Count - 1 do
    if (FBindings[I].Action = Action) and FActiveBindings[I] then Exit(True);
end;

procedure TInputManager.BeginCapture(Action: Integer; const DeviceId: string);
begin
  CheckThread;
  if not FEnabled then raise EInvalidOperation.Create('Input is disabled');
  CancelCapture;
  Poll;
  var Values := FBackend.Poll;
  for var V in Values do
  begin
    var Key := InputValueKey(V.DeviceId, V.Kind, V.Code);
    if V.Kind = TInputElementKind.Axis then
    begin
      var Origin: Single := 0;
      if V.Value <= -0.9 then Origin := -1 else if V.Value >= 0.9 then Origin := 1;
      FCaptureOrigins.AddOrSetValue(Key, Origin);
      if (Origin = 0) and (Abs(V.Value) > 0.25) then FBlocked.AddOrSetValue(Key, True);
    end
    else if ((V.Kind = TInputElementKind.Hat) and (V.Value >= 0)) or
      ((V.Kind <> TInputElementKind.Hat) and (V.Value > 0.5)) then
      FBlocked.AddOrSetValue(Key, True);
  end;
  FCaptureAction := Action; FCaptureDevice := DeviceId; FCapturing := True;
end;

procedure TInputManager.CancelCapture;
begin
  CheckThread;
  FCapturing := False; FHasCaptured := False; FBlocked.Clear; FCaptureOrigins.Clear;
end;

function TInputManager.TakeCaptured(out Binding: TInputBinding): Boolean;
begin
  CheckThread; Result := FHasCaptured;
  if Result then Binding := FCaptured else Binding := Default(TInputBinding);
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
    if Length(Bytes) > 0 then Stream.WriteBuffer(Bytes[0], Length(Bytes));
  finally Root.Free; end;
end;

procedure TInputManager.LoadBindings(Stream: TStream);
begin
  CheckThread;
  if (Stream.Size - Stream.Position < 0) or (Stream.Size - Stream.Position > 1024 * 1024) then
    raise EReadError.Create('Input profile is too large');
  var Bytes: TBytes;
  SetLength(Bytes, Stream.Size - Stream.Position);
  if Length(Bytes) > 0 then Stream.ReadBuffer(Bytes[0], Length(Bytes));
  var Json := TJSONObject.ParseJSONValue(TEncoding.UTF8.GetString(Bytes));
  var Pending := TList<TInputBinding>.Create;
  try
    if not (Json is TJSONObject) then raise EReadError.Create('Invalid input profile');
    var Root := TJSONObject(Json);
    if Root.GetValue<Integer>('version') <> 1 then raise EReadError.Create('Unknown input profile version');
    var Items := Root.GetValue<TJSONArray>('bindings');
    if Items = nil then raise EReadError.Create('Missing bindings');
    for var Item in Items do
    begin
      if not (Item is TJSONObject) then raise EReadError.Create('Invalid binding');
      var Obj := TJSONObject(Item);
      var Kind := Obj.GetValue<Integer>('kind');
      if (Kind < Ord(Low(TInputElementKind))) or (Kind > Ord(High(TInputElementKind))) then
        raise EReadError.Create('Invalid element kind');
      var B: TInputBinding;
      B.Action := Obj.GetValue<Integer>('action'); B.DeviceId := Obj.GetValue<string>('device');
      B.Kind := TInputElementKind(Kind); B.Code := Obj.GetValue<Integer>('code');
      B.Direction := Obj.GetValue<Integer>('direction');
      B.AxisOrigin := Obj.GetValue<Double>('origin');
      B.PressThreshold := Obj.GetValue<Double>('press'); B.ReleaseThreshold := Obj.GetValue<Double>('release');
      ValidateBinding(B);
      Pending.Add(B);
    end;
    ClearBindings;
    for var B in Pending do AddBinding(B);
  finally Pending.Free; Json.Free; end;
end;

end.
