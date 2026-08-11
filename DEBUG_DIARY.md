# EAMS Debug Diary

Running log of errors, root causes, fixes, and the reasoning behind each change.
Newest entries at the bottom.

---

## 2026-08-07 — Session start / recap

### Context
EAMS (Employee Asset Management System) — SAP CAP backend, two Fiori UI apps,
deployed to SAP BTP Cloud Foundry with:
- CAP backend (srv/) + DB (db/)
- Approuter (app/router) — single entry point
- XSUAA — authentication
- HTML5 repo — hosts built UI apps (app/requests, app/assets)

Backend, DB, and approuter are deployed and healthy.

### Problem
Loading `/requests/index.html` via the approuter, the UI's OData calls are
being requested as `.../requests/eams/metadata` instead of `.../eams/metadata`.
The API path is being nested *inside* the app's own route prefix
(`/requests/...`) instead of being routed to the backend at the root.

Fix attempted previously: added an explicit route in
`app/requests/xs-app.json` (or app/router/xs-app.json) matching
`/requests/eams/*` -> backend destination, then redeployed.

Result: same 404 — no change observed.

Two hypotheses going in:
1. **Staleness**: the redeploy didn't actually ship the new xs-app.json
   (stale build / wrong mtar / cached module).
2. **Route precedence**: approuter is matching a different, higher-priority
   route before ever reaching the new rule.

### Step: inspect the deployed .mtar
Goal: confirm with certainty whether the latest xs-app.json changes are
inside the artifact that was actually deployed, before debugging routing
logic further.

Finding: **No `.mtar` file exists locally**, and no `mta_archives/` directory
either. `.gitignore` explicitly excludes `mta_archives/`, `*_mta_build_tmp`,
and `*.mtar` (lines 10-13 of `.gitignore`), so even if one was built before,
it was never committed and appears to have been cleaned up / not present in
this working copy.

**Consequence**: can't inspect "the .mtar we uploaded" directly — it doesn't
exist on disk anymore. Need to either:
(a) rebuild fresh with `mbt build` and inspect the newly produced mtar's
    xs-app.json contents before redeploying (confirms what *would* ship), or
(b) inspect what's actually live in Cloud Foundry right now (`cf apps`,
    `cf app <approuter>`, download droplet, or hit the routes directly) to
    see what's currently running, independent of local build state.

Repo layout found:
- `app/assets/xs-app.json`
- `app/requests/xs-app.json`
- `app/router/xs-app.json`
- `mta.yaml` at repo root

Next: read all three xs-app.json files + mta.yaml to understand the intended
routing topology (there are 3 separate xs-app.json files, which is itself
suspicious — need to confirm which one actually governs runtime routing for
the approuter module vs. which are HTML5-repo-app-level descriptors that get
ignored at runtime).

### Finding: which xs-app.json actually matters
`mta.yaml` shows only `app/router` is deployed as `type: approuter.nodejs`
(module name `eams`) — the single entry point. `app/requests/xs-app.json` and
`app/assets/xs-app.json` are HTML5-repo-app-level descriptors bundled inside
the `eamsrequests`/`eamsassets` html5 modules; those are only consulted when
an app is served through a *managed* approuter (e.g. SAP Build Work Zone)
with no standalone approuter in the picture. Since this project has its own
standalone approuter module, those two files are dead weight — not the cause.

**`app/router/xs-app.json` already has the correct fix**, and route order is
right (specific rule before catch-all):
```
1. ^/requests/eams/(.*)$  -> /eams/$1  -> destination: srv-api   (fix)
2. ^/assets/eams/(.*)$    -> /eams/$1  -> destination: srv-api
3. ^/eams/(.*)$           -> /eams/$1  -> destination: srv-api
4. ^(.*)$                 -> html5-apps-repo-rt                  (catch-all)
```
So on disk, this should work. Confirmed via `git log` that this fix is fully
committed (commit `c9805b9`, 29 lines changed in `app/router/xs-app.json`,
working tree clean). So it's not "never committed."

### Root cause found: stale deployment (hypothesis 1 confirmed)
No local `.mtar`/`mta_archives/` exists — `.gitignore` excludes them, so
couldn't inspect the uploaded archive directly. Instead verified via the
live CF environment:

- `cf app eams` → **last uploaded: Fri 07 Aug 14:40:19 IST 2026**
  = 09:10:19 UTC (instance start 09:10:37 UTC).
- Fix commit `c9805b9` timestamp: **09:22:11 UTC** — **12 minutes AFTER**
  the currently-running approuter was last deployed.

So the currently running `eams` approuter container predates the fix commit
entirely — the routing fix was written and committed to git, but the actual
`cf deploy`/`cf push` that would ship it never happened (or happened before
the commit).

**Corroborated with live traffic**, not just timestamps:
- `cf logs eams --recent` shows the real failing browser request
  (`GET /requests/eams/$metadata?sap-language=EN`, `vcap_request_id:
  05b5de59-...`, 404) has a matching app-log line with the SAME request_id:
  `"Sending client credentials token for service html5-apps-repo-rt"`.
  That only happens when the approuter dispatches to the **catch-all**
  rule (`service: html5-apps-repo-rt`), never the backend (`destination:
  srv-api`) rule.
  → Direct proof the running instance is still on the OLD single-route
    xs-app.json (`^/(.*)$` -> destination srv-api, no html5-apps-repo-rt
    awareness at all) or an intermediate version — either way, NOT the
    fixed version. This matches the timestamp evidence exactly.
- (A follow-up unauthenticated `curl` to the same endpoint returned a
  login-redirect page, not a 404 — but that's a red herring: both the old
  catch-all rule and the new backend rule specify `authenticationType:
  xsuaa`, so an unauthenticated request gets redirected to login before
  routing is even decided. Not useful for distinguishing old vs new config;
  the authenticated real-user request + matching request_id in the app log
  is the reliable signal.)

### Fix
Rebuild the MTA archive (`mbt build`) and actually redeploy
(`cf deploy`/`cf push`) so the committed `app/router/xs-app.json` fix goes
live. The bug was never "wrong routing logic" — it was a deploy that silently
didn't ship.

**Lesson for next time**: after any `cf deploy`, check `cf app <name>` →
"last uploaded" timestamp against the git commit timestamp of the fix before
assuming a redeploy failed to fix a bug. Cheap, conclusive, no guessing.

### Rebuild + verify before redeploying
Ran `mbt build` fresh from the current (clean, committed) working tree.
Succeeded, produced `mta_archives/eams_1.0.0.mtar`.

Before trusting it, unzipped the mtar and drilled into the `eams` module's
`data.zip` (the approuter payload) to read the packaged `xs-app.json`
directly — confirmed byte-for-byte it contains the fixed 4-route config
(specific `/requests/eams/*` and `/assets/eams/*` rules + generic `/eams/*`
rule, all before the `html5-apps-repo-rt` catch-all). So this artifact, if
deployed, will ship the fix. Proceeding to `cf deploy`.

### Deployed
`cf deploy mta_archives/eams_1.0.0.mtar -f` — completed successfully.
`eams-srv` (backend) and `eams` (approuter) were both re-uploaded, staged,
and restarted; `eams-db-deployer` HDI deploy task also re-ran.

Verified: `cf app eams` now shows **last uploaded: Fri 07 Aug 15:08:56 IST
2026** — well after the fix commit (09:22 UTC / 14:52 IST). The stale-deploy
gap is closed.

### Status / next step
The fixed `xs-app.json` is now genuinely live. Next: reload
`/requests/index.html` in the browser (real authenticated session, not
curl) and confirm the OData calls hit `/eams/...` and return real data
instead of 404. If it still fails, check `cf logs eams --recent` again and
match the failing request's `vcap_request_id` to its app-log line the same
way as before — that technique (matching request_id across RTR and APP log
lines to see which route dispatched) is now a proven, reusable diagnostic
for this approuter.

## 2026-08-07 — Still blank after redeploy. New investigation.

User confirmed: reloaded `/requests/index.html` with a real authenticated
session, still blank. Streamed live `cf logs eams`/`cf logs eams-srv`
while user reloaded, to catch the real failing requests.

### Observed (post-redeploy, real authenticated browser session)
- `GET /requests/eams/$metadata?sap-language=EN` → **404**, 14-byte body
- `HEAD /requests/eams/` (UI5 ODataModel's CSRF-token preflight) → **404**
- Matched each failing request's own `vcap_request_id` to its app-log line:
  both show `"Sending client credentials token for service
  html5-apps-repo-rt"` — i.e., dispatched to the catch-all rule (rule 4),
  not the backend (`destination: srv-api`, rules 1-3).
- Checked whether this log line is even diagnostic: compared against a
  **known-good** static file request (`GET /requests/Component-preload.js`,
  which correctly SHOULD go through rule 4) — it gets the exact same log
  line. So every single request, matching or not, is landing on rule 4.

### Ruled out (each independently verified, not assumed)
1. **Stale deploy** — ruled out. `cf app eams` shows fresh upload
   (15:08:56 IST, after the fix commit).
2. **Backend doesn't have the route** — ruled out. Direct curl to
   `https://...eams-srv.../eams/$metadata` (bypassing approuter entirely)
   returns **401 Unauthorized** (CAP + xsuaa middleware recognizing the
   route, just rejecting the missing token) — NOT 404. So `/eams/$metadata`
   is a real, valid backend endpoint.
3. **Duplicate/stray route mapping stealing traffic** — ruled out via
   `cf routes`: hostname `52eb1744trial-dev-eams` maps only to the `eams`
   app, nothing else.
4. **`cds build --production` silently regenerating/overwriting
   `app/router/xs-app.json`** during the `mbt build` `before-all` step —
   ruled out. Checked the file on disk immediately after running
   `mbt build`: unchanged, matches git, no `gen/router` folder exists.
5. **Homoglyph/non-ASCII corruption in the `"srv-api"` destination name**
   (worth checking given garbled unicode had shown up in copy-pasted text
   earlier in this session) — ruled out via `grep -P "[^\x00-\x7F]"` and a
   hexdump of the destination name in both `xs-app.json` and `mta.yaml`:
   clean ASCII, byte-for-byte identical everywhere.
6. **Destination `srv-api` misconfigured/missing at runtime** — ruled out.
   `cf env eams` shows the `destinations` env var correctly set:
   `{"name":"srv-api","url":"https://...eams-srv...","forwardAuthToken":true}`.
7. **The packaged/deployed xs-app.json isn't actually what we think** —
   ruled out with the strongest possible evidence: used `cf run-task eams
   --command "cat xs-app.json"` (runs a fresh container from the exact
   same live droplet — works even though `cf ssh` is disabled on this
   trial org) and read the file directly. **It is byte-for-byte the correct,
   fixed 4-route config.** This is as close to ground truth as it gets —
   not the git file, not the build artifact, but literally what's on disk
   inside the running droplet.

### Where this leaves us
Every layer we can independently verify (source, build artifact, live
droplet filesystem, destination config, backend route) is correct. Yet
`@sap/approuter` (Application router version 21.5.0, confirmed from its own
startup log) is not matching the specific rules 1-3 for requests that
clearly should match their regexes (`/requests/eams/$metadata`,
`/requests/eams/` both match `^/requests/eams/(.*)$`). This now looks like
either an approuter runtime/version quirk, or an interaction between
`csrfProtection: true` + `destination`-based routing that isn't behaving
as documented. Next step: check for known @sap/approuter issues with this
version/pattern, and/or empirically test with a simplified route (no
csrfProtection, no capture group) to isolate which property is responsible.

### Root cause #2 found: wrong xs-app.json layer entirely
WebSearch turned up the missing architectural fact: with `HTML5Runtime_enabled:
true` (set on `eams-html5-repo-host` in `mta.yaml`), once a request falls
under a deployed HTML5 app's own namespace (`/requests/*`, `/assets/*`),
routing inside that namespace is governed by **that app's own bundled
`xs-app.json`** (`app/requests/xs-app.json` / `app/assets/xs-app.json`) —
NOT the central approuter's `xs-app.json`. This directly explains everything
observed: the fix in `app/router/xs-app.json` (rules 1-3, `/requests/eams/*`
etc.) is real, deployed, byte-for-byte confirmed live — and STILL never
gets consulted, because by the time a request path starts with `/requests/`,
dispatch has already been handed off to the `requests` app's own routing
file, which only had a rule for `^/?odata/(.*)$` (a leftover template
default that doesn't match this project's actual CAP service path, `/eams`)
before falling to its own catch-all → 404 as a missing static file.

This also retroactively explains why EVERY request (including legitimate
static file requests) showed identical "Sending client credentials token
for service html5-apps-repo-rt" log lines: that log line reflects the
TOP-LEVEL approuter handing off to the html5-apps-repo-rt service for
*any* `/requests/*` path — which is correct for static files, but for
`/requests/eams/*` it should never have gotten there if the top-level rule
were actually authoritative for that prefix. It isn't; the app-level file
is.

**Fix**: added `^/?eams/(.*)$` → `/eams/$1` → `destination: srv-api` as the
first route in both `app/requests/xs-app.json` and `app/assets/xs-app.json`,
before their existing (harmless but irrelevant) `/odata/*` rule and before
their catch-all. Rebuilding and redeploying to test.

**Lesson for next time**: for CAP + standalone approuter + HTML5 App
Repository (`HTML5Runtime_enabled: true`) deployments, API routing rules
for calls made FROM a specific UI app must live in THAT APP'S OWN
`xs-app.json`, not (only) the central approuter's. The central approuter's
`xs-app.json` only governs top-level dispatch between "which HTML5 app" /
"which non-HTML5 destination" — it does not reach inside an already-matched
HTML5 app's own path space.

### Fix confirmed live
Rebuilt (`mbt build`), verified the fix byte-for-byte inside the freshly
built `requests.zip` (not just the source file), then `cf deploy`'d.
Deploy log confirmed the mechanism: `Content of application "eams" is not
changed - upload will be skipped` (approuter itself untouched this time) —
instead the fix shipped via `Deploying content module "eams-app-deployer"
in target service "eams-html5-repo-host"`, i.e. through the HTML5 App
Repository content pipeline, exactly matching where the theory said the
file needed to live.

Streamed live logs again during a real reload:
- `GET /requests/eams/$metadata` → **200**, 2751 bytes (real CSDL metadata)
- `HEAD /requests/eams/` → **200**
- `POST /requests/eams/$batch` → **200**, and confirmed on the backend side
  (`eams-srv` own RTR log) as `POST /eams/$batch` → 200 — traffic is now
  genuinely reaching the CAP service through the correct path.

**The original routing bug (nested `/requests/eams/*` never reaching the
backend) is fully fixed and confirmed via live traffic, not just deploy
logs.**

## 2026-08-07 — New, separate issue: 403 Forbidden in the UI

User reported the UI now loads but shows "Error / Forbidden" instead of
data. This is a **completely different problem** from the routing bug —
and its appearance is actually confirmation the routing fix worked: the
request is now reaching the backend at all, which is why the backend gets
to reject it.

`cf logs eams-srv --recent` shows the real cause directly:
```
msg: "403 - Error
    at reject (.../auth/utils.js:20:14)
    at ApplicationService.enforce_auth (.../auth/restrict.js:229:5)
  message: 'Forbidden', code: '403'"
```
This is CAP's own `@restrict`/`@requires` authorization middleware
rejecting the request — not a routing or infrastructure problem.

`srv/service.cds` defines role-gated access on every entity, e.g.:
```
@restrict: [
  { grant: 'READ', to: ['Employee','Manager','AssetAdmin','SysAdmin','ITSupport'] },
  ...
]
@requires: 'SysAdmin'   // Employees entity
@requires: ['AssetAdmin','SysAdmin']  // InventoryReport
```
And `mta.yaml`'s `eams-auth` (xsuaa) resource defines matching role
collections: `Employee (eams ${org}-${space})`, `Manager (...)`,
`AssetAdmin (...)`, `SysAdmin (...)`, `ITSupport (...)`.

**Root cause**: the logged-in BTP user has none of these role collections
assigned in the subaccount yet, so every CDS entity read is rejected before
it even runs.

**Fix (manual, in BTP Cockpit — not something doable from this shell;
no `btp` CLI is installed here)**:
1. BTP Cockpit → Security → Users → select your user.
2. "Assign Role Collection" → pick one appropriate to what you want to
   test with (e.g. `Employee (eams 52eb1744trial-dev)` for basic read
   access, or `SysAdmin (eams 52eb1744trial-dev)` for full access including
   the Employees entity and InventoryReport).
3. Log out of the app and log back in (or hard-refresh) so the new JWT
   includes the updated role/scope claims — role collection changes don't
   apply to an already-issued token.
4. Reload `/requests/index.html` — the same `$batch` call that got 403
   should now return real data.

**Lesson for next time**: a 403 (not 404, not a routing/CORS error) from
the backend after `/eams/...` calls are confirmed reaching it is almost
always a missing role-collection assignment for the logged-in user, not
an app bug — check `@requires`/`@restrict` in the `.cds` service definition
and cross-reference against the user's assigned role collections in BTP
Cockpit before assuming the code is wrong.

### Correction: SysAdmin wasn't the right role for this app
User had already assigned `SysAdmin` before I gave the above instructions —
still got 403. Re-checked `srv/service.cds` and the `/requests` app's own
`manifest.json` (`dataSources` → `uri: "/eams/"`, routes/targets built
entirely around `AssetRequests`, e.g. `AssetRequestsList`,
`AssetRequestsObjectPage`) to identify EXACTLY which entity this UI queries:
**`AssetRequests`** (srv/service.cds:21), whose `@restrict` block only
grants:
```
{ grant: ['READ','CREATE'], to: ['Employee','Manager'] },
{ grant: '*', to: ['Manager'] },
{ grant: 'READ', to: ['ITSupport'] }
```
`SysAdmin` is not in this list at all — it only covers `Assets`,
`Employees`, and `InventoryReport`, not `AssetRequests`. So `SysAdmin`
was a perfectly valid role in general, just not the one this specific app
needs.

**Fix**: user assigned `Manager (eams 52eb1744trial-dev)` instead (grants
full `*` access to `AssetRequests`, including the `approve`/`rejectRequest`/
`cancel` actions).

### RESOLVED
UI now shows real `AssetRequests` data (status "Standard"/"Allocation",
"Approved", descriptions like "Need a monitor for home office setup").
End-to-end confirmed working: approuter → HTML5 app → backend → HANA data
→ rendered in the Fiori UI.

**Full chain of what it actually took**, for future reference:
1. Central approuter's `xs-app.json` fix (real, but insufficient alone —
   `HTML5Runtime_enabled: true` means it doesn't govern routing inside an
   already-matched HTML5 app's own path space).
2. The SAME destination rule also added to the HTML5 app's OWN
   `xs-app.json` (`app/requests/xs-app.json`, `app/assets/xs-app.json`) —
   this is the layer that actually mattered for `/requests/eams/*`.
3. A role collection matching the SPECIFIC entity's `@restrict`/`@requires`
   annotations assigned to the test user in BTP Cockpit — matched to the
   actual entity the UI queries (`AssetRequests` → needs `Employee`,
   `Manager`, or `ITSupport`; `SysAdmin` does not cover it, despite sounding
   like it should have the broadest access).
