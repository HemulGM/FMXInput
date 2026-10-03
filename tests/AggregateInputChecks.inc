procedure TestAggregateInput;
begin
  var Backend := TFakeBackend.Create;
  try
    var K1 := DesktopInputDevice(TInputDeviceKind.Keyboard);
    K1.Id := 'keyboard:1'; K1.PhysicalId := 'physical:1'; K1.Serial := 'serial:1';
    K1.VendorId := 123; K1.ProductId := 456;
    var K2 := K1; K2.Id := 'keyboard:2'; K2.PhysicalId := 'physical:2';
    var M1 := DesktopInputDevice(TInputDeviceKind.Mouse);
    M1.Id := 'mouse:1'; M1.PhysicalId := 'physical:mouse1';
    var M2 := M1; M2.Id := 'mouse:2'; M2.PhysicalId := 'physical:mouse2';
    var Pad := Default(TInputDevice);
    Pad.Kind := TInputDeviceKind.Controller; Pad.Id := 'pad:1';
    Pad.PhysicalId := 'physical:pad1'; Pad.VendorId := 123; Pad.ProductId := 456;
    Pad.Elements := [M1.Elements[0]]; Pad.Available := True;
    var Wheel := Pad; Wheel.Id := 'wheel:1'; Wheel.PhysicalId := 'physical:wheel1';
    var Twin := Pad; Twin.Id := 'pad:2'; Twin.PhysicalId := 'physical:pad2';
    Backend.SetDevices([Pad, M1, K1, Wheel, K2, M2, Twin]);
    var Listed := Backend.Devices;
    Check((Length(Listed) = 5) and (Listed[0].Id = SystemKeyboardId) and
      (Listed[1].Id = SystemMouseId), 'Stable order: keyboard, mouse, distinct gaming devices');
    Check((Listed[0].Serial = '') and (Listed[0].PhysicalId = '') and
      (Listed[0].VendorId = 0) and (Listed[0].Name = 'Keyboard'), 'Aggregate does not impersonate physical hardware');
    for var Mode in [TInputDeviceListMode.Gaming, TInputDeviceListMode.AllInterfaces] do
    begin
      Backend.DeviceListMode := Mode;
      Check(Length(Backend.Devices) = 5, 'Both list modes preserve abstract desktop sources');
      var V := Backend.Publish([
        TInputValue.Create(K1.Id, TInputElementKind.Key, 26, 0),
        TInputValue.Create(K2.Id, TInputElementKind.Key, 26, 1)]);
      Check((Length(V) = 1) and (V[0].DeviceId = SystemKeyboardId) and (V[0].Value = 1),
        'One keyboard release cannot release another held key');
      V := Backend.Publish([
        TInputValue.Create(M1.Id, TInputElementKind.RelativeAxis, MouseX, 3),
        TInputValue.Create(M2.Id, TInputElementKind.RelativeAxis, MouseX, -1)]);
      Check((Length(V) = 1) and (V[0].DeviceId = SystemMouseId) and (V[0].Value = 2),
        'All mouse motion is accumulated once');
      V := Backend.Publish([
        TInputValue.Create(Pad.Id, TInputElementKind.Button, 0, 1),
        TInputValue.Create(Twin.Id, TInputElementKind.Button, 0, 0)]);
      Check((Length(V) = 2) and (V[0].DeviceId <> V[1].DeviceId), 'Identical gamepad models remain independent');
    end;
    K1.Available := False; K1.Error := 'Denied';
    Backend.SetDevices([K1, K2]);
    Check(Backend.Devices[0].Available and (Backend.Devices[0].Error = ''), 'A usable keyboard keeps the aggregate usable');
    Backend.SetDevices([K2]);
    Check(Backend.Devices[0].Id = SystemKeyboardId, 'Keyboard ID survives unplugging a physical keyboard');
    Backend.SetDevices([Pad]);
    Check((Length(Backend.Devices) = 1) and (Backend.Devices[0].Kind = TInputDeviceKind.Controller),
      'No desktop source invented when none is present');
    Backend.SetDevices(nil);
    Check(Length(Backend.Devices) = 0, 'No ghost sources');
    Check((MacKeyToHid(13) = 26) and (MacKeyToHid(0) = 4) and
      (MacKeyToHid(56) = 225) and (MacKeyToHid(60) = 229) and (MacKeyToHid(200) = 0),
      'Mac physical keys map to the same HID positions');
  finally Backend.Free; end;
end;
