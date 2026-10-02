# FMXInput

Standalone Delphi desktop input library for Windows, Linux and macOS. Despite
the repository name, it has **no dependency on FireMonkey, VCL or RetroMul**.
It uses Delphi RTL and operating-system APIs, without SDL, libevdev, helper
executables, drivers or bundled native libraries.

## Units

| Unit | Responsibility |
| --- | --- |
| `FMXInput.pas` | Device/value types, backend factory, action bindings, capture, JSON profiles |
| `FMXInput.Windows.pas` | Individual keyboards via Raw Input; XInput and DirectInput controllers |
| `FMXInput.Linux.pas` | Individual keyboards and controllers through Linux evdev |
| `FMXInput.MacOS.pas` | Individual keyboards and HID controllers through IOHIDManager |

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
No background worker or global application event handler is installed.

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

## Profiles and device identity

`SaveBindings(Stream)` writes a UTF-8 JSON profile. `LoadBindings(Stream)`
validates the version, element kinds, axis origins and thresholds before
replacing any existing bindings. It does not rescan or reset native devices.
Use a new/truncated stream when saving. Profiles are limited to 1 MiB on load.

`Device.Id` is backend-specific and is deliberately separate from the name.
Windows Raw Input uses a device interface path, DirectInput uses its instance
GUID, Linux uses vendor/product plus serial or physical path, macOS uses
vendor/product plus serial or location. These fallback identities can change
with USB ports, drivers or system configuration. Identical devices without a
unique serial may require explicit reassignment. Device IDs and controller
element codes are not promised to be portable between operating systems.

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
serviced by `Poll`. Use **one Windows backend per process**: Windows Raw Input
registration is shared by device class within a process. Coordinate with any
other component that registers keyboards through Raw Input.

### Linux

Enumeration reads `/sys/class/input/event*/device`; state is queried from
`/dev/input/event*` using `EVIOCGKEY` and `EVIOCGABS`. Authoritative snapshots
avoid reliance on an overflowing evdev event queue. No exclusive grab is used.
The implementation targets Linux64 and calls libc `open`, `close` and `ioctl`.

Devices denied by session ACLs/permissions remain listed with `Available=False`
and an error. Permissions must be arranged by the host application's packaging
or session; the library does not change system permissions or require running
the application as root. This is especially relevant to physical keyboards.

### macOS

System IOKit and CoreFoundation frameworks are used directly through public C
APIs. IOHIDManager matches keyboards, joysticks, gamepads and multi-axis
controllers, discovers HID input elements and polls their values. It is
scheduled on the creation thread's default CFRunLoop; polling services the
run loop with a zero timeout. Device access errors remain visible in the list.

Keyboard HID access may require **Input Monitoring** permission. The library
does not automatically prompt or change permissions. Sandbox/device policy
can also restrict access. This backend reads devices exposed as usable HID;
it does not implement vendor-specific report protocols or a GameController
fallback for controllers that expose only that framework's API.

## Build and validation

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

Verified with Delphi 13 / compiler 37.0 on 2026-10-02:

* Win32/Win64: regression tests pass; native enumeration finds attached HID
  keyboards. No physical gamepad was attached during verification.
* Linux64/macOS Intel/macOS ARM64: all units compile successfully.
* Linux/macOS hardware access and controller behaviour require testing on
  those systems; they are not claimed as runtime-verified.

## API references

* [Raw Input](https://learn.microsoft.com/en-us/windows/win32/inputdev/about-raw-input)
* [XInput and DirectInput](https://learn.microsoft.com/en-us/windows/win32/xinput/xinput-and-directinput)
* [Linux input API](https://docs.kernel.org/input/input.html)
* [IOHIDManager](https://developer.apple.com/documentation/iokit/1438371-iohidmanagersetdevicematching)

## License

MIT; see [LICENSE](LICENSE). The repository's original license is preserved.
