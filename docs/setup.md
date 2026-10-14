# First-run playbook for Codex

A person can start with this short prompt:

> Use https://github.com/NerdOutInc/little-screens to help me set up my own TRMNL device. Read the repository's AGENTS.md and docs/setup.md.

That prompt starts the complete onboarding workflow below; the user does not need to copy additional instructions. For a new installation:

1. Create the user's own ChatGPT Site using the Sites plugin, generate their own access token, and seed a weather-only starter screen. Never reuse another owner's Site or credentials.
2. Make your best guess at their city from available context and label it as a suggestion. Do not stop to ask for a location. Fetch real weather for that city and publish the starter image.
3. Give the user their private management link with its token, then walk them through connecting their TRMNL using the screen's setup URL.
4. After the user confirms the physical screen works, help them customize it and set up hourly updates on their always-on computer running Codex desktop.

Carry the process through to a visible first screen. Ask only for information that is truly necessary. Use the Sites plugin and its current skill instructions for creation, secrets, packaging, publication and tool schemas. Follow the ownership, access, verification, and scheduling steps below throughout setup.

## 1. Establish ownership and runtime

Clone this repository into the user's chosen workspace, or use their existing checkout. Read AGENTS.md. Confirm from context whether this is a new installation or an existing household update. Discover an existing local connection and its Site before creating anything; reuse it only when it belongs to this user and they intend to continue that installation.

For a new owner, create a new Site. Do not infer ownership from a repository URL. The reusable template deliberately has no real project ID or credentials. Create `.runtime/` for private state and keep it out of Git. Prepare Python 3.10+ and install `updater/requirements.txt` in a local virtual environment; prepare the Site's Node dependencies using the Sites helper or `npm install` in `site/`.

The updater runs on the user's always-on computer with Codex desktop, not a Site cloud scheduler. Use the computer and timezone already established by the user; ask about a different updater machine only when that choice is unresolved. Other desktop operating systems have not yet been runtime-tested even though the renderer is portable Python.

The hardware requirement is a TRMNL-compatible device with custom-server support, not necessarily an OG. Our local prototype was tested on TRMNL OG firmware 1.8.17. Establish the user's model from context or ask when needed for pairing. Verify its firmware routes and image requirements; the current renderer and server require 800×480 grayscale PNGs. Other models may need code changes. The button timings in this guide apply to the tested OG.

## 2. Guess a starter location; do not block on a question

Use city-level information already available in the conversation, user profile, saved context, or an authorized weather page. Prefer an explicit city over an operating-system timezone. A timezone alone does not determine a city: if necessary choose a representative major city in that timezone as a suggestion. If no usable context exists, choose an explicit sample city and label it as a suggestion, never as a detected location.

Save the chosen city, IANA timezone, weather source URL, and `location_inferred: true` in the starter's profile. Put “Suggested location” on the starter screen. Tell the owner the guess and invite a correction after first display. Do not ask for precise location permission, inspect private location history, or pretend to know an address.

Fetch real current weather for the chosen city using the browser. Keep observation time, forecast date, precipitation period, and source URL. Missing values are null. If a particular site is inaccessible, try another public weather source for a new starter unless the owner specified an exclusive source. Never fabricate a populated weather screen: if no source can be reached, publish an honest “Weather unavailable” starter with the suggested city and a timestamp.

No calendar connection or ImageGen call is required for this milestone.

## 3. Create and privately publish their Site

Use Sites `create_site` once. Save the exact returned project ID locally, then reuse it on every call. Generate at least 32 random bytes with a cryptographic random generator; encode as URL-safe text. Set `SITE_TOKEN` as a secret environment variable and `SITE_ORIGIN` to the exact returned Site origin. Do not print credentials in logs or commit them.

Prepare an isolated publishing checkout from the reusable source:

```sh
node scripts/prepare-site.mjs --project-id ACTUAL_RETURNED_ID --destination .runtime/site-publish
```

This creates the deployment's `.openai/hosting.json` in the private checkout. It does not alter the reusable template. Use the Sites plugin's required credential-on-hidden-stdin Git/build/package workflow from that checkout, then publish privately. Preserve its Git history for future updates. Do not put the source repository credential into a shell command or a file.

Store the application connection in `.runtime/site-connection.json`:

```json
{"origin":"https://YOUR-SITE.chatgpt.site","token":"YOUR_GENERATED_TOKEN"}
```

On Unix, set mode 600; on Windows use the current user's private profile/workspace and restrictive file permissions. The HTTP client refuses redirects so it won't forward the application token to a sign-in destination. During private QA, the Sites owner's short-lived service-access token may be needed for the dispatch layer; use the official Sites instructions, keep it local, and remove it from the connection before relying on the public device endpoint. It is not the application's SITE_TOKEN.

## 4. Seed one weather-only screen

Read `/api/guide` and `/api/screens` through the client. If a matching starter already exists, continue it instead of adding a duplicate. Create one logical screen named “Weather” with polling 300 seconds and starter instructions tailored to the guessed city. Set `profile.template` to `weather-starter-v1`, `location`, `timezone`, `weather_url`, and `location_inferred: true`. Do not include personal event data.

Use a request JSON file with a durable new UUID. Every later retry uses the same UUID and identical payload. Record the returned logical screen ID locally.

```sh
python updater/site_client.py write save_screen .runtime/create-weather.json
python updater/render.py .runtime/weather-input.json .runtime/weather.png
python updater/site_client.py write publish_screen .runtime/publish-weather.json --png .runtime/weather.png
python updater/site_client.py get SCREEN_ID
```

The render input contains `profile` and `snapshot.weather`; see `updater/examples/weather.json`. Populate current values and times from the live source. Use `snapshot.weather.note` to explain a source failure. View the PNG before uploading, then verify the persisted publication hash against the local image.

The weather starter is deterministic and requires no generated art. Users customize later; setup should not get stuck auditioning clouds.

## 5. Give the owner the links and pair one device

Give the owner their full private management URL, including `?token=...`, in the conversation, as requested by this onboarding flow. Explain that it is a password-bearing bookmark. Never put it in Git, public documentation, or unrelated messages.

Open the Site for the owner. Its screen card provides **Copy setup URL** after an image has been published. The owner must make the Site public through Sites sharing so a TRMNL can reach it; keep application token protection enabled. Do not silently change the audience.

After the owner makes it public, verify anonymous requests without the token receive 404, and the exact setup URL's `/api/setup` and `/api/display` return direct HTTP 200 JSON with an absolute image URL. Verify the image is a direct 200 PNG with Content-Length. Do not rely on an owner bypass token or browser sign-in for this test.

Then guide the physical steps:

1. Hold the OG's rear button for about 6–8 seconds to enter Wi-Fi setup.
2. From a phone, join the TRMNL Wi-Fi. Choose the household Wi-Fi, then Custom Server.
3. Paste the entire screen setup URL, without a trailing slash. This is not the management URL and not a direct image URL.
4. Briefly press the rear button or wait for its next check. Ask what appears on the physical display.

If the firmware shows READY TO PAIR, the logical screen is already provisioned; check the firmware request status and refresh again. Do not send the owner to the TRMNL company's hosted registration flow for this custom server. Never claim success based only on an image download.

## 6. Customize and schedule locally

Now ask what the user wants to see. They can rename the screen, change location, add calendars, request scenes, or create additional independent screens. Save revised instructions and structured profile through the API. Keep exact IDs; a new name is not a new device.

Follow docs/updater.md to test one complete local update and create the requested hourly desktop automation. Verify supported tools, permissions, connection path, repository path and model/image-generation availability on the actual updater computer. No cloud scheduler.

Review the first actual scheduled run. Preserve the last successful image if data gathering or image generation fails, and report actionable failures. Maintain per-screen independence.
