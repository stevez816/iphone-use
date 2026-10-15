# iPhone Use

Let an AI agent use a real iPhone from your Mac. Nothing is installed on the phone.

<p align="center"><img src="docs/demo.gif" width="300" alt="iPhone Use tapping 12 × 34 = on a real iPhone's Calculator"></p>

iPhone Use is a small macOS app. It reads the iPhone's screen over a USB cable and
taps and types through Bluetooth, posing as a keyboard and mouse. Your agent gets
an MCP server (and a plain HTTP API) with `screenshot`, `tap`, `swipe`, `type_text`,
`press_key` and `home`.

Because it drives a real, unlocked iPhone the way a person would, apps behave the
way they do in your hand: your accounts, App Store installs, push notifications,
iMessage. No simulator, no developer account, no app on the phone.

## How it works

```
                USB cable: screen frames (CoreMediaIO, like QuickTime)
   ┌──────────┐ ◀──────────────────────────────────────────────── ┌────────┐
   │   Mac    │                                                    │ iPhone │
   │iPhone Use│ ─────────────────────────────────────────────────▶ │        │
   └──────────┘   Bluetooth LE: keyboard + mouse (HID over GATT)   └────────┘
        ▲                                                   AssistiveTouch turns
        │ MCP / HTTP                                        the pointer into taps
     your agent
```

- **Screen.** A trusted iPhone becomes a video capture device once a Mac app sets
  `kCMIOHardwarePropertyAllowScreenCaptureDevices`. iPhone Use keeps the latest frame.
- **Input.** The Mac publishes a Bluetooth LE HID service with `CBPeripheralManager`.
  The iPhone pairs with it like any keyboard. Classic Bluetooth HID is not an option
  on current macOS because `bluetoothd` owns its L2CAP channels.
- **Taps.** With AssistiveTouch on, iOS shows a pointer for mice. iPhone Use's report
  map has an absolute pointer (X and Y from 0 to 32767) that iOS maps straight to the
  screen, so a tap lands exactly where it is aimed, no calibration. iOS ignores the
  absolute pointer's buttons, so the click itself goes through a second, relative
  mouse.
- **Typing.** A standard keyboard report, US layout.

## Requirements

- A Mac with Bluetooth LE (any Apple Silicon Mac). Tested on macOS 26.
- An iPhone and a USB **data** cable. Charge-only cables give power and no screen.
- Xcode command line tools to build.

## Setup

```sh
git clone https://github.com/xhoantran/iphone-use && cd iphone-use
./scripts/build-app.sh            # builds build/iPhoneUse.app
open build/iPhoneUse.app          # allow Bluetooth and Camera when asked
```

Then, once:

1. **Plug the iPhone in**, unlock it and tap **Trust**. On Apple Silicon, if the Mac
   asks "Allow accessory to connect?", click **Allow**. If the screen never shows up,
   check System Settings > Privacy & Security > *Allow accessories to connect*.
2. For a new Bluetooth bond, open a two-minute pairing window on the Mac:
   `curl -X POST localhost:7390/bluetooth/pairing -H 'Content-Type: application/json' -d '{"device":"<device-id>"}'`
   (Replace `<device-id>` with your USB-connected phone's ID from `/devices`.)
   On the iPhone, **Settings > Bluetooth**: select the peripheral and confirm the
   system Bluetooth or iPhone Use pairing prompt on the Mac, and the prompt on the
   iPhone if present. If a code is shown, check that both devices show the same code.
   An attempt times out after 30 seconds (the app's own prompt cancels after 25);
   reopen the window before retrying if it expires.
   Opening a window does not bind Bluetooth input to that USB screen: the pointer
   verification still has to identify the correct phone.
3. On the iPhone, **Settings > Accessibility > Touch > AssistiveTouch**: turn it on.

Check it:

```sh
curl localhost:7390/status
# {"bluetooth":"1 connected, advertising as iPhone Use","devices":[{"id":"...","name":"iPhone",
#   "bluetooth":true,"width":1180,"height":2556}],"unmatchedHosts":[]}
```

iPhone Use runs as a menu-less background app. Quit it with `pkill -x iphone-use`.

## Use it from an agent (MCP)

The same binary is the MCP server. It talks to the running app over localhost.

Claude Code:

```sh
claude mcp add iphone-use -- "$PWD/build/iPhoneUse.app/Contents/MacOS/iphone-use" mcp
```

Any other MCP client:

```json
{
  "mcpServers": {
    "iphone-use": {
      "command": "/path/to/iPhoneUse.app/Contents/MacOS/iphone-use",
      "args": ["mcp"]
    }
  }
}
```

Screenshots are scaled so the long edge is 1200 px. Tap and swipe coordinates are
pixels of that screenshot. Every action returns a fresh screenshot.

| Tool | Arguments |
| --- | --- |
| `list_devices` | |
| `screenshot` | |
| `tap` | `x`, `y` |
| `long_press` | `x`, `y`, `seconds` |
| `swipe` | `x1`, `y1`, `x2`, `y2`, `seconds` |
| `type_text` | `text` (ASCII) |
| `press_key` | `key`, `modifiers` (`cmd`, `shift`, `alt`, `ctrl`) |
| `home` | |

Every tool except `list_devices` also takes `device`, needed only when more than one
iPhone is connected.

`press_key` with `space` + `cmd` opens Spotlight, which is often the fastest way to
open an app: Spotlight, type the name, `enter`.

## HTTP API

Everything listens on `127.0.0.1:7390` (set `IPHONE_USE_PORT` to change it).
Coordinates are pixels of the full-resolution screen unless you pass `width` and
`height` for the image they came from, `maxEdge` for a screenshot taken with that
`maxEdge`, or `"fraction": true` for 0 to 1. With several phones, add `"device"` to the
body (or `?device=` to a GET): the phone's id or name from `/devices`.

```sh
curl localhost:7390/devices
curl localhost:7390/screenshot -o screen.jpg                  # ?format=png, ?maxEdge=1200, ?device=
curl -X POST localhost:7390/tap   -d '{"x":590,"y":1278}'
curl -X POST localhost:7390/swipe -d '{"x1":590,"y1":1900,"x2":590,"y2":700,"duration":0.4}'
curl -X POST localhost:7390/type  -d '{"text":"hello"}'
curl -X POST localhost:7390/key   -d '{"key":"space","modifiers":["cmd"]}'
curl -X POST localhost:7390/home
```

`scripts/record.sh demo.mp4 [fps] [device]` records a phone's screen until you press Ctrl-C.

## Several iPhones

Plug each phone in and pair each one with **iPhone Use** in its Bluetooth settings.
Every phone gets its own screen capture and its own input queue, so phones work in
parallel.

Bluetooth does not say which phone a connection belongs to. So when a new phone
connects, iPhone Use moves its pointer along a path and back to the starting point,
then verifies that exactly one USB screen shows that movement. Keep the phone unlocked,
AssistiveTouch enabled, and its screen still while this runs (about 3 seconds per host).
Even one USB phone and one Bluetooth host must pass this check: they may be different
phones. The verified match is saved in
`~/Library/Application Support/iPhoneUse/pairings.json`. Each phone is matched once. If a
match goes wrong:

```sh
curl -X POST localhost:7390/match -d '{"force":true}'            # forget and match again
curl -X POST localhost:7390/pair  -d '{"device":"<id>","host":"<uuid from unmatchedHosts>"}'
```

`/match` with `force` removes the present phones' old bindings **before** trying again.
A failed match leaves them unbound. Legacy, unversioned bindings are ignored because
older versions could save guesses. `/pair` is an explicit manual override, not a
Bluetooth pairing command: use it only after independently identifying the host UUID.
It rejects hosts that are not connected and keeps each host assigned to at most one
screen. Duplicate names or ID prefixes are rejected; use the full device ID.

## Troubleshooting pairing and control

A working screenshot proves only that USB capture works. It does not establish a
Bluetooth input connection. In `/status`, `bluetoothHosts` lists subscribed report
channels, `pairing` describes the Mac pairing handler, and each device's `bluetooth`
flag requires both a verified (or explicitly assigned) binding and a live HID host.
A tap needs both `absolutePointer` and `relativeMouse`; typing needs `keyboard`.
Control requests fail with an error if the binding or required channel is missing.
`ok: true` means input was accepted by the local Bluetooth transport, not that the
phone's screen response has been verified. Check a fresh screenshot after an action.

On the tested macOS 26.1 installation, `bluetoothd` rejected new peers with
"no one to handle the request", although previously bonded phones could connect.
Registration alone did not route incoming requests to the app. This build uses a
two-minute, single-peer pairing window, listens for the central's connection event,
and attaches a `CBCentralManager` client to that exact incoming peer UUID. It then
asks that client's **private** `CBPairingAgent` to initiate MITM-protected pairing.
Previously bonded peers do not consume the window. Pairing-agent method signatures
are checked before use; unavailable/incompatible versions are reported in `/status`.
No pairing request is accepted by the app without a local confirmation. First pairing
was verified with an iPhone 12 Pro running iOS 18.6, using a different Apple Account:
the system Bluetooth confirmation appeared, the encrypted bond succeeded, and all
four HID input reports were subscribed. This compatibility workaround uses private
Apple APIs and is not an App Store distribution solution; other macOS versions have
not been validated.

Initiate pairing from the intended phone and verify the corresponding Mac
confirmation. If no prompt arrives, collect diagnostics before
changing the phone's pairing records. Do not bind a different connected phone just
because it is the only host in `unmatchedHosts`.

```sh
./scripts/test-bindings.sh      # local regression checks; no phone input is sent
./scripts/diagnose.sh           # status and recent app logs; no screen images
```

On the tested iPhone 12 Pro running iOS 18.6, the pointer was visible on the physical
display, but the USB frames did not consistently show enough pointer contrast/movement
to pass automatic verification.
This intentionally leaves the phone unbound. For this repair, its host UUID was
identified from the synchronized first-pairing logs and physical pointer confirmation,
then explicitly assigned with `/pair`. A tap opened system search and Home returned
to the Home Screen; a second connected phone remained unmatched. This does not prove
automatic matching works on every iOS screen. Do not lower the verification threshold
or guess a binding just to make `bluetooth` become `true`.

After restarting the final build, the tested iPhone automatically restored all four
input reports and its saved binding. Tapping Back, scrolling Settings, opening search with Cmd-Space,
and returning Home were verified against fresh screenshots. The 44 local regression
checks, release build, and code-signature verification also passed.

Rebuilding with ad-hoc signing may cause macOS to request Bluetooth/Camera permission
again. Existing Bluetooth bonds and saved screen/host associations should survive an
app restart; reconnect from the phone's Bluetooth settings if its HID reports do not
automatically resubscribe.

## Limits

- Tested with two iPhones at once. Classic Bluetooth caps a Mac at 7 devices; iPhone Use
  runs on Bluetooth LE, whose limit depends on the Mac's Bluetooth chip and has not
  been measured.
- Typing is US ASCII. Other characters need the clipboard (not built yet).
- Portrait only has been tested.
- The phone must stay unlocked. Set Auto-Lock to Never while an agent is working.

## Credits

The idea comes from [TapKit](https://tapkit.ai). The hard parts of being a BLE
keyboard with CoreBluetooth (the long-form `1812` UUID, encrypted attributes, the
Report Reference descriptor) are written up in
[sryo/clak's notes](https://github.com/sryo/clak/blob/main/docs/corebluetooth-hid-notes.md).

## License

MIT
