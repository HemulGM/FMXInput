program InputProbe;

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  System.Classes,
  FMXInput.Linux in '..\FMXInput.Linux.pas',
  FMXInput.MacOS in '..\FMXInput.MacOS.pas',
  FMXInput in '..\FMXInput.pas',
  FMXInput.Windows in '..\FMXInput.Windows.pas';

begin
  try
    var Mode := TInputDeviceListMode.Gaming;
    if ParamStr(1) = '--all' then Mode := TInputDeviceListMode.AllInterfaces;
    var Manager := TInputManager.Create(CreateFMXInputBackend(Mode));
    try
      for var Device in Manager.Devices do
      begin
        Writeln(Device.Name, ' [', Device.Id, ']');
        Writeln('  Available=', Device.Available, ' controls=', Length(Device.Elements));
        Writeln('  Kind=', InputDeviceKindName(Device.Kind), ' virtual=', Device.IsVirtual,
          ' auxiliary=', Device.IsAuxiliary, ' physical=', Device.PhysicalId);
        if Device.Error <> '' then
          Writeln('  ', Device.Error);
      end;
      if (ParamCount > 0) and (ParamStr(1) = '--capture') then
      begin
        Writeln('Release sticks/triggers, then press a key/button or move an axis. Timeout: 30 seconds.');
        Manager.BeginCapture(1);
        var Deadline := TThread.GetTickCount64 + 30000;
        while Manager.Capturing and (TThread.GetTickCount64 < Deadline) do
        begin
          Manager.Poll;
          TThread.Sleep(8);
        end;
        var Binding: TInputBinding;
        if Manager.TakeCaptured(Binding) then
        begin
          Writeln('Captured ', Binding.DeviceId, ' kind=', Ord(Binding.Kind),
            ' code=', Binding.Code, ' direction=', Binding.Direction);
          Manager.AddBinding(Binding);
          var Stream := TFileStream.Create('input-profile.json', fmCreate);
          try
            Manager.SaveBindings(Stream);
          finally
            Stream.Free;
          end;
        end
        else
          Writeln('No input captured.');
      end;
    finally
      Manager.Free;
    end;
  except
    on E: Exception do
    begin
      Writeln(E.ClassName, ': ', E.Message);
      Halt(1);
    end;
  end;
end.

