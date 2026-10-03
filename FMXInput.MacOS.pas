unit FMXInput.MacOS;

interface

uses
  FMXInput;

{$IF Defined(MACOS) and not Defined(IOS)}
type
  TMacOSInputBackend = class(TInputBackend)
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

{$IF Defined(MACOS) and not Defined(IOS)}

uses
  System.SysUtils, System.Classes, System.Generics.Collections,
  Macapi.CoreFoundation, Macapi.AppKit, Macapi.Foundation, Macapi.ObjectiveC,
  Macapi.CocoaTypes, Posix.Dlfcn;

const
  IOKitLib = '/System/Library/Frameworks/IOKit.framework/IOKit';

function ServiceMatching(Name: MarshaledAString): CFMutableDictionaryRef; cdecl; external IOKitLib name _PU + 'IOServiceMatching';

function MatchingServices(Port: Cardinal; Matching: CFDictionaryRef; out Iterator: Cardinal): Integer; cdecl; external IOKitLib name _PU + 'IOServiceGetMatchingServices';

function IteratorNext(Iterator: Cardinal): Cardinal; cdecl; external IOKitLib name _PU + 'IOIteratorNext';

function ObjectRelease(Obj: Cardinal): Integer; cdecl; external IOKitLib name _PU + 'IOObjectRelease';

function RegistryProperty(Service: Cardinal; Key: CFStringRef; Allocator: Pointer; Options: Cardinal): CFTypeRef; cdecl; external IOKitLib name _PU + 'IORegistryEntryCreateCFProperty';

function BlockCopy(Block: Pointer): Pointer; cdecl; external '/usr/lib/libSystem.B.dylib' name _PU + '_Block_copy';

procedure BlockRelease(Block: Pointer); cdecl; external '/usr/lib/libSystem.B.dylib' name _PU + '_Block_release';

// Public C API declarations; no Objective-C helper or external wrapper needed.
function HIDManagerCreate(Allocator: Pointer; Options: Cardinal): Pointer; cdecl; external IOKitLib name _PU + 'IOHIDManagerCreate';

function HIDManagerOpen(Manager: Pointer; Options: Cardinal): Integer; cdecl; external IOKitLib name _PU + 'IOHIDManagerOpen';

function HIDManagerClose(Manager: Pointer; Options: Cardinal): Integer; cdecl; external IOKitLib name _PU + 'IOHIDManagerClose';

procedure HIDManagerMatch(Manager, Dictionaries: Pointer); cdecl; external IOKitLib name _PU + 'IOHIDManagerSetDeviceMatchingMultiple';

function HIDManagerCopyDevices(Manager: Pointer): CFSetRef; cdecl; external IOKitLib name _PU + 'IOHIDManagerCopyDevices';

procedure HIDManagerSchedule(Manager: Pointer; RunLoop: CFRunLoopRef; Mode: CFStringRef); cdecl; external IOKitLib name _PU + 'IOHIDManagerScheduleWithRunLoop';

procedure HIDManagerUnschedule(Manager: Pointer; RunLoop: CFRunLoopRef; Mode: CFStringRef); cdecl; external IOKitLib name _PU + 'IOHIDManagerUnscheduleFromRunLoop';

function HIDDeviceProperty(Device: Pointer; Key: CFStringRef): CFTypeRef; cdecl; external IOKitLib name _PU + 'IOHIDDeviceGetProperty';

function HIDDeviceOpen(Device: Pointer; Options: Cardinal): Integer; cdecl; external IOKitLib name _PU + 'IOHIDDeviceOpen';

function HIDDeviceCopyElements(Device, Matching: Pointer; Options: Cardinal): CFArrayRef; cdecl; external IOKitLib name _PU + 'IOHIDDeviceCopyMatchingElements';

function HIDDeviceValue(Device, Element: Pointer; out Value: Pointer): Integer; cdecl; external IOKitLib name _PU + 'IOHIDDeviceGetValue';

function HIDElementType(Element: Pointer): Cardinal; cdecl; external IOKitLib name _PU + 'IOHIDElementGetType';

function HIDElementPage(Element: Pointer): Cardinal; cdecl; external IOKitLib name _PU + 'IOHIDElementGetUsagePage';

function HIDElementUsage(Element: Pointer): Cardinal; cdecl; external IOKitLib name _PU + 'IOHIDElementGetUsage';

function HIDElementCookie(Element: Pointer): Cardinal; cdecl; external IOKitLib name _PU + 'IOHIDElementGetCookie';

function HIDElementMinimum(Element: Pointer): NativeInt; cdecl; external IOKitLib name _PU + 'IOHIDElementGetLogicalMin';

function HIDElementMaximum(Element: Pointer): NativeInt; cdecl; external IOKitLib name _PU + 'IOHIDElementGetLogicalMax';

function HIDValueInteger(Value: Pointer): NativeInt; cdecl; external IOKitLib name _PU + 'IOHIDValueGetIntegerValue';

function HIDDeviceService(Device: Pointer): Cardinal; cdecl; external IOKitLib name _PU + 'IOHIDDeviceGetService';

function RegistryId(Service: Cardinal; out Id: UInt64): Integer; cdecl; external IOKitLib name _PU + 'IORegistryEntryGetRegistryEntryID';

type
  TLocalEventClass = interface(NSObjectClass)
    ['{C156BF64-0B0B-4E59-BB77-E09D614BE929}']
    function addLocalMonitorForEventsMatchingMask(Mask: NSUInteger; handler: Pointer): Pointer; cdecl;
    procedure removeMonitor(Monitor: Pointer); cdecl;
  end;

  TLocalEvent = class(TOCGenericImport<TLocalEventClass, NSEvent>);

  TBlockDescriptor = record
    Reserved, Size: NativeUInt;
    Signature: MarshaledAString;
  end;

  PLocalBlock = ^TLocalBlock;

  TLocalBlock = record
    Isa: Pointer;
    Flags, Reserved: Integer;
    Invoke: Pointer;
    Descriptor: ^TBlockDescriptor;
    State: Pointer;
  end;

  TMacElement = record
    Ref: Pointer;
    Info: TInputElement;
    Minimum, Maximum: NativeInt;
  end;

  TMacDevice = class
    Ref: Pointer;
    AllElements: CFArrayRef;
    Elements: TArray<TMacElement>;
    Info: TInputDevice;
    Seen: Boolean;
    destructor Destroy; override;
  end;

  TMacState = class
    Manager: Pointer;
    RunLoop: CFRunLoopRef;
    Devices: TObjectList<TMacDevice>;
    DesktopDevices: TArray<TInputDevice>;
    Keys: array[0..255] of Boolean;
    Buttons: array[0..31] of Boolean;
    Delta: array[0..3] of Single;
    Monitor: Pointer;
    BlockDescriptor: TBlockDescriptor;
    procedure DesktopEvent(Event: NSEvent);
    procedure ResetDesktop;
    procedure RefreshDesktop;
    constructor Create;
    destructor Destroy; override;
  end;

function LocalEventCallback(Block: PLocalBlock; Event: Pointer): Pointer; cdecl;
begin
  Result := Event; // Preserve normal AppKit/FMX dispatch, including text input.
  try
    TMacState(Block.State).DesktopEvent(TNSEvent.Wrap(Event));
  except
    // Exceptions must never escape an Objective-C block callback.
  end;
end;

procedure TMacState.ResetDesktop;
begin
  FillChar(Keys, SizeOf(Keys), 0);
  FillChar(Buttons, SizeOf(Buttons), 0);
  FillChar(Delta, SizeOf(Delta), 0);
end;

procedure TMacState.DesktopEvent(Event: NSEvent);
begin
  if not TNSApplication.Wrap(TNSApplication.OCClass.sharedApplication).isActive then
    Exit;
  case Event.&type of
    NSKeyDown, NSKeyUp:
      begin
        var Code := MacKeyToHid(Event.keyCode);
        if Code <> 0 then
          Keys[Code] := Event.&type = NSKeyDown;
      end;
    NSFlagsChanged:
      begin
        var Code := MacKeyToHid(Event.keyCode);
        var Flags := Event.modifierFlags;
        var Mask: NSUInteger := 0;
        // Device-dependent flags retain separate left/right modifier states.
        case Code of
          224:
            Mask := $1;
          225:
            Mask := $2;
          226:
            Mask := $20;
          227:
            Mask := $8;
          228:
            Mask := $2000;
          229:
            Mask := $4;
          230:
            Mask := $40;
          231:
            Mask := $10;
          57:
            Mask := $10000;
        end;
        if Mask <> 0 then
          Keys[Code] := (Flags and Mask) <> 0;
      end;
    NSLeftMouseDown, NSRightMouseDown, NSOtherMouseDown, NSLeftMouseUp, NSRightMouseUp, NSOtherMouseUp:
      begin
        var Button := Event.buttonNumber;
        if (Button >= 0) and (Button <= High(Buttons)) then
          Buttons[Button] := Event.&type in [NSLeftMouseDown, NSRightMouseDown, NSOtherMouseDown];
      end;
    NSMouseMoved, NSLeftMouseDragged, NSRightMouseDragged, NSOtherMouseDragged:
      begin
        Delta[MouseX] := Delta[MouseX] + Event.deltaX;
        Delta[MouseY] := Delta[MouseY] + Event.deltaY;
      end;
    NSScrollWheel:
      begin
        // AppKit deltas, including trackpad scrolling, are not raw HID detents.
        Delta[MouseWheel] := Delta[MouseWheel] + Event.deltaY;
        Delta[MouseHorizontalWheel] := Delta[MouseHorizontalWheel] - Event.deltaX;
      end;
  end;
end;

function MakeString(const Text: string): CFStringRef;
begin
  var Bytes := UTF8String(Text);
  Result := CFStringCreateWithCString(nil, MarshaledAString(Bytes), kCFStringEncodingUTF8);
end;

function DeviceNumber(Device: Pointer; const Name: string): Int64;
begin
  Result := 0;
  var Key := MakeString(Name);
  try
    var Value := HIDDeviceProperty(Device, Key);
    if (Value <> nil) and (CFGetTypeID(Value) = CFNumberGetTypeID) then
      CFNumberGetValue(CFNumberRef(Value), kCFNumberSInt64Type, @Result);
  finally
    CFRelease(Key);
  end;
end;

function DeviceString(Device: Pointer; const Name: string): string;
begin
  Result := '';
  var Key := MakeString(Name);
  try
    var Value := HIDDeviceProperty(Device, Key);
    if (Value = nil) or (CFGetTypeID(Value) <> CFStringGetTypeID) then
      Exit;
    var Buffer: array[0..4095] of AnsiChar;
    if CFStringGetCString(CFStringRef(Value), @Buffer[0], SizeOf(Buffer), kCFStringEncodingUTF8) then
      Result := UTF8ToString(PAnsiChar(@Buffer[0]));
  finally
    CFRelease(Key);
  end;
end;

procedure TMacState.RefreshDesktop;
begin
  // Registry metadata only: never open keyboard/mouse HID devices.
  var Matching := ServiceMatching('IOHIDDevice');
  var Iterator: Cardinal := 0;
  if (Matching = nil) or (MatchingServices(0, CFDictionaryRef(Matching), Iterator) <> 0) then
    Exit;
  var HasKeyboard := False;
  var HasMouse := False;
  var PageKey := MakeString('PrimaryUsagePage');
  var UsageKey := MakeString('PrimaryUsage');
  var PairsKey := MakeString('DeviceUsagePairs');
  var PairPageKey := MakeString('DeviceUsagePage');
  var PairUsageKey := MakeString('DeviceUsage');
  try
    while True do
    begin
      var Service := IteratorNext(Iterator);
      if Service = 0 then
        Break;
      try
        var PageRef := RegistryProperty(Service, PageKey, nil, 0);
        var UsageRef := RegistryProperty(Service, UsageKey, nil, 0);
        var Pairs := RegistryProperty(Service, PairsKey, nil, 0);
        try
          var Page, Usage: Integer;
          Page := 0;
          Usage := 0;
          if (PageRef <> nil) and (CFGetTypeID(PageRef) = CFNumberGetTypeID) then
            CFNumberGetValue(PageRef, kCFNumberSInt32Type, @Page);
          if (UsageRef <> nil) and (CFGetTypeID(UsageRef) = CFNumberGetTypeID) then
            CFNumberGetValue(UsageRef, kCFNumberSInt32Type, @Usage);
          HasKeyboard := HasKeyboard or ((Page = 1) and (Usage = 6));
          HasMouse := HasMouse or ((Page = 1) and (Usage = 2)) or ((Page = 13) and (Usage = 5));
          if (Pairs <> nil) and (CFGetTypeID(Pairs) = CFArrayGetTypeID) then
            for var I := 0 to CFArrayGetCount(Pairs) - 1 do
            begin
              var Pair := CFArrayGetValueAtIndex(Pairs, I);
              if CFGetTypeID(Pair) <> CFDictionaryGetTypeID then
                Continue;
              var P := CFDictionaryGetValue(Pair, PairPageKey);
              var U := CFDictionaryGetValue(Pair, PairUsageKey);
              Page := 0;
              Usage := 0;
              if (P <> nil) and (CFGetTypeID(P) = CFNumberGetTypeID) then
                CFNumberGetValue(P, kCFNumberSInt32Type, @Page);
              if (U <> nil) and (CFGetTypeID(U) = CFNumberGetTypeID) then
                CFNumberGetValue(U, kCFNumberSInt32Type, @Usage);
              HasKeyboard := HasKeyboard or ((Page = 1) and (Usage = 6));
              HasMouse := HasMouse or ((Page = 1) and (Usage = 2)) or ((Page = 13) and (Usage = 5));
            end;
        finally
          if PageRef <> nil then
            CFRelease(PageRef);
          if UsageRef <> nil then
            CFRelease(UsageRef);
          if Pairs <> nil then
            CFRelease(Pairs);
        end;
      finally
        ObjectRelease(Service);
      end;
    end;
  finally
    CFRelease(PageKey);
    CFRelease(UsageKey);
    CFRelease(PairsKey);
    CFRelease(PairPageKey);
    CFRelease(PairUsageKey);
    ObjectRelease(Iterator);
  end;
  DesktopDevices := nil;
  if HasKeyboard then
    DesktopDevices := DesktopDevices + [DesktopInputDevice(TInputDeviceKind.Keyboard)]
  else
    FillChar(Keys, SizeOf(Keys), 0);
  if HasMouse then
    DesktopDevices := DesktopDevices + [DesktopInputDevice(TInputDeviceKind.Mouse)]
  else
  begin
    FillChar(Buttons, SizeOf(Buttons), 0);
    FillChar(Delta, SizeOf(Delta), 0);
  end;
end;

constructor TMacState.Create;
begin
  inherited;
  Devices := TObjectList<TMacDevice>.Create;
  Manager := HIDManagerCreate(nil, 0);
  if Manager = nil then
    raise EInvalidOperation.Create('IOHIDManagerCreate failed');
  var ArrayCallbacks := kCFTypeArrayCallBacks;
  var KeyCallbacks := kCFTypeDictionaryKeyCallBacks;
  var ValueCallbacks := kCFTypeDictionaryValueCallBacks;
  var Matches := CFArrayCreateMutable(nil, 0, @ArrayCallbacks);
  try
    // Raw HID is reserved for separate gaming devices, including wheels.
    for var Usage in [4, 5, 8] do
    begin
      var Match := CFDictionaryCreateMutable(nil, 0, @KeyCallbacks, @ValueCallbacks);
      try
        var Page: Integer := 1;
        var NativeUsage: Integer := Usage;
        var PageKey := MakeString('DeviceUsagePage');
        var UsageKey := MakeString('DeviceUsage');
        var PageNumber := CFNumberCreate(nil, kCFNumberSInt32Type, @Page);
        var UsageNumber := CFNumberCreate(nil, kCFNumberSInt32Type, @NativeUsage);
        try
          CFDictionarySetValue(Match, PageKey, PageNumber);
          CFDictionarySetValue(Match, UsageKey, UsageNumber);
          CFArrayAppendValue(Matches, Match);
        finally
          CFRelease(PageKey);
          CFRelease(UsageKey);
          CFRelease(PageNumber);
          CFRelease(UsageNumber);
        end;
      finally
        CFRelease(Match);
      end;
    end;
    HIDManagerMatch(Manager, Matches);
  finally
    CFRelease(Matches);
  end;
  RunLoop := CFRunLoopGetCurrent;
  HIDManagerSchedule(Manager, RunLoop, kCFRunLoopDefaultMode);
  HIDManagerOpen(Manager, 0);
  BlockDescriptor.Size := SizeOf(TLocalBlock);
  BlockDescriptor.Signature := '@16@?0@8'; // Object result; block and event pointer arguments (64-bit ABI).
  var Block := Default(TLocalBlock);
  Block.Isa := dlsym(RTLD_DEFAULT, '_NSConcreteStackBlock');
  if Block.Isa = nil then
    raise EInvalidOperation.Create('Objective-C block runtime unavailable');
  Block.Flags := 1 shl 30; // BLOCK_HAS_SIGNATURE; captured Pascal pointer needs no retain helper.
  Block.Invoke := @LocalEventCallback;
  Block.Descriptor := @BlockDescriptor;
  Block.State := Self;
  var HeapBlock := BlockCopy(@Block);
  try
    Monitor := TLocalEvent.OCClass.addLocalMonitorForEventsMatchingMask(
      NSKeyDownMask or NSKeyUpMask or NSFlagsChangedMask or
      NSLeftMouseDownMask or NSLeftMouseUpMask or NSRightMouseDownMask or NSRightMouseUpMask or
      NSOtherMouseDownMask or NSOtherMouseUpMask or NSMouseMovedMask or
      NSLeftMouseDraggedMask or NSRightMouseDraggedMask or NSOtherMouseDraggedMask or NSScrollWheelMask,
      HeapBlock);
  finally
    BlockRelease(HeapBlock);
  end;
  if Monitor = nil then
    raise EInvalidOperation.Create('Cannot install local AppKit input monitor');
  RefreshDesktop;
end;

destructor TMacDevice.Destroy;
begin
  if AllElements <> nil then
    CFRelease(AllElements);
  if Ref <> nil then
    CFRelease(Ref);
  inherited;
end;

destructor TMacState.Destroy;
begin
  if Monitor <> nil then
    TLocalEvent.OCClass.removeMonitor(Monitor);
  if Manager <> nil then
  begin
    if RunLoop <> nil then
      HIDManagerUnschedule(Manager, RunLoop, kCFRunLoopDefaultMode);
    HIDManagerClose(Manager, 0);
    CFRelease(Manager);
  end;
  Devices.Free;
  inherited;
end;

constructor TMacOSInputBackend.Create;
begin
  inherited;
  FImpl := TMacState.Create;
end;

destructor TMacOSInputBackend.Destroy;
begin
  FImpl.Free;
  inherited;
end;

procedure TMacOSInputBackend.Refresh;
begin
  var State := TMacState(FImpl);
  State.RefreshDesktop;
  // Bounded servicing also supports console programs without an AppKit loop.
  CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0, True);
  var SetRef := HIDManagerCopyDevices(State.Manager);
  try
    for var Device in State.Devices do
      Device.Seen := False;
    if SetRef <> nil then
    begin
      var Refs: TArray<Pointer>;
      SetLength(Refs, CFSetGetCount(SetRef));
      if Length(Refs) > 0 then
        CFSetGetValues(SetRef, @Refs[0]);
      for var Ref in Refs do
      begin
        var Existing: TMacDevice := nil;
        for var Device in State.Devices do
          if Device.Ref = Ref then
            Existing := Device;
        if Existing <> nil then
        begin
          Existing.Seen := True;
          if not Existing.Info.Available then
            HIDDeviceOpen(Ref, 0);
          Continue;
        end;
        var Device := TMacDevice.Create;
        try
          Device.Ref := Pointer(CFRetain(Ref));
          Device.Info.Name := DeviceString(Ref, 'Product');
          Device.Info.Serial := DeviceString(Ref, 'SerialNumber');
          Device.Info.VendorId := Word(DeviceNumber(Ref, 'VendorID') and $FFFF);
          Device.Info.ProductId := Word(DeviceNumber(Ref, 'ProductID') and $FFFF);
          var Identity := Device.Info.Serial;
          if Identity = '' then
            Identity := IntToHex(DeviceNumber(Ref, 'LocationID'), 8);
          Device.Info.Id := 'macos:hid:' + IntToHex(Device.Info.VendorId, 4) + ':' +
            IntToHex(Device.Info.ProductId, 4) + ':' + Identity + ':' +
            IntToStr(DeviceNumber(Ref, 'PrimaryUsage'));
          var Location := DeviceNumber(Ref, 'LocationID');
          if (Device.Info.Serial <> '') or (Location <> 0) then
            Device.Info.PhysicalId := 'macos:physical:' + IntToHex(Device.Info.VendorId, 4) + ':' +
              IntToHex(Device.Info.ProductId, 4) + ':' + Device.Info.Serial + ':' + IntToHex(Location, 8)
          else
          begin
            var Id: UInt64;
            if RegistryId(HIDDeviceService(Ref), Id) = 0 then
              Device.Info.PhysicalId := 'macos:registry:' + IntToHex(Id, 16);
          end;
          var Transport := DeviceString(Ref, 'Transport').ToLower;
          Device.Info.IsVirtual := (Transport = 'virtual') or (Transport = 'software');
          for var Other in State.Devices do
            if Other.Info.Id = Device.Info.Id then
              Device.Info.Id := Device.Info.Id + ':' + IntToHex(NativeUInt(Ref), 16);
          Device.Info.Kind := TInputDeviceKind.Controller;
          var Status := HIDDeviceOpen(Ref, 0);
          Device.Info.Available := Status = 0;
          if Status <> 0 then
            Device.Info.Error := Format('IOHIDDeviceOpen %.8x; check gaming device access', [Cardinal(Status)]);
          Device.AllElements := HIDDeviceCopyElements(Ref, nil, 0);
          if Device.AllElements <> nil then
            for var I := 0 to CFArrayGetCount(Device.AllElements) - 1 do
            begin
              var Element: TMacElement;
              Element.Ref := CFArrayGetValueAtIndex(Device.AllElements, I);
              var ElementType := HIDElementType(Element.Ref);
              var Page := HIDElementPage(Element.Ref);
              var Usage := HIDElementUsage(Element.Ref);
              if (ElementType < 1) or (ElementType > 4) then
                Continue; // input elements only
              Element.Minimum := HIDElementMinimum(Element.Ref);
              Element.Maximum := HIDElementMaximum(Element.Ref);
              Element.Info.Code := Integer(HIDElementCookie(Element.Ref) and $7FFFFFFF);
              if (Page = 7) and (Usage >= 4) and (Usage <= 231) then
              begin
                Element.Info.Kind := TInputElementKind.Key;
                Element.Info.Code := Usage;
                Element.Info.Name := InputKeyName(Usage);
              end
              else if Page = 9 then
              begin
                Element.Info.Kind := TInputElementKind.Button;
                Element.Info.Name := 'Button ' + IntToStr(Usage);
              end
              else if (Page = 1) and (Usage = $39) then
              begin
                Element.Info.Kind := TInputElementKind.Hat;
                Element.Info.Name := 'D-pad';
              end
              else if (Page = 1) and (Usage >= $30) and (Usage <= $38) then
              begin
                Element.Info.Kind := TInputElementKind.Axis;
                Element.Info.Name := 'Axis ' + IntToStr(Usage);
              end
              else
                Continue;
              Device.Elements := Device.Elements + [Element];
              Device.Info.Elements := Device.Info.Elements + [Element.Info];
            end;
          Device.Seen := True;
          State.Devices.Add(Device);
          Device := nil;
        finally
          Device.Free;
        end;
      end;
    end;
    for var I := State.Devices.Count - 1 downto 0 do
      if not State.Devices[I].Seen then
      begin
        State.Devices.Delete(I);
      end;
  finally
    if SetRef <> nil then
      CFRelease(SetRef);
  end;
  FDevices := Copy(State.DesktopDevices);
  for var Device in State.Devices do
    FDevices := FDevices + [Device.Info];
end;

function TMacOSInputBackend.Poll: TArray<TInputValue>;
begin
  CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0, True);
  var Values := TList<TInputValue>.Create;
  try
    var State := TMacState(FImpl);
    if not TNSApplication.Wrap(TNSApplication.OCClass.sharedApplication).isActive then
      State.ResetDesktop;
    FDevices := Copy(State.DesktopDevices);
    for var Device in State.DesktopDevices do
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
    for var Device in TMacState(FImpl).Devices do
    begin
      var DeviceValues := TList<TInputValue>.Create;
      try
        Device.Info.Available := True;
        Device.Info.Error := '';
        for var Element in Device.Elements do
        begin
          var NativeValue: Pointer := nil;
          var Status := HIDDeviceValue(Device.Ref, Element.Ref, NativeValue);
          if (Status <> 0) or (NativeValue = nil) then
          begin
            Device.Info.Available := False;
            Device.Info.Error := Format('IOHID read %.8x; check device access', [Cardinal(Status)]);
            Continue;
          end;
          var RawValue := HIDValueInteger(NativeValue);
          var Value: Single := 0;
          case Element.Info.Kind of
            TInputElementKind.Axis:
              Value := NormalizeAxis(RawValue, Element.Minimum, Element.Maximum);
            TInputElementKind.Hat:
              if (RawValue < Element.Minimum) or (RawValue > Element.Maximum) then
                Value := -1
              else if Element.Maximum - Element.Minimum = 3 then
                Value := (RawValue - Element.Minimum) * 2
              else if Element.Maximum - Element.Minimum = 7 then
                Value := RawValue - Element.Minimum
              else
                Value := -1;
          else
            if RawValue <> 0 then
              Value := 1;
          end;
          DeviceValues.Add(TInputValue.Create(Device.Info.Id, Element.Info.Kind, Element.Info.Code, Value));
        end;
        if Device.Info.Available then
          Values.AddRange(DeviceValues);
      finally
        DeviceValues.Free;
      end;
      FDevices := FDevices + [Device.Info];
    end;
    Result := PublishValues(Values.ToArray);
  finally
    Values.Free;
  end;
end;

procedure TMacOSInputBackend.Reset;
begin
  CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0, True);
  TMacState(FImpl).ResetDesktop;
end;
{$ENDIF}

end.

