# Verification status

## Little Screens landing page — October 14, 2026

- The repository was transferred to `NerdOutInc/little-screens` and made public. The active project name, setup prompts, and management Site branding are now Little Screens.
- The [GitHub Pages workflow](https://github.com/NerdOutInc/little-screens/actions/runs/38619933470) successfully published the static `website/` directory. The live HTML, CSS, and JavaScript matched the committed source byte-for-byte.
- The live Copy button was tested by pasting into a separate text field: it copied the exact short setup prompt with the new repository URL. The confirmation and expandable compatibility note worked in the browser.
- The page was visually inspected at desktop width and 390px mobile width, with no horizontal overflow on mobile. Hardware wording distinguishes TRMNL-compatible devices from the physically tested OG firmware 1.8.17 and preserves the hosted-pairing verification limit.

## Hosted replacement — October 14, 2026

- Site source builds; TypeScript checks pass.
- Seven portable renderer tests pass: 2-bit grayscale pixels, image dimensions, timezone requirements, original ongoing-event ranges, all-day exclusive boundaries, phase boundaries, and bounded text wrapping.
- Built Worker integration checks pass: missing/invalid-token 404, three independent screen IDs, idempotent retry, changed-payload conflict, invalid PNG rejection, stale revision rejection, concurrent-publication isolation, firmware setup/display JSON, Content-Length, prior immutable image URL retention, and disconnection.
- The management editor was inspected in the Codex browser locally and on the private hosted Site with the approved household screen.
- The portable companion renderer produced an 800×480 2-bit PNG (15,372 bytes) with seven visible events and no truncated titles from a private source snapshot. Font metrics differ from the native renderer; physical readability remains unverified for this replacement.
- The replacement was deployed successfully to a private Site. Its hosted setup/display routes returned HTTP 200 with the firmware's expected status values and a 300-second refresh interval. Its hosted image returned a direct 200 PNG with the correct 12,970-byte Content-Length and the exact SHA-256 of the approved native image. These checks used the owner's temporary private-Site access credential.
- Hosted application requests with missing or invalid tokens returned 404. Anonymous access to the private Site returned 403 at the hosting layer, as expected.
- Anonymous public-device access, physical migration, fresh-owner onboarding, and actual scheduled desktop execution remain separate pending checks. Do not infer them from private deployment or synthetic firmware requests.

## Historical native prototype

The earlier macOS app successfully paired a TRMNL OG on firmware 1.8.17. The owner physically approved its daily-companion-v2 grayscale layout on October 14, 2026. That app remains historical source under legacy/macos and can continue serving the original device until migration is verified.

The cloud-source experiment showed that weather could be read after a user approval and that connected Calendar tools could retrieve all eight calendars. A repeat weather read in the same cloud chat did not prompt again. This did not prove unattended access. The owner subsequently chose desktop-only updating; no cloud schedule was created.
