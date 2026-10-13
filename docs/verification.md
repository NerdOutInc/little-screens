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
