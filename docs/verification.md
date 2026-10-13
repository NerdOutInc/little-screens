# First-milestone verification

Checked October 13, 2026 on the development Mac. These are separate evidence boundaries.

| Check | Result |
| --- | --- |
| Swift build and XCTest | 12 tests passed after final review, including credential redaction and repeated HTTP list headers. |
| Packaged native app | Release executable/resource bundle built; plist validation and ad-hoc signature verification passed. |
| Native app startup | Running with separate loopback agent and LAN firmware listeners; persistent store and Keychain initialized. |
| Help page | Loaded in Codex's built-in browser with readable starter prompt and all nine registered tools. |
| Actual WebMCP | Codex discovered and invoked server status, timed pairing, confirmation, and test publication against both an isolated simulator and the real app. |
| Actual HTTP delivery | Repeatable smoke test passed: simulated OG called setup and display, fetched the new 48,062-byte, 800×480, 1-bit BMP, matched SHA-256 to the receipt, then lost access after disconnection. |
| Image preview | PNG inspected in-browser. XCTest compares decoded BMP/PNG orientation and sampled black/white pixels. |
| Multiple devices | Three simulated identities retain independent credentials, images, and revisions. |
| Physical OG | Passed on firmware 1.8.17. Setup registered the OG, the user matched its displayed code, and the real device fetched the subsequent test publication. The user confirmed its name, matching code, and “HELLO FROM CODEX” on the physical screen. |
| Native Help menu click | Implemented with `NSWorkspace.open` to use the default browser. Menu-only app was not discoverable by this session's native UI automation; direct click still needs verification. |
| Login startup / hourly updates | Not implemented or tested in this milestone. |

The firmware's setup renderer can overlay its standard Friendly ID / hosted-service instructions on the server's image. The local flow continues with Codex. Source checked in the official [firmware setup service](https://github.com/usetrmnl/trmnl-firmware/blob/main/src/services/device_setup.cpp) and [message renderer](https://github.com/usetrmnl/trmnl-firmware/blob/main/src/display.cpp).

Run `swift test` and `python3 scripts/smoke-test.py` for repeatable local checks. Simulator evidence is not physical e-ink evidence. Runtime data and screenshots stay outside Git.

The first physical attempt exposed an HTTP parser compatibility bug: a firmware request had a repeated or otherwise unsupported header. The parser now supports standard field-name punctuation and combines repeated list-valued fields, including `Accept-Encoding`, while continuing to reject duplicate framing and credential fields. The same OG then completed its refresh without re-pairing. A regression test covers list headers and rejects duplicate Host, Content-Length, ID, and Access-Token.

The app still reports `physical_display_verified: false` because its protocol has no trustworthy display acknowledgement. The physical confirmation above came from the user, separately from server telemetry. No device MAC addresses, credentials, household images, or private source data are included in this repository.

## Weather/agenda milestone (0.2.0)

Checked later on October 13, 2026, using the existing paired device and persistent installation.

| Check | Result |
| --- | --- |
| Source gathering | Weather Underground's visible current conditions, forecast, and current UV were read in Codex's browser. All eight accessible Google calendars were queried through Codex's Calendar connector; full-event reads recovered missing all-day dates. No external-service integration was added to the app. |
| Live WebMCP | Thirteen tools discovered. `get_device_profile`, `save_dashboard`, `render_dashboard`, and `publish_screen` invoked successfully through the Help page in Codex's built-in browser. |
| Saved preferences | Weather URL, timezone, units, all-calendar scope, lookahead, current-UV-only choice, and layout instructions saved through the app, with device/profile revisions and durable receipts. |
| Preview/publication | A live snapshot was staged and inspected at 800 × 480 before publication. The first layout showed 13 events with complete visible titles and a later-event overflow count. |
| Physical feedback | The user confirmed the weather/calendar dashboard appeared, but reported that agenda text was too small. Event titles were enlarged from 14 to 18 pixels, time labels to 14 pixels, and calendar legend to 14 pixels. Readability of the revised screen awaits physical confirmation. |
| Tests | All 17 Swift tests passed, including staged publication/restart recovery, wrong-device and stale-profile rejection, render expiry, timezone/all-day boundaries, overflow, and invalid source data. The preview now uses the exact thresholded black/white pixels used by the BMP, including emoji. |
| HTTP/package | Thirteen-tool HTTP smoke test, JavaScript syntax, release packaging, plist validation, and ad-hoc signature verification passed. |
| Remaining boundaries | Login startup and hourly automation remain unimplemented. A fresh-chat update from only the Help URL and multi-device physical dashboard operation still need separate testing. |

The app marks stale data when rendering. If no later render runs, an e-ink screen keeps its previous pixels and printed source timestamps; it cannot dynamically acquire a stale label. Evening precipitation uses the source's explicit “Tonight” period rather than being mislabeled as an all-day probability. Unknown values remain unknown.
