program FMXInputDemo;

uses
  System.StartUpCopy,
  FMX.Forms,
  FMXInput.Linux in '..\..\FMXInput.Linux.pas',
  FMXInput.MacOS in '..\..\FMXInput.MacOS.pas',
  FMXInput in '..\..\FMXInput.pas',
  FMXInput.Windows in '..\..\FMXInput.Windows.pas',
  InputDemo.Main in 'InputDemo.Main.pas' {InputDemoForm};

{$R *.res}

begin
  Application.Initialize;
  Application.CreateForm(TInputDemoForm, InputDemoForm);
  Application.Run;
end.
