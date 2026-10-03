# FMXInput

Standalone Delphi desktop input library for Windows, Linux and macOS. Despite
the repository name, it has **no dependency on FireMonkey, VCL or RetroMul**.
It uses Delphi RTL and operating-system APIs, without SDL, libevdev, helper
executables, drivers or bundled native libraries.

## Units

| Unit | Responsibility |
| --- | --- |
| `FMXInput.pas` | Device/value types, backend factory, action bindings, capture, JSON profiles |
| `FMXInput.Windows.pas` | Aggregate foreground keyboard/mouse via Raw Input; XInput and DirectInput gaming devices |
| `FMXInput.Linux.pas` | Window keyboard/mouse events; evdev gaming devices |
| `FMXInput.MacOS.pas` | Local AppKit keyboard/mouse events; IOHID gaming devices |

Add this directory to the Delphi unit search path and use `FMXInput`. The
factory selects the platform backend at compile time. Only desktop targets
are supported; Android/iOS do not instantiate a desktop backend.

## Basic use

```pascal
uses FMXInput;

var Input := TInputManager.Create(CreateFMXInputBackend);
try
  for var Device in Input.Devices do
    if Device.Available then
      ShowDevice(Device.Id, Device.Name, Device.Elements); // application code

  Input.BeginCapture(100, SelectedDeviceId); // opaque application action ID
  // In the application's timer/update loop:
  Input.Poll;
  var Binding: TInputBinding;
  if Input.TakeCaptured(Binding) then
  begin
    Input.RemoveBindings(100); // omit this to allow multiple sources
    Input.AddBinding(Binding);
  end;
  SetActionState(100, Input.IsPressed(100)); // application code
finally
  Input.Free;
end;
```

Action IDs have no built-in meaning: a project may use them for player/button
pairs, shortcuts or other digital actions. Two devices can drive one action;
releasing one source does not release the other. `Values` exposes the latest
raw normalized snapshot for analog previews or application-specific handling.
The library does not supply a settings window or an emulator adapter.

Create, poll, refresh, save/load and destroy a manager/backend on the **same
thread**. On Windows/macOS use the main/UI thread for native event integration.
Call `Poll` regularly (for example every 8 ms); this is state polling, so very
short presses between polls are not guaranteed to be observed. Discovery is
refreshed once per second while polling; `Refresh` forces an immediate scan.
No background worker or system-wide keyboard/mouse monitor is installed.
Native adapters observe the host application's events and preserve normal dispatch.

Set `Input.Enabled := False` when your application loses focus or opens a
dialog that should receive ordinary text input. Set it back to `True` on
activation. Disable also cancels capture and releases logical actions. Native
controllers can still be held when you re-enable input; their current state
will be reflected on the next poll. The application remains responsible for
focus and text/IME input; this library processes physical keys.

## Capture and values

* Keys and buttons have values 0/1. Standard PC keyboard positions use USB HID
  keyboard usage IDs across backends: physical W is 26 regardless of layout.
  Left/right modifiers and keypad keys are distinct. `InputKeyName` labels
  positions using US legends, not the active text layout. The PC scan-code
  mapping covers standard keys and modifiers; exotic/media keys are not
  exhaustively translated on Windows/Linux.
* Axes use values in [-1, 1]; XInput triggers use [0, 1]. Positive and negative
  directions are separate bindings. Driver-provided axis layouts are not
  assumed to be identical across operating systems or controller models.
* Hats use -1 for neutral and clockwise directions 0..7 starting at up.
  Cardinal bindings also match neighbouring diagonals. Linux evdev D-pads
  represented by `ABS_HAT*` are exposed as two signed axes instead.
* Mice use `TInputDeviceKind.Mouse`. Button codes `MouseLeft`, `MouseRight`,
  `MouseMiddle`, `MouseBack`, `MouseForward` are 0..4 on all three backends.
  Windows Raw Input supplies these five standard buttons; extra vendor buttons
  programmed as keyboard macros are not additional native mouse buttons.
* `RelativeAxis` is separate from normalized controller `Axis`. `MouseX` and
  `MouseY` contain accumulated motion since the last backend poll;
  positive X/Y means right/down. `MouseWheel` and `MouseHorizontalWheel` contain
  wheel deltas, positive up/right. Windows uses raw counts and wheel detents,
  Linux window input uses pointer-coordinate deltas and legacy wheel steps,
  and macOS uses AppKit movement/scroll deltas, including trackpad input.
  Motion and scroll units are platform-specific. These values are
  consumed once and return to zero on the next poll. Polling cannot recover
  relative motion lost by an OS queue overflow.
* Mouse buttons and wheel directions can be captured normally. Pointer motion
  is excluded from capture by default so moving to the capture button cannot
  steal a binding. Use `BeginCapture(Action, DeviceId, True)` to include motion.
  Relative bindings are pulses, with no controller-axis normalization or
  hysteresis; wheel pulses also work for fractional detents.
* Capture ignores already-held keys/buttons until they are released. Axes
  resting near the centre use origin 0; axes resting at an endpoint use origin
  -1/+1, which allows generic triggers. Start capture with **sticks centred and
  triggers released** so their rest positions can be determined correctly.
  Intermediate off-centre axes must return to neutral before capture.
* Default axis press/release thresholds are 0.65/0.45 of travel from the rest
  position. Bindings expose thresholds and `AxisOrigin` for manual calibration.
* `BeginCapture(Action, DeviceId)` limits capture to a selected device; an empty
  ID listens to all devices. `CancelCapture` aborts and `TakeCaptured` consumes
  the result once. Captured bindings are not added automatically.

## Device list policy

The ordinary list follows a conventional game-input model:

1. `Keyboard` (`SystemKeyboardId = system:keyboard`), if a keyboard is present.
2. `Mouse` (`SystemMouseId = system:mouse`), if a pointer is present.
3. Each separate gaming device: gamepads, joysticks, wheels and multi-axis controllers.

Keyboard and mouse bindings select the aggregate source, not physical hardware.
Multiple keyboards feed one keyboard state; on Windows held states from different
interfaces are ORed. Multiple mice feed one mouse source and movement is summed.
The aggregate IDs remain unchanged when physical peripherals are replaced.
Aggregate names have no vendor/product/serial identity. An inaccessible source
can remain listed with `Available=False`; absence removes it from the list.

Gaming interfaces sharing a native physical identity are combined. Windows uses
PnP ContainerID, Linux a resolved sysfs parent, and macOS serial/location with a
registry-ID fallback. Identical vendor/product IDs alone never merge gamepads.
Virtual gaming devices are allowed. This is an approximate native implementation
of the model used by SDL; SDL is neither linked nor required, and FMXInput does
not provide SDL's controller mapping database or every vendor report protocol.

`AllInterfaces` is a diagnostic mode for controller interfaces only. Keyboard
and mouse remain abstract in every mode. `RawDevices` exposes backend metadata
for diagnostics; the demo deliberately displays only the ordinary list.
Changing controller list mode can change controller IDs and requires rebinding.

## Profiles and device identity

`SaveBindings(Stream)` writes a UTF-8 JSON profile. `LoadBindings(Stream)`
validates the version, element kinds, axis origins and thresholds before
replacing any existing bindings. It does not rescan or reset native devices.
Use a new/truncated stream when saving. Profiles are limited to 1 MiB on load.

Keyboard/mouse IDs are the cross-platform aggregate constants above. Profiles
created with previous per-device keyboard/mouse IDs must be rebound.

Gaming device IDs are backend-specific and deliberately separate from names.
DirectInput uses an instance GUID, Linux vendor/product plus serial/physical
path, and macOS vendor/product plus serial/location. Physical grouping uses the
native physical identity where available. Fallback IDs can change with ports,
drivers or system configuration. Identical devices without a unique serial may
need explicit reassignment. Controller IDs and element codes are not promised
to be portable between operating systems.

XInput only exposes slots 0..3, so its IDs represent **player slots**, not
permanent physical controllers. Its device names/serials cannot be reliably
recovered from XInput alone. XUSB device interfaces identified by `IG_` and
vendor/product are excluded from DirectInput to avoid double enumeration;
unusual virtual drivers may need additional identification rules.

## Platform details

### Windows

Only system `user32`, `dinput8` and XInput DLLs are used. XInput is loaded from
System32 (`xinput1_4`, with `xinput9_1_0` fallback). Other HID gamepads use
DirectInput, including enumerated buttons, absolute axes and POVs.

Raw Input registration is nonexclusive and leaves normal FMX/VCL keyboard
messages enabled. A hidden window receives individual keyboard events and is
serviced by `Poll`. Registration has no INPUTSINK flag: only foreground
application input is received. Use **one Windows backend per process**: Windows Raw Input
registration is shared by device class within a process. Coordinate with any
other component that registers keyboards through Raw Input.

### Linux

Keyboard/mouse are received from window events, never by opening their evdev
nodes. In GTK3/X11 hosts the backend dynamically attaches a non-consuming GDK
filter to the already loaded toolkit. It handles core X11 and XInput2 local
events and reads keyboard/pointer presence from the default GDK seat. XWayland
also works with this adapter. It does not initialize GTK or steal its event queue.
The standard Xorg/XWayland evdev keycode offset (8) is used for physical positions.

Hosts with their own event loop can forward `ProcessX11Event` (with an already
obtained XI2 cookie), `ProcessXInput2Event`, or the decoded `KeyEvent`,
`MouseButtonEvent`, `MouseMotionEvent`, and `MouseWheelEvent` calls.
Call `SetWindowInputPresence` on seat/capability changes and `Reset` on focus loss.
For example a native Wayland host passes `wl_keyboard` evdev codes directly to
`KeyEvent` and forwards `wl_pointer` buttons/motion/axis events after converting
button codes and scroll direction. **No automatic native Wayland adapter is
implemented**; without an adapter desktop sources report `Available=False`.
Cursor locking/raw relative-pointer protocols are not implemented by this example.

Only gaming devices open `/dev/input/event*`. Enumeration reads sysfs; state is
queried with `EVIOCGKEY` and `EVIOCGABS`. No exclusive grab is used. Devices denied
by session ACLs stay listed with the actual error and `Available=False`. The host
application's packaging/session arranges gaming-device permissions; the library
does not change permissions or require root. Keyboard/mouse window input does
not require evdev access.

### macOS

Keyboard/mouse use an AppKit **local** `NSEvent` monitor on the main thread.
Events are returned unchanged to the normal FMX/AppKit dispatcher. Physical
`keyCode` positions are mapped to USB HID usages; characters/text layouts are
not used for gameplay bindings. Movement, buttons and scrolling feed aggregate
state. Polling while inactive and explicit `Reset` clear desktop state.

Presence is read from IOKit registry metadata without opening keyboard/mouse
HID devices. IOHIDManager matches only joystick, gamepad and multi-axis gaming
collections, including conventional HID wheels. It polls their controls through
the creation thread's CFRunLoop. Keyboard/mouse input uses no global tap and
requests no Input Monitoring or Accessibility permission. The host must run
its normal AppKit event loop; use the UI thread.

Sandbox/device policy can still restrict gaming-device access. Vendor-specific
report protocols and a GameController fallback for devices exposed only through
that framework are not implemented. Controller compatibility is therefore less
extensive than SDL's full set of backends.

## FMX device capture demo

Open `examples/FMXDemo/FMXInputDemo.dproj` in RAD Studio. The entire interface
is defined in `InputDemo.Main.fmx` and can be edited in the form designer.
The Pascal unit populates device/control data and handles input; it does not
create UI controls. The project uses only FMX and the library's native backends,
with no dependency on RetroMul or SDL.

Select a keyboard, mouse or controller in **Input source**. The grid shows its controls
and current values; the log records changes only from that selected device.
**Capture next input** assigns a key, button, axis direction or D-pad direction
to a demonstration action. Its pressed/released state appears below the capture
button. Release previously held controls before capture. **Cancel** stops capture;
**Clear log** clears the displayed history. Axis changes below 0.05 are omitted
from the log to limit noise, while the grid continues to display their values.

Input pauses and held states clear when the window loses focus. Switching
devices clears the captured action. Unplugging the selected device leaves the
selection empty; devices refresh automatically and through **Refresh**.
The list contains one aggregate keyboard, one aggregate mouse and each separate
gaming device. Unplugging one of several keyboards/mice keeps the aggregate
source selected; removing the last one removes it. **Capture mouse motion** opts
into capturing pointer movement. The selected source ID is displayed.
Linux gaming devices require access to their `/dev/input/event*` nodes;
keyboard/mouse do not. macOS keyboard/mouse use local AppKit input.
Linux FMX builds additionally need FMXLinux and a
configured target SDK; macOS builds need the corresponding RAD Studio SDK.

Build both Windows demos and run the FMX resource/interaction regression tests:

```powershell
./tests/Build.ps1 -Targets Win32,Win64 -FMXDemo
```

Executables are written to `build/Win32` and `build/Win64`. `FMXDemoTests` loads
the real `.fmx` with a fake backend and verifies selection, foreign-device
filtering, capture, keyboard/gamepad display, release, focus loss and disconnect.
The interactive `FMXInputDemo` executable is built without being launched by
the script. Native Linux/macOS demo execution must be tested on those systems.
The form unit compiles for Linux64, macOS Intel and macOS ARM64. Win32/Win64
demo builds and regression tests pass; the Win64 form was also opened and polled
with the real Windows backend. A physical gamepad was not attached during testing.
On the development PC the ordinary list contains `Keyboard [system:keyboard]`
and `Mouse [system:mouse]`. Physical peripherals and their macro interfaces do
not appear as separate selectable sources.

## Build and validation

Linux sysfs metadata is read to EOF without trusting the file's reported size.
These generated attributes can report 4096 bytes while returning only a few
characters; `TFile.ReadAllText`/`ReadBuffer(Size)` would raise `EReadError`.
Optional inaccessible metadata is skipped. Denied gaming-device evdev access
keeps the device in the list with `Available=False` and the actual errno/message,
instead of preventing application startup. Sysfs reader regression tests cover
nominal sizes, partial UTF-8 reads and EOF on Windows and Linux. The console
tests can additionally read a real attribute, for example on Linux:

```sh
./InputTests /sys/kernel/uevent_seqnum
```

From a Windows PowerShell with Delphi command-line compilers on PATH:

```powershell
./tests/Build.ps1
./tests/Build.ps1 -Targets Win64,Win32 -NativeProbe
```

The script compiles all four units for Win32, Win64, Linux64, macOS Intel and
macOS ARM64 with range/overflow checking. It builds and runs standalone fake
backend regression tests on Windows. Cross-platform unit compilation does
not link or execute Linux/macOS programs and needs no remote platform SDK.

`examples/InputProbe.dpr` is a framework-free console example: list devices,
or run with `--capture` to capture a binding and save `input-profile.json`.
Link/run the example on Linux/macOS using a configured RAD Studio target SDK.
Keyboard/mouse capture on Linux/macOS requires a host window event loop;
the standalone console probe is primarily useful for gaming devices there.

Verified with Delphi 13 / compiler 37.0 on 2026-10-03:

* Win32/Win64: core, native mouse-packet and FMX demo tests pass. Native
  enumeration returns one keyboard and one mouse. No gamepad was attached.
* Linux64: native Ubuntu/WSL tests cover X11/XInput2 decoding, window state,
  focus loss, aggregate devices and live sysfs reads. `LinuxGdkTests.dpr`
  additionally verifies native GTK3/X11 seat discovery and delivery through
  the actual GDK filter using an unmapped test window. Run its executable with
  `GDK_BACKEND=x11 ./LinuxGdkTests` after linking with a configured Linux SDK.
* macOS Intel/ARM64: backend units compile; runtime permission behaviour and
  physical controller handling require verification on a Mac.
* Native Wayland integration and physical gaming-device compatibility are not
  claimed as tested.

## API references

* [Raw Input](https://learn.microsoft.com/en-us/windows/win32/inputdev/about-raw-input)
* [PnP device containers](https://learn.microsoft.com/en-us/windows-hardware/drivers/install/devpkey-device-containerid)
* [XInput and DirectInput](https://learn.microsoft.com/en-us/windows/win32/xinput/xinput-and-directinput)
* [Linux input API](https://docs.kernel.org/input/input.html)
* [Linux relative events and wheel handling](https://docs.kernel.org/input/event-codes.html)
* [IOHIDManager](https://developer.apple.com/documentation/iokit/1438371-iohidmanagersetdevicematching)
* [Local AppKit events](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/EventOverview/MonitoringEvents/MonitoringEvents.html)
* [GDK window filters](https://docs.gtk.org/gdk3/method.Window.add_filter.html)
* [SDL X11 event backend](https://github.com/libsdl-org/SDL/blob/main/src/video/x11/SDL_x11events.c)

## License

MIT; see [LICENSE](LICENSE). The repository's original license is preserved.
