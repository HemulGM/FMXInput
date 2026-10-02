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
  end;
{$ENDIF}

implementation

{$IF Defined(LINUX) and not Defined(ANDROID)}

uses
  System.SysUtils, System.Classes, System.IOUtils, System.Generics.Collections;

function EvOpen(Path: MarshaledAString; Flags: Integer): Integer; cdecl; external 'libc.so.6' name 'open';

function EvClose(Fd: Integer): Integer; cdecl; external 'libc.so.6' name 'close';

function EvIoctl(Fd: Integer; Request: NativeUInt; Data: Pointer): Integer; cdecl; external 'libc.so.6' name 'ioctl';

type
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
    constructor Create;
    destructor Destroy; override;
  end;

function ReadRequest(Number, Size: Cardinal): NativeUInt;
begin
  Result := NativeUInt($80000000) or (NativeUInt(Size) shl 16) or ($45 shl 8) or Number;
end;

function BitSet(const Bits: TBytes; Code: Integer): Boolean;
begin
  Result := (Code >= 0) and (Code div 8 < Length(Bits)) and
    ((Bits[Code div 8] and (1 shl (Code mod 8))) <> 0);
end;

function SysText(const Path: string): string;
begin
  Result := '';
  try
    if TFile.Exists(Path) then
      Result := TFile.ReadAllText(Path).Trim;
  except
    on E: EInOutError do
      Result := '';
    on E: EFOpenError do
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
  Devices.Free;
  inherited;
end;

constructor TLinuxInputBackend.Create;
begin
  inherited;
  FImpl := TLinuxState.Create;
end;

destructor TLinuxInputBackend.Destroy;
begin
  FImpl.Free;
  inherited;
end;

procedure TLinuxInputBackend.Refresh;
begin
  var State := TLinuxState(FImpl);
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
    var IsKeyboard := BitSet(Keys, 30) and BitSet(Keys, 16); // A and Q positions
    var IsController := False;
    for var Code := $120 to $13F do
      if BitSet(Keys, Code) then
        IsController := True;
    if not IsKeyboard and not IsController then
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
      if IsKeyboard then
        Device.Info.Kind := TInputDeviceKind.Keyboard
      else
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
    end;
    Device.Info.Available := Device.Fd >= 0;
    if not Device.Info.Available then
      Device.Info.Error := 'Cannot open ' + NativePath + '; check session/device permissions'
    else
      Device.Info.Error := '';
  end;
  FDevices := nil;
  for var Device in State.Devices do
    FDevices := FDevices + [Device.Info];
end;

function TLinuxInputBackend.Poll: TArray<TInputValue>;
begin
  var Values := TList<TInputValue>.Create;
  try
    FDevices := nil;
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
    Result := Values.ToArray;
  finally
    Values.Free;
  end;
end;
{$ENDIF}

end.

