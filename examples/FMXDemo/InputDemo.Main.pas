unit InputDemo.Main;

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections,
  FMX.Types, FMX.Controls, FMX.Forms, FMX.Layouts, FMX.StdCtrls,
  FMX.ListBox, FMX.Grid, FMX.Grid.Style, FMX.ScrollBox, FMX.Memo,
  FMX.Controls.Presentation, FMX.Objects, FMXInput, System.Rtti, FMX.Memo.Types;

type
  TInputDemoForm = class(TForm)
    RootLayout: TLayout;
    BackgroundRect: TRectangle;
    HeaderLayout: TLayout;
    TitleLabel: TLabel;
    SubtitleLabel: TLabel;
    DeviceLayout: TLayout;
    DeviceLabel: TLabel;
    DeviceRow: TLayout;
    DeviceCombo: TComboBox;
    RefreshButton: TButton;
    DeviceInfoLayout: TLayout;
    DeviceIdLabel: TLabel;
    DeviceStatusLabel: TLabel;
    MainLayout: TLayout;
    ControlsLayout: TLayout;
    ControlsLabel: TLabel;
    ValuesGrid: TStringGrid;
    KindColumn: TStringColumn;
    NameColumn: TStringColumn;
    CodeColumn: TStringColumn;
    ValueColumn: TStringColumn;
    Splitter: TSplitter;
    EventsLayout: TLayout;
    EventsHeader: TLayout;
    EventsLabel: TLabel;
    ClearLogButton: TButton;
    EventsMemo: TMemo;
    FooterLayout: TLayout;
    HeldLabel: TLabel;
    CaptureRow: TLayout;
    CaptureButton: TButton;
    CancelButton: TButton;
    CaptureLabel: TLabel;
    BindingStateLabel: TLabel;
    PollTimer: TTimer;
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure FormActivate(Sender: TObject);
    procedure FormDeactivate(Sender: TObject);
    procedure DeviceComboChange(Sender: TObject);
    procedure RefreshButtonClick(Sender: TObject);
    procedure CaptureButtonClick(Sender: TObject);
    procedure CancelButtonClick(Sender: TObject);
    procedure ClearLogButtonClick(Sender: TObject);
    procedure PollTimerTimer(Sender: TObject);
  private
    FInput: TInputManager;
    FDevices: TArray<TInputDevice>;
    FSelectedId: string;
    FUpdating, FHasBinding, FDevicesInitialized: Boolean;
    FPrevious: TDictionary<string, TInputValue>;
    FRows: TDictionary<string, Integer>;
    function SelectedDevice(out Device: TInputDevice): Boolean;
    function ElementName(Kind: TInputElementKind; Code: Integer): string;
    procedure SynchronizeDevices;
    procedure PopulateControls;
    procedure DisplayValues;
    procedure UpdateStatus;
    procedure Log(const Text: string);
    procedure UpdateCaptureButtons;
  protected
    function CreateBackend: TInputBackend; virtual;
  end;

var
  InputDemoForm: TInputDemoForm;

implementation

uses System.Math;

{$R *.fmx}

function KindName(Kind: TInputElementKind): string;
begin
  case Kind of
    TInputElementKind.Key: Result := 'Key';
    TInputElementKind.Button: Result := 'Button';
    TInputElementKind.Axis: Result := 'Axis';
    TInputElementKind.Hat: Result := 'Hat';
  end;
end;

function FormatValue(Kind: TInputElementKind; Value: Single): string;
const
  Directions: array[0..7] of string = ('Up', 'Up-right', 'Right', 'Down-right',
    'Down', 'Down-left', 'Left', 'Up-left');
begin
  case Kind of
    TInputElementKind.Key, TInputElementKind.Button:
      if Value > 0.5 then Result := 'Pressed' else Result := 'Released';
    TInputElementKind.Axis: Result := FormatFloat('0.000', Value);
    TInputElementKind.Hat:
      if (Value >= 0) and (Value <= 7) then Result := Directions[Round(Value)]
      else Result := 'Neutral';
  end;
end;

function TInputDemoForm.CreateBackend: TInputBackend;
begin Result := CreateFMXInputBackend; end;

procedure TInputDemoForm.FormCreate(Sender: TObject);
begin
  FPrevious := TDictionary<string, TInputValue>.Create;
  FRows := TDictionary<string, Integer>.Create;
  FInput := TInputManager.Create(CreateBackend);
  SynchronizeDevices;
  PollTimer.Enabled := True;
end;

procedure TInputDemoForm.FormDestroy(Sender: TObject);
begin
  PollTimer.Enabled := False;
  FInput.Free; FRows.Free; FPrevious.Free;
end;

procedure TInputDemoForm.FormActivate(Sender: TObject);
begin
  if FInput = nil then Exit;
  FInput.Enabled := True;
  UpdateStatus;
  UpdateCaptureButtons;
end;

procedure TInputDemoForm.FormDeactivate(Sender: TObject);
begin
  if FInput = nil then Exit;
  FInput.Enabled := False;
  DisplayValues;
  FPrevious.Clear;
  UpdateStatus;
  if CaptureLabel.Text = 'Waiting for input from the selected device...' then
    CaptureLabel.Text := 'Capture cancelled: window lost focus.';
  UpdateCaptureButtons;
end;

function TInputDemoForm.SelectedDevice(out Device: TInputDevice): Boolean;
begin
  Device := Default(TInputDevice);
  for var Item in FDevices do
    if Item.Id = FSelectedId then begin Device := Item; Exit(True); end;
  Result := False;
end;

function TInputDemoForm.ElementName(Kind: TInputElementKind; Code: Integer): string;
begin
  var Device: TInputDevice;
  if SelectedDevice(Device) then
    for var Element in Device.Elements do
      if (Element.Kind = Kind) and (Element.Code = Code) then Exit(Element.Name);
  if Kind = TInputElementKind.Key then Result := InputKeyName(Code)
  else Result := KindName(Kind) + ' ' + IntToStr(Code);
end;

procedure TInputDemoForm.SynchronizeDevices;
begin
  var Current := FInput.Devices;
  var Changed := not FDevicesInitialized or (Length(Current) <> Length(FDevices));
  if not Changed then
    for var I := 0 to High(Current) do
      if (Current[I].Id <> FDevices[I].Id) or (Current[I].Name <> FDevices[I].Name) or
        (Current[I].Available <> FDevices[I].Available) or
        (Current[I].Error <> FDevices[I].Error) or
        (Length(Current[I].Elements) <> Length(FDevices[I].Elements)) then Changed := True;
  if not Changed then Exit;
  var PreviousId := FSelectedId;
  FDevices := Current;
  var SelectedIndex := -1;
  FUpdating := True;
  DeviceCombo.Items.BeginUpdate;
  try
    DeviceCombo.Items.Clear;
    for var I := 0 to High(FDevices) do
    begin
      var Device := FDevices[I];
      var Caption := Device.Name;
      if Device.Kind = TInputDeviceKind.Keyboard then Caption := Caption + ' | Keyboard'
      else Caption := Caption + ' | Controller';
      if Device.VendorId <> 0 then
        Caption := Caption + ' | ' + IntToHex(Device.VendorId, 4) + ':' + IntToHex(Device.ProductId, 4);
      Caption := IntToStr(I + 1) + '. ' + Caption;
      if not Device.Available then Caption := Caption + ' | unavailable';
      DeviceCombo.Items.Add(Caption);
      if Device.Id = PreviousId then SelectedIndex := I;
    end;
    // On startup choose the first usable source. If the selected source is
    // unplugged, leave selection empty instead of silently switching devices.
    if not FDevicesInitialized and (SelectedIndex < 0) then
      for var I := 0 to High(FDevices) do
        if FDevices[I].Available then begin SelectedIndex := I; Break; end;
    DeviceCombo.ItemIndex := SelectedIndex;
  finally DeviceCombo.Items.EndUpdate; FUpdating := False; end;
  FDevicesInitialized := True;
  if (SelectedIndex >= 0) and (FDevices[SelectedIndex].Id = PreviousId) then
  begin
    PopulateControls;
    UpdateStatus;
  end
  else DeviceComboChange(nil);
  UpdateCaptureButtons;
end;

procedure TInputDemoForm.DeviceComboChange(Sender: TObject);
begin
  if FUpdating or (FInput = nil) then Exit;
  FInput.CancelCapture;
  FInput.ClearBindings;
  FHasBinding := False;
  FSelectedId := '';
  if (DeviceCombo.ItemIndex >= 0) and (DeviceCombo.ItemIndex < Length(FDevices)) then
    FSelectedId := FDevices[DeviceCombo.ItemIndex].Id;
  EventsMemo.Lines.Clear;
  FPrevious.Clear;
  CaptureLabel.Text := 'Release controls, then choose Capture next input.';
  BindingStateLabel.Text := 'Captured action: not assigned';
  PopulateControls;
  for var Value in FInput.Values do
    if Value.DeviceId = FSelectedId then
      FPrevious.AddOrSetValue(InputValueKey(Value.DeviceId, Value.Kind, Value.Code), Value);
  DisplayValues;
  UpdateStatus;
  UpdateCaptureButtons;
end;

procedure TInputDemoForm.PopulateControls;
begin
  FRows.Clear;
  var Device: TInputDevice;
  ValuesGrid.BeginUpdate;
  try
    if not SelectedDevice(Device) then begin ValuesGrid.RowCount := 0; Exit; end;
    ValuesGrid.RowCount := Length(Device.Elements);
    for var I := 0 to High(Device.Elements) do
    begin
      var Element := Device.Elements[I];
      FRows.AddOrSetValue(InputValueKey(Device.Id, Element.Kind, Element.Code), I);
      ValuesGrid.Cells[0, I] := KindName(Element.Kind);
      ValuesGrid.Cells[1, I] := Element.Name;
      ValuesGrid.Cells[2, I] := IntToStr(Element.Code);
      if Element.Kind = TInputElementKind.Hat then ValuesGrid.Cells[3, I] := 'Neutral'
      else ValuesGrid.Cells[3, I] := FormatValue(Element.Kind, 0);
    end;
  finally ValuesGrid.EndUpdate; end;
end;

procedure TInputDemoForm.Log(const Text: string);
begin
  EventsMemo.Lines.BeginUpdate;
  try
    while EventsMemo.Lines.Count >= 300 do EventsMemo.Lines.Delete(0);
    EventsMemo.Lines.Add(FormatDateTime('hh:nn:ss.zzz', Now) + '  ' + Text);
  finally EventsMemo.Lines.EndUpdate; end;
  EventsMemo.GoToTextEnd;
end;

procedure TInputDemoForm.DisplayValues;
begin
  var Current := TDictionary<string, TInputValue>.Create;
  var Held := TStringList.Create;
  try
    for var Value in FInput.Values do
      if (FSelectedId <> '') and (Value.DeviceId = FSelectedId) then
      begin
        var Key := InputValueKey(Value.DeviceId, Value.Kind, Value.Code);
        Current.AddOrSetValue(Key, Value);
        if ((Value.Kind in [TInputElementKind.Key, TInputElementKind.Button]) and (Value.Value > 0.5)) or
          ((Value.Kind = TInputElementKind.Hat) and (Value.Value >= 0)) then
          Held.Add(ElementName(Value.Kind, Value.Code));
      end;
    // Include disappeared values so a sparse key snapshot generates release.
    for var Pair in FPrevious do
      if not Current.ContainsKey(Pair.Key) then
      begin
        var Released := Pair.Value;
        if Released.Kind = TInputElementKind.Hat then Released.Value := -1 else Released.Value := 0;
        Current.Add(Pair.Key, Released);
      end;
    for var Pair in Current do
    begin
      var Value := Pair.Value;
      var Row: Integer;
      if FRows.TryGetValue(Pair.Key, Row) then
      begin
        var Text := FormatValue(Value.Kind, Value.Value);
        if ValuesGrid.Cells[3, Row] <> Text then ValuesGrid.Cells[3, Row] := Text;
      end;
      var Previous := Value;
      if not FPrevious.TryGetValue(Pair.Key, Previous) then
        if Value.Kind = TInputElementKind.Hat then Previous.Value := -1 else Previous.Value := 0;
      var Changed := Previous.Value <> Value.Value;
      if Value.Kind = TInputElementKind.Axis then Changed := Abs(Previous.Value - Value.Value) >= 0.05;
      if Changed then
      begin
        Log(ElementName(Value.Kind, Value.Code) + ': ' + FormatValue(Value.Kind, Value.Value));
        FPrevious.AddOrSetValue(Pair.Key, Value);
      end;
    end;
    if Held.Count = 0 then HeldLabel.Text := 'Held keys / buttons: none'
    else
    begin
      var Text := '';
      for var Item in Held do
      begin if Text <> '' then Text := Text + ', '; Text := Text + Item; end;
      HeldLabel.Text := 'Held keys / buttons: ' + Text;
    end;
    if FHasBinding then
      if FInput.IsPressed(1) then BindingStateLabel.Text := 'Captured action: PRESSED'
      else BindingStateLabel.Text := 'Captured action: released';
  finally Held.Free; Current.Free; end;
end;

procedure TInputDemoForm.UpdateStatus;
begin
  var Device: TInputDevice;
  if not SelectedDevice(Device) then
  begin
    DeviceIdLabel.Text := 'No input device selected.';
    DeviceStatusLabel.Text := 'Select a source. Disconnected devices do not switch the source automatically.';
  end
  else
  begin
    DeviceIdLabel.Text := Device.Id;
    if not FInput.Enabled then DeviceStatusLabel.Text := 'Paused: activate this window to receive input.'
    else if not Device.Available then DeviceStatusLabel.Text := Device.Error
    else DeviceStatusLabel.Text := Format('%d controls | Only events from this device are displayed.', [Length(Device.Elements)]);
  end;
end;

procedure TInputDemoForm.UpdateCaptureButtons;
begin
  var Device: TInputDevice;
  CaptureButton.Enabled := SelectedDevice(Device) and Device.Available and
    FInput.Enabled and not FInput.Capturing;
  CancelButton.Enabled := FInput.Capturing;
end;

procedure TInputDemoForm.RefreshButtonClick(Sender: TObject);
begin
  FInput.Refresh;
  FInput.Poll;
  SynchronizeDevices;
  DisplayValues;
  UpdateStatus;
  UpdateCaptureButtons;
  PollTimer.Enabled := True;
end;

procedure TInputDemoForm.CaptureButtonClick(Sender: TObject);
begin
  var Device: TInputDevice;
  if not SelectedDevice(Device) or not Device.Available or not FInput.Enabled then Exit;
  FInput.ClearBindings;
  FHasBinding := False;
  FInput.BeginCapture(1, FSelectedId);
  CaptureLabel.Text := 'Waiting for input from the selected device...';
  BindingStateLabel.Text := 'Captured action: not assigned';
  UpdateCaptureButtons;
end;

procedure TInputDemoForm.CancelButtonClick(Sender: TObject);
begin
  FInput.CancelCapture;
  CaptureLabel.Text := 'Capture cancelled.';
  UpdateCaptureButtons;
end;

procedure TInputDemoForm.ClearLogButtonClick(Sender: TObject);
begin EventsMemo.Lines.Clear; end;

procedure TInputDemoForm.PollTimerTimer(Sender: TObject);
begin
  if FInput = nil then Exit;
  try
    FInput.Poll;
    SynchronizeDevices;
    DisplayValues;
    var Binding: TInputBinding;
    if FInput.TakeCaptured(Binding) then
    begin
      FInput.AddBinding(Binding);
      FHasBinding := True;
      var Text := ElementName(Binding.Kind, Binding.Code);
      if Binding.Kind = TInputElementKind.Axis then
        if Binding.Direction < 0 then Text := Text + ' (negative)' else Text := Text + ' (positive)';
      CaptureLabel.Text := 'Captured: ' + Text;
      Log('CAPTURED ' + Text);
    end;
    UpdateCaptureButtons;
  except
    on E: Exception do
    begin
      PollTimer.Enabled := False;
      FInput.Enabled := False;
      Log(E.ClassName + ': ' + E.Message);
      DeviceStatusLabel.Text := 'Input stopped: ' + E.Message;
      UpdateCaptureButtons;
    end;
  end;
end;

end.
