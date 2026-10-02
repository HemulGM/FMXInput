program FMXInputDemo;

uses
  System.StartUpCopy,
  FMX.Forms,
  FMXInput in '..\..\FMXInput.pas',
  FMXInput.Windows in '..\..\FMXInput.Windows.pas',
  FMXInput.Linux in '..\..\FMXInput.Linux.pas',
  FMXInput.MacOS in '..\..\FMXInput.MacOS.pas',
  InputDemo.Main in 'InputDemo.Main.pas' {InputDemoForm};

begin
  Application.Initialize;
  Application.CreateForm(TInputDemoForm, InputDemoForm);
  Application.Run;
end.
