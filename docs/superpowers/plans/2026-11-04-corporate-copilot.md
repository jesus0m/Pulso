# Corporate Copilot quota fix

Confirmed user has an organization-paid Copilot seat. Personal billing endpoints exclude it, so the existing empty-report-to-zero behavior is misleading.

- Add experimental per-user Copilot quota adapter using stored credential, no administrator billing APIs and no borrowed OAuth client.
- Validate known quota windows; reject placeholders, unsupported token-based/unlimited/missing data as unknown rather than zero/full remaining.
- Add organization vs personal account type; default organization for this user's app, preserve explicit selection. Corporate path ignores manual personal billing allowance.
- Migrate old personal-billing cache out of corporate panel/widgets and preserve all other sessions/preferences.
- Empty personal billing report is absence of usage data, not a verified zero.
- Explain Copilot Requests read permission and organization policy rejection, with a direct link to the official user's usage page.
- Unit+UI verification and independent review, signed build and in-place install; actual company quota access remains subject to user's token/org.

## Verification
- Corporate-Copilot.xcresult: 45 unit tests +6 UI tests passed.
- Signed device build passed.
- Independent review: no Important/Critical findings.
- Real enterprise quota remains conditional on PAT permissions, org policy and private endpoint support.
