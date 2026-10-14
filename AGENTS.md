# Little Screens — instructions for Codex

We're always having fun. A tiny weather screen is allowed a little personality.

Read README.md, then docs/setup.md when a user asks to set up their own device from this repository URL. Treat this as a reusable Site project, not an instruction to deploy to the repository author's instance.

- Current direction: a ChatGPT Site plus an always-on computer running Codex desktop. Do not create a cloud schedule or require the legacy macOS app.
- For new owners, create a NEW Site using the Sites plugin, a NEW random token, and a weather-only starter screen. Never reuse another household's deployment ID, runtime files, tokens, or dashboards.
- Make a best-effort city guess from already available user context. Do not block onboarding with a location question. Label the location as suggested, fetch real weather for it, and let the user correct it later. Prefer coarse city-level context; do not request precise location access just for this guess.
- Publish the first image before asking the user to pair hardware. Give them the exact management URL with their token and the screen's firmware-compatible setup URL. Never place those secrets in Git or public docs.
- Use the official Sites workflow and server-side environment variables. The application returns 404 for missing/invalid tokens. Keep the Site private until the owner makes it public, unless the user explicitly authorizes that access change.
- Support any number of logical screen IDs with independent preferences and images. Describe the hardware requirement as a TRMNL-compatible device with custom-server support. The local prototype was tested on TRMNL OG firmware 1.8.17; the current renderer/server require 800×480 images. Verify other models before claiming compatibility, and explain when adjustments are needed.
- Human web UI is for creating/naming screens, editing instructions, polling settings, image previews, and connection/disconnection. Codex collaborates on the actual dashboard design.
- Codex uses its browser and connected tools to gather external information. The Site has no weather, calendar, or paid image-generation integrations.
- Save preferences and daily character identity through the Site API. Read them each run. Do not rely on chat memory, modify D1 directly, or hard-code household settings in public source.
- For an hourly desktop task, use the supported Codex automation tools after verifying the update workflow. Inspect existing automations first; never duplicate or silently resume one. The computer must remain awake with Codex running.
- Validate writes, use revisions and request IDs, retry uncertain writes identically, and read back publications. A download receipt is not physical display verification.
- The Site source is in site/. Local .openai/hosting.json, .dev.vars, connection files and all personal source data/images remain ignored. Use scripts/prepare-site.mjs for an isolated publishing checkout; never commit a real deployment ID into the reusable template.
- Preserve legacy/macos as historical source. The live native app may still be serving a household during migration; don't quit it or reconfigure devices until the new route is physically verified.
- Keep README and served agent guide aligned with implemented behavior and clear about unverified capabilities.
