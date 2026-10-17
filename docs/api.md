# Site API

Authenticate management/API requests with `Authorization: Bearer SITE_TOKEN`, or with `?token=SITE_TOKEN` for the browser. Invalid credentials return an empty 404. Do not send management tokens in source-control files or logs. Responses containing private data use no-store and no-referrer.

| Method | Path | Result |
| --- | --- | --- |
| GET | `/api/guide` | Current guide and starter instructions |
| GET | `/api/screens` | Every logical screen with revision, instructions, profile, scene, publication and status |
| GET | `/api/screens/{id}` | One screen |
| GET | `/api/assets/{id}/image` | Current published PNG |
| GET | `/api/assets/{id}/scene` | Current scene art |
| GET | `/api/assets/{id}/reference` | First scene reference for the local day |
| GET | `/api/receipts/{request_id}` | Saved write result |
| POST | `/api/save_screen` | Create/update screen preferences |
| POST | `/api/save_scene` | Save scene and pin same-day identity |
| POST | `/api/publish_screen` | Atomically switch the screen's image |

All writes need a UUID `request_id` and integer `expected_revision`. New screens omit `id` and use revision 0. Existing writes must match the current revision. Every successful screen, scene or publication mutation increments it. Retry identical input with the same UUID; reusing an ID for different input is a 409. The registry and receipts commit together with a database compare-and-swap.

`save_screen`: name, instructions, refresh_seconds (60–86400), active boolean, optional profile JSON. Unknown/extra top-level fields are rejected. Setting active=false revokes firmware reads but preserves the record.

`save_scene`: id, date (YYYY-MM-DD), character, identity, condition, phase (morning/afternoon/evening/night), prompt, png_base64. First image for a local date remains the reference; changing character/identity on the same day is rejected by default. For an explicit owner request only, send `replace_daily_character: true` and a nonempty `replacement_reason` (up to 500 characters). Both fields are required together. This pins the replacement image as the new reference, records `scene.replacement.reason` and `.at`, and retains revision/idempotency protection. Scheduled refreshes must not use this override. Renderers additionally verify local date, phase and condition before drawing live data.

`publish_screen`: id, png_base64, metadata (JSON, max 16KB). PNG validation checks signature, dimensions, 1/2-bit grayscale format, chunk checksums, bounded decompression and pixel scanline structure. Only IHDR, IDAT and IEND are accepted. Use updater/render.py to normalize input. Images must be 800×480 and at most 90,000 bytes.

The current and last 19 publication URLs remain accessible to an active screen, avoiding a race between metadata polling and image fetch. Older R2 objects are not automatically removed yet. The prototype registry is bounded at 1.5MB and 10,000 durable write receipts; reaching a limit fails explicitly rather than losing retry protection. These are storage limits, not a two-device cap; long-running installations need retention maintenance before reaching them.

## Firmware

`setup_url` is `SITE_ORIGIN/d/{logical_id}/{derived_key}`. Keys are HMAC-derived from SITE_TOKEN and cannot be used as the management token. There is no MAC-address registration requirement. The logical ID determines content; multiple devices may share it.

- `GET {setup_url}/api/setup`: HTTP 200, JSON status 200, api_key, friendly_id, image_url and refresh_rate.
- `GET {setup_url}/api/display`: HTTP 200, JSON status 0, immutable filename, absolute image_url, refresh_rate in seconds.
- `POST {setup_url}/api/log`: bounded response; raw hardware logs are not persisted.
- `GET {setup_url}/image/{publication_id}.png`: direct PNG with Content-Length.

Publish the first image before pairing. A screen with no image returns pending status. Missing/invalid keys and disconnected screens return 404. Rotating SITE_TOKEN rotates setup keys as well as the management token.

A publication receipt is persistence evidence. `seen` means a firmware metadata request arrived. `image_sent` means the server prepared an image response. None proves physical rendering.
