program LinuxGdkTests;

{$APPTYPE CONSOLE}
{$Q+}{$R+}

uses System.SysUtils, System.Classes, FMXInput, FMXInput.Linux;

// Uses only system GTK/X11 to test the optional host integration on Linux.
function gtk_init_check(Argc, Argv: Pointer): Integer; cdecl; external 'libgtk-3.so.0';
function gtk_window_new(Kind: Integer): Pointer; cdecl; external 'libgtk-3.so.0';
procedure gtk_widget_realize(Widget: Pointer); cdecl; external 'libgtk-3.so.0';
procedure gtk_widget_destroy(Widget: Pointer); cdecl; external 'libgtk-3.so.0';
function gtk_widget_get_window(Widget: Pointer): Pointer; cdecl; external 'libgtk-3.so.0';
function gdk_display_get_default: Pointer; cdecl; external 'libgdk-3.so.0';
function gdk_x11_display_get_xdisplay(Display: Pointer): Pointer; cdecl; external 'libgdk-3.so.0';
function gdk_x11_window_get_xid(Window: Pointer): NativeUInt; cdecl; external 'libgdk-3.so.0';
function g_main_context_iteration(Context: Pointer; Block: Integer): Integer; cdecl; external 'libglib-2.0.so.0';
function XSendEvent(Display: Pointer; Window: NativeUInt; Propagate: Integer; Mask: NativeInt; Event: Pointer): Integer; cdecl; external 'libX11.so.6';
procedure XFlush(Display: Pointer); cdecl; external 'libX11.so.6';
function XDefaultRootWindow(Display: Pointer): NativeUInt; cdecl; external 'libX11.so.6';

type
  TXKeyEvent = record
    EventType: Integer;
    Serial: NativeUInt;
    SendEvent: Integer;
    Display: Pointer;
    Window, Root, Subwindow, Time: NativeUInt;
    X, Y, RootX, RootY: Integer;
    State, Detail: Cardinal;
    SameScreen: Integer;
  end;
  TXEvent = record
    case Integer of
      0: (Key: TXKeyEvent);
      1: (Padding: array[0..23] of NativeUInt);
  end;

procedure Check(Value: Boolean; const Message: string);
begin if not Value then raise Exception.Create(Message); end;

procedure Run;
begin
  Check(gtk_init_check(nil, nil) <> 0, 'GTK cannot connect to X11');
  var Window := gtk_window_new(0);
  try
    gtk_widget_realize(Window); // Unmapped: no visible test window.
    var Backend := TLinuxInputBackend.Create;
    try
      Backend.Refresh;
      var Keyboard := False;
      for var Device in Backend.Devices do
        if Device.Id = SystemKeyboardId then
        begin Keyboard := True; Check(Device.Available, 'GDK adapter is unavailable'); end;
      Check(Keyboard, 'GDK seat keyboard not enumerated');
      var Display := gdk_x11_display_get_xdisplay(gdk_display_get_default);
      var Event := Default(TXEvent);
      Event.Key.EventType := 2; Event.Key.Detail := 25;
      Event.Key.Display := Display;
      Event.Key.Window := gdk_x11_window_get_xid(gtk_widget_get_window(Window));
      Event.Key.Root := XDefaultRootWindow(Display);
      Event.Key.SameScreen := 1;
      Check(XSendEvent(Display, Event.Key.Window, 0, 0, @Event) <> 0, 'X11 send failed');
      XFlush(Display);
      var Pressed := False;
      for var I := 0 to 200 do
      begin
        g_main_context_iteration(nil, 0);
        for var Value in Backend.Poll do
          if (Value.DeviceId = SystemKeyboardId) and (Value.Code = 26) and (Value.Value = 1) then Pressed := True;
        if Pressed then Break;
        TThread.Sleep(1);
      end;
      Check(Pressed, 'Native X11 event never reached the backend through GDK filter');
      Backend.Reset;
    finally Backend.Free; end; // Removes the native filter before state destruction.
    g_main_context_iteration(nil, 0);
  finally gtk_widget_destroy(Window); end;
end;

begin
  try
    Run;
    Writeln('PASS native GTK3/X11 seat discovery and local event integration');
  except
    on E: Exception do begin Writeln(E.ClassName + ': ' + E.Message); ExitCode := 1; end;
  end;
end.
