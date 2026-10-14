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
| Preview/publication | A live snapshot was staged and inspected at 800 × 480 before publication. The first layout showed 13 events with complete visible titles and a later-event overflow count. The revised layout shows nine nearest events, with one title deliberately truncated, and a count of 18 later event rows. |
| Physical feedback | The user confirmed the first dashboard appeared, but reported that agenda text was too small. Event titles were enlarged from 14 to 18 pixels, time labels to 14 pixels, and calendar legend to 14 pixels. The revised screen was published through WebMCP, the device requested its image, and the user confirmed: “Yes, this size works.” The readability preference is saved in the device profile. |
| Native restart | Existing device identity, profile, source snapshot, and publication survived the rebuilt app's restart. macOS requested access to the installation's existing Keychain item; after the user allowed it, both listeners resumed and WebMCP publication succeeded. |
| Tests | All 17 Swift tests passed, including staged publication/restart recovery, wrong-device and stale-profile rejection, render expiry, timezone/all-day boundaries, overflow, and invalid source data. The preview now uses the exact thresholded black/white pixels used by the BMP, including emoji. |
| HTTP/package | Thirteen-tool HTTP smoke test, JavaScript syntax, release packaging, plist validation, and ad-hoc signature verification passed. |
| Remaining boundaries | Login startup and hourly automation remain unimplemented. A fresh-chat update from only the Help URL and multi-device physical dashboard operation still need separate testing. |

The app marks stale data when rendering. If no later render runs, an e-ink screen keeps its previous pixels and printed source timestamps; it cannot dynamically acquire a stale label. Evening precipitation uses the source's explicit “Tonight” period rather than being mislabeled as an all-day probability. Unknown values remain unknown.

## Daily companion milestone (0.3.0)

Checked October 14, 2026. The native app was rebuilt with fourteen WebMCP tools, and the existing device profile was changed through the live Help page. Its new template uses a 200px weather/art column and 600px full-height agenda, original compact event time ranges, 18px titles, and no calendar-source numbers or legend. The staged preview showed 12 events across three days; one long title was deliberately truncated and 15 later rows were counted in the footer.

Codex read fresh weather and all eight accessible calendars. The Weather Underground current-UV panel remained unavailable, so UV was explicitly null. A new bathroom cat illustration was generated with the built-in ImageGen tool, normalized to 176×220, and saved through `save_daily_scene`. The app retains the first reference for the day and rejects changes to same-day character identity, mismatched weather/time phases, and publication of superseded scenes.

The inspected and published image is an 800×480, 10,700-byte PNG with actual bit depth 2, grayscale color type 0, and exactly four decoded values: 0, 85, 170, 255. The saved publication hash matches those bytes. All 21 Swift tests, the fourteen-tool HTTP smoke test (including scene upload and grayscale publication/download), JavaScript syntax, release build, plist validation, and signature verification passed. Test fixtures contain no personal source data.

A pre-existing OG diagnostic reported an incomplete BMP download. The HTTP writer now sends a final TCP message and allows the peer to finish, instead of cancelling immediately after local send completion. HTTP delivery tests pass; a lasting improvement on household Wi-Fi requires hardware observation.

The user confirmed that the new screen appeared on the physical OG and requested design changes. Visual approval and detailed grayscale/readability feedback remain pending. No recurring update task has been enabled. Scene changes are enforced when Codex submits a refresh; the local app does not generate art or fetch external data autonomously.


## Integrated scene and event notes (0.4.0)

Checked October 14, 2026. The user approved the published screen on the physical OG: “This layout works.” The right two-thirds contains a full-height agenda on a hanging towel; weather values are rendered into a bathroom mirror on the left. ImageGen made the text-free scene using the same daily character reference; the app draws all actual weather and event text. Titles are 20px bold, original time ranges 16px bold, and useful source-backed notes 14px regular. Seven upcoming rows fit across two days with no title truncation; the footer counts 20 later rows.

All eight accessible Google calendars were refreshed, with full-event reads for near-term notes. Weather came from the visible Weather Underground page; its current UV field remained unavailable and was sent as null. User preferences and approval were saved through real WebMCP calls, alongside scene metadata and publication receipts. The original same-day character reference survived the template change. Personal snapshots, artwork, device identifiers, and receipts remain in ignored local storage.

The published image is 800×480, 12,970 bytes, actual PNG bit depth 2 / grayscale type 0, with decoded values 0, 85, 170, 255. Its SHA-256 matches the publication receipt. All 23 Swift tests passed, including variable-height row fitting, word wrapping, optional-note compatibility, invalid detail lengths, template-specific image sizes, and same-day reference/notes persistence through a restart. The fourteen-tool HTTP smoke test exercised a full background, detailed agenda, PNG download/hash, and credential revocation. JavaScript syntax, release packaging, and signature checks passed.

Layout approval is saved per device. No recurring task has been enabled; the user requested scheduling guidance after approval. Login startup and an unattended scheduled update remain unverified.
