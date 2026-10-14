# TRMNL Site source

Reusable React/Vinext Site with a D1 registry and R2 image storage. Read the repository's [setup guide](../docs/setup.md), [development guide](../docs/development.md), and [API contract](../docs/api.md).

Copy `.openai/hosting.example.json` to the ignored `.openai/hosting.json` for local development. Actual Site IDs and application secrets are per-owner local configuration. Publish through an isolated instance checkout using `../scripts/prepare-site.mjs` and the official Sites workflow.

The Site does not gather source data or generate images. Codex desktop on the owner's always-on computer does that through the portable updater. The firmware route selects a logical screen by URL, independent of hardware MAC addresses.
