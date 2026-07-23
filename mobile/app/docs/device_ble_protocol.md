# Device BLE and AT protocol

> **Canonical protocol reference** lives with the Flutter SDK:
> [`sdk/flutter/docs/DEVICE_BLE_PROTOCOL.md`](../../sdk/flutter/docs/DEVICE_BLE_PROTOCOL.md)
>
> **Business flow** (when to issue DOWNLOAD, resume after connect, index sync):
> [recording_flow.md](recording_flow.md) section 3.

The SenseCraft Voice app implements device I/O through the
`sensecraft_voice` package (`path: ../sdk/flutter`). Update protocol
details in the SDK doc; keep product-specific recording / transfer logic in
this repo's [recording_flow.md](recording_flow.md).
