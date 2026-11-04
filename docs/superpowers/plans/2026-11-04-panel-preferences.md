# Clear quota values and persistent panels

- Preserve existing iPhone provisioning/signing changes and installed sessions.
- Show both used and remaining percentages explicitly; same rounding for each part and widgets. Regression fixture: 55% used must be 45% remaining (not same value); 57% used =>43% remaining.
- Persist hidden providers; stable order, all-hidden empty state with settings recovery. Hiding never disconnects or deletes snapshots/credentials.
- Show GitHub saved credential/account status; never refill password field with the actual token. Test config restoration across store creation and saving without re-entering token.
- Investigate device code: official user-billing endpoint requires GitHub App user token with Plan:read. Requires own registered Client ID and enabled device flow; no borrowed public client IDs, fake pairing or embedded client secret. Current update retains saved PAT unless registration is separately configured.
- Add Codex session account label for manual comparison, kept out of shared snapshots/widgets.
- Run unit/UI checks and independent review, then update installed app in place without uninstalling it.

## Verification
- 31 unit tests passed (Panel-Preferences.xcresult).
- Four existing UI flows passed; visibility/relaunch/all-hidden UI flow passed after targeting the switch thumb (Panel-Visibility-Verified.xcresult).
- Preferences screenshot inspected; Copilot raw overage display retained after independent review.
- Signed device build passed; installed in place and launched on the paired iPhone 18 Pro Max. No app uninstall or credential deletion.
- Real GitHub credential persistence and ChatGPT account attribution were not exercised with user credentials. Device-code registration remains a documented prerequisite, not a shipped pairing button.
