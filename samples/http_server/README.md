# HTTP Server Sample

WiFi AP mode with an HTTP server on port 80: serves a welcome page, a small
REST API (`/status`, `/led/{id}`, `/echo`), and a file browser for the SD
card (`/files`, `/files/*`).

## Build

```sh
west build --build-dir build-http-server --board clip/nrf5340/cpuapp samples/http_server
west flash --build-dir build-http-server && nrfutil device reset
```

## Usage

1. Device starts a WiFi AP — SSID `ClipHTTP_XXXX`, password `12345678`
2. Connect your phone/PC to the AP
3. Open `http://192.168.4.1/` in a browser (or curl):
   ```sh
   curl http://192.168.4.1/status
   curl http://192.168.4.1/files
   curl -O http://192.168.4.1/files/REC/20260319_120000/001.opus
   ```
