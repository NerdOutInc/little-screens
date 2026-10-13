# Project instructions

We're always having fun! We use humor in all contexts because it keeps things light and engaging.

Read `README.md` for the current product direction and distinguish planned behavior from implemented behavior.

- Build a small macOS menu bar app and local TRMNL server.
- Support a registry of devices with no hard-coded count. The user's initial setup is two TRMNL OG devices on one household network, each showing different content.
- Keep device IDs explicit. Give each device independent preferences, rendering, publication state, and error handling.
- Use Codex's browser or connected tools to gather external information. Do not add external-service integrations to the Mac app unless requested.
- Use a minimal local page with WebMCP tools as the intended agent interface. Verify actual Codex discovery and invocation before claiming compatibility.
- Make the app's homepage self-describing: an agent given only its URL should learn the available tools, guide device pairing, collaborate with the user on each dashboard, and save its preferences. Keep the served handbook aligned with the app version.
- Keep human-facing web content to simple connection/disconnection instructions. Dashboard editing, previews, and settings belong in the conversation with Codex, not a human web dashboard.
- Use app-owned SQLite storage for the device registry, dashboard instructions, sources, template revisions, preferences, and publication receipts. Keep rendered image files on disk and app-managed secrets in Keychain.
- Preserve saved display preferences across hourly updates. Persist user-requested changes through the app's tools instead of relying only on chat history or having Codex edit the database directly.
- Keep personal source data, household screens, credentials, and runtime profiles out of Git.
- Keep writes validated, atomic, revision-checked, and idempotent. A publication receipt is not proof of a successful physical screen refresh.
- Prefer the smallest implementation that demonstrates the next milestone. Update the README as the implementation and verified capabilities change.
