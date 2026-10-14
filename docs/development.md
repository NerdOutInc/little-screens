# Development and publication

The reusable source lives in `site/`; deployment-specific files stay local. Install the current Sites plugin and follow its skill instructions for publishing. This repository doesn't embed a personal Site ID.

## Public getting-started page

The small static page in `website/` is published to GitHub Pages by `.github/workflows/pages.yml` when that directory or the workflow changes on `main`. The workflow uploads only `website/`. It does not publish the ChatGPT Site, runtime data, or household screens.

Preview it with `python3 -m http.server 8790 --bind 127.0.0.1 --directory website`, then open `http://localhost:8790/`. Keep the prompt identical to README.md and docs/setup.md. Verify the Copy button writes that exact text and that the page fits narrow screens. Browser clipboard failures should select the prompt and show manual-copy instructions.

## Local preview

```sh
cp site/.openai/hosting.example.json site/.openai/hosting.json
cd site
npm install
```

Create ignored `site/.dev.vars` with a cryptographically random `SITE_TOKEN` of at least 32 characters and `SITE_ORIGIN=http://127.0.0.1:5173`. The token belongs only in this file and the ignored local client connection. Don't use a committed example value in a hosted deployment.

```sh
npm run build
node --import ./scripts/sites-env.mjs ./node_modules/wrangler/bin/wrangler.js d1 execute DB --local --config dist/server/wrangler.json --persist-to .wrangler/state --file drizzle/0000_nice_peter_parker.sql
npm run dev
```

Open `http://127.0.0.1:5173/?token=YOUR_LOCAL_TOKEN`. Without it, 404 is the intended result. D1/R2 local state is isolated under `.wrangler/`; hosted state is separate. Later schema changes need a new Drizzle migration, not edited applied migrations.

The custom `worker.ts` routes firmware and API requests directly, preserving the fixed image length required by OG setup. The HTML framework handles the management page. Keep the maintained Sites build integration intact.

For the built Worker preview, copy the ignored environment file into the ignored build directory first, then run Wrangler. Development HTML middleware can alter wire headers, so firmware contract tests must use the built Worker or hosted endpoint:

```sh
npm run build
cp .dev.vars dist/server/.dev.vars
npm start -- --port 5174
```

From the repo root:

```sh
python -m unittest discover -s updater/tests -v
npm exec --prefix site -- tsc --noEmit -p site/tsconfig.json
python scripts/test-site.py .runtime/local-test-connection.json .runtime/test-screen.png
```

The integration script refuses non-local origins. It exercises authentication, multiple IDs, idempotence, stale/concurrent writes, malformed PNG rejection, firmware metadata/image responses, fixed Content-Length, retention of a prior image URL, and disconnection. Use a disposable local database; the test adds synthetic screen records.

## Publish your own instance

1. Create a new Site using the official Sites tool; persist the exact returned ID locally.
2. Set secret SITE_TOKEN and SITE_ORIGIN using the Sites environment-variable tool.
3. Prepare a separate ignored source checkout:

```sh
node scripts/prepare-site.mjs --project-id ACTUAL_RETURNED_ID --destination .runtime/site-publish
```

4. Install dependencies in that checkout, then use the Sites skill's source workflow helper with its short-lived credential through hidden stdin. Build and package there; push its exact source commit to the Site's managed source repository and privately deploy that same commit/archive.
5. Check deployment status, live API authentication, seeded image hash and response headers. Import personal content through the API, never through a committed migration or source file.
6. The owner makes the Site public before a real device can connect. Test device endpoints without owner preview access, then physically verify the display.

The public GitHub repository and each instance's managed Site source repository are separate. The publishing helper copies reusable source into the instance checkout and creates its deployment manifest there. Preserve that checkout's Git history. For removed source files, explicitly remove their counterparts in the publishing checkout before republishing; the helper does not delete files or reset history automatically.

## Fonts

The portable renderer bundles Atkinson Hyperlegible Regular and Bold from [googlefonts/atkinson-hyperlegible](https://github.com/googlefonts/atkinson-hyperlegible), under the SIL Open Font License in `updater/fonts/OFL.txt`. No operating-system font installation is required.
