# SDK tools

These tools are new and independent of `applications/clip/tests/tools`.
Their implementation lives in the installed `clip.tools` package.  The scripts
in this directory are only development wrappers for the same implementation.
Install the SDK to register the commands on `PATH`.

```sh
cd /path/to/reSpeaker_Clip/sdk
python -m pip install -e '.[ble]'
```

| Installed command | Purpose |
|---|---|
| `clip.terminal` | Interactive current-firmware AT terminal over BLE or Wi-Fi UDP |
| `clip.sync` | Download newest, selected, or all sessions; optional post-success delete |
| `clip.record` | Start/stop a recording with optional duration and periodic bookmarks |
| `clip.stream` | Live RTC audio streaming over BLE; `.bin` received-packet capture + stream diagnostics (streaming only) |
| `clip.web` | Local browser control panel; requires the `web` extra |
| `clip.wifi` | BLE-to-Wi-Fi handoff using the host platform's native Wi-Fi tool |

Examples:

```sh
clip.terminal --transport ble --address AA:BB:CC:DD:EE:FF
clip.terminal --transport udp
clip.sync --transport udp --all --output recordings
clip.record --transport ble --mode enhanced --duration 60
clip.stream --transport ble --address AA:BB:CC:DD:EE:FF
clip.web --transport udp
clip.wifi --address AA:BB:CC:DD:EE:FF
```

During SDK development, `python tools/terminal.py` (and the matching wrappers,
including `stream.py`) run the exact same installed
implementation. `clip.stream` runs until `Ctrl-C` when `--duration` is omitted.
The UDP default is the actual firmware port `8089`, not the old tool's `8080`.

For the web panel install its extra and browse to the printed loopback URL:

```sh
python -m pip install -e '.[web]'       # Wi-Fi/UDP
python -m pip install -e '.[web,ble]'   # BLE
clip.web --transport ble
```

The server deliberately defaults to `127.0.0.1`. If you expose it on a LAN with
`--bind`, put it behind suitable network access control because it can control
recording and delete sessions.

`clip.stream` does one job: it runs an RTC session and writes the
received-packet log — `rtc-<session>.bin.part` while streaming, atomically
renamed to `rtc-<session>.bin` on a normal stream end. RTC streaming is
BLE-only; the tool rejects `--transport udp` up front.

When `clip.web` starts with `--transport ble`, its **Switch transfer to Wi-Fi**
button starts the device AP over BLE, automatically joins the host to it, and
switches the web server's connection to UDP. The backend selects `nmcli` on
Linux, `networksetup` on macOS, or `netsh` on Windows. The browser only asks the
local Python server to perform this operation; it never receives the Wi-Fi
password or attempts to change the operating-system network itself.
