# SDK examples

This standalone real-device example uses the public `clip` package API. It
shows a real-time analysis path against a live Clip over BLE, with no CLI
wrapper or unrelated features. From a source checkout, `_bootstrap.py`
inserts `sdk/src` onto `sys.path`; install the relevant extras for runtime
dependencies.

| Example | Purpose |
|---|---|
| `demo_stream_fft_display.py` | Real-time terminal FFT spectrum of an RTC stream through the SDK `JitterBuffer` + Opus decoder + NumPy FFT, with an adaptive noise floor and hard spectral gate |

The example runs until `Ctrl-C` when `--duration` is omitted. Omitting
`--address` scans for a BLE device named "Clip" and uses the first match.

## `demo_stream_fft_display.py` — live FFT spectrum demo

Install the BLE and examples extras (see `sdk/README.md` for full install
instructions; skip if already installed):

```sh
cd /path/to/reSpeaker_Clip/sdk
python -m pip install -e '.[ble,examples]'
```

Examples:

```sh
python examples/demo_stream_fft_display.py --address AA:BB:CC:DD:EE:FF  # replace with your device address
python examples/demo_stream_fft_display.py --duration 10 --depth-frames 5
```
Logs:
```sh
python examples/demo_stream_fft_display.py --address C4:F1:79:A4:09:A0 --depth-frames 5 --duration 50
RTC session: 00000000082552
Streaming for 50s ...

frames received : 2503
bytes received  : 191846
seq discontin.  : 0
avg inter-frame : 20.0 ms (max 120 ms)

Live spectrum (SDK JitterBuffer + Opus decode + FFT):
  depth target    : 5 frames (100 ms)
  frames in       : 2503
  frames processed: 2503
  start wait      : 7 silent ticks
  underruns       : 17 (17 silent ticks)
  catch-up drops  : 0
  decode errors   : 0

Queue depth distribution (JitterBuffer.buffered):
  at feed  (n=2503): p50=5  p95=6  min=1  max=7  mean=5.3  (frames)
  at get   (n=2527): p50=5  p95=6  min=0  max=7  mean=5.2  (frames)
  depth=0 at get : 17 (0.7%) = underruns

Latency (on_frame arrival → FFT end, 2503 samples):
  total    : p50=96.1  p95=118.7  min=10.3  max=124.6  mean=95.4  (ms)
  queue    : p50=95.8  p95=118.6  min=10.2  max=127.3  (ms)
  decode   : p50=0.08  p95=0.12  min=0.02  max=0.47  (ms)
```

This is the analysis path: the `on_frame` callback feeds Opus packets
straight into a `LiveSpectrum` (SDK `JitterBuffer` → Opus decode →
NumPy `rfft` → terminal Unicode bar chart) on a dedicated thread.

The spectrum is rendered as a single-line Unicode bar chart (` ▁▂▃▄▅▆▇█`,
8 sub-levels per cell) that refreshes in place each frame.

**Noise suppression.**  A per-band adaptive noise floor (fast attack /
slow release envelope follower) tracks the mic's noise baseline, and a
hard spectral gate blanks anything below `floor + margin` to a fixed
-80 dB.  The noise region is therefore a constant blank and never
flickers frame to frame — only signal genuinely above the baseline
shows up.  There is no time smoothing, so no extra latency is added.

It accepts `--depth-frames` (jitter buffer depth in frames, default 5;
`0` = pass-through).  The processing thread is paced at 20 ms/frame
(the natural frame period) to simulate the sound card's consumption
rate and keep the JitterBuffer dynamics meaningful, and starts lazily
on the first frame to avoid spinning silence during BLE connection
parameter negotiation.
