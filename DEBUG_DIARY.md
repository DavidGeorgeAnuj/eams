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

## 2026-08-07 — Missing "Create" button in Fiori Elements (separate from routing/auth)

While doing manual lifecycle testing, user reported no "Create" button on the
`/requests` app's AssetRequests list (and later, same on `/assets`/Assets).
This took several wrong turns before landing on the real cause — worth
recording precisely so the mistakes aren't repeated.

### Wrong turn #1: misread grep output as "Insertable: false" on AssetRequests
Ran `cf run-task eams-srv` to compile the live model to EDMX in-process
(no HTTP, no auth needed — same trick as reading `xs-app.json` earlier) and
grepped for `InsertRestrictions`. Found `Insertable Bool="false"` and
wrongly attributed it to `AssetRequests`. On closer line-by-line tracing,
that block actually belonged to `InventoryReport` (a `@readonly` reporting
view — correctly not insertable). **AssetRequests had no capability
restriction in the metadata at all.** Told the user the wrong thing here;
corrected once traced properly. Lesson: when grepping structured XML for a
property value, always trace back to its enclosing `<Annotations Target=...>`
block by line number — don't assume proximity in a `-A N` grep window means
the same target.

### Wrong turn #2: assumed it was CAP's `@restrict` auto-hiding the button
Confirmed via WebSearch that CAP's `@restrict` is backend-enforcement only
and does NOT auto-generate `Capabilities.InsertRestrictions` metadata (that
was speculation, not fact). So absence of any restriction should mean
"insertable" by spec default — yet the button still didn't show even for
`Manager`, who has explicit `CREATE` grant. Added an explicit
`@Capabilities.InsertRestrictions.Insertable: true` annotation on both
`Assets` and `AssetRequests` anyway (a legitimate, known fix pattern per
SAP Community threads for exactly this symptom) — rebuilt, redeployed,
verified byte-for-byte live via `cf run-task` compiling `srv/csn.json`
in-process. **Confirmed `Insertable="true"` genuinely on the wire** (verified
independently by the user pasting the real Network-tab response body with
browser cache disabled — a real `200`, not a stale `304`). Still no Create
button. So this wasn't the cause either — just a legitimate improvement
that was already latent best-practice.

Side lesson mid-investigation: a `304 Not Modified` response with a matching
`ETag`/`If-None-Match` means the browser reused a cached body — the actual
content served was NOT re-inspected. Always check DevTools Network tab with
"Disable cache" ticked before trusting what a `304` response "shows."

### Wrong turn #3 (partial): assumed missing `tableSettings.creationMode`
Found via WebSearch that Fiori Elements' `sap.fe.templates.ListReport` for
non-draft OData V4 services often needs an explicit `creationMode` (e.g.
`{"name": "NewPage"}`) under `tableSettings` in the manifest — ours only had
`{"type": "ResponsiveTable"}`. Added it to both `app/assets/webapp/manifest.json`
and `app/requests/webapp/manifest.json`. This is a real, correct config
addition (needed regardless), but alone still did not make the Create
button appear.

### Actual root cause: non-draft OData V4 entities don't get a List Report
Create button in `sap.fe.templates.ListReport`, period
Multiple independent SAP Community threads (including one on this EXACT
stack — CAP Node.js, `Capabilities.InsertRestrictions.Insertable: true`
explicitly set) converge on the same unresolved community answer: **"With
OData V4, create button becomes visible only if you enable draft."** No
combination of capability annotations or `creationMode` config overrides
this for a non-draft entity in `sap.fe.templates.ListReport`. This is a
known, accepted framework limitation, not a bug in our config.

### Fix: enable `@odata.draft.enabled`
Added `@odata.draft.enabled` to both `Assets` and `AssetRequests` in
`srv/service.cds`. This is a real architectural decision (not a one-line
tweak to shrug off): it introduces the standard Fiori Elements draft
workflow (New → fill in fields → Save/Discard, with `IsActiveEntity`/
`HasDraftEntity`/`HasActiveEntity` fields and a `DraftAdministrativeData`
entity added to the OData model), backed by real HANA shadow tables
(`AssetRequests_drafts`, `Assets_drafts`, `DRAFT.DraftAdministrativeData`)
that CAP auto-generates — confirmed present in `gen/db/src/gen/` after
`mbt build`.

Checked one important interaction before committing to this: CAP defers
custom `.before('CREATE', ...)` / `.on('CREATE', ...)` handlers to draft
**activation** (Save), not to the initial "New" click — so the existing
validation logic in `srv/service.js` (asset-availability check, setting
`employee_ID`/`requestDate` from the current user) will still fire at the
right moment, with the form fully filled in, not prematurely on an empty
draft. This is standard, intentional CAP draft semantics, so the existing
business logic should compose cleanly without modification.

Rebuilt, redeployed. Verified live via `cf run-task` compiling the deployed
`srv/csn.json`: `IsActiveEntity: true`, `DraftRoot: true` both confirmed
present in the real served metadata. No startup or DB errors in
`eams-srv` logs after the `eams-db-deployer` task ran to create the new
draft tables.

**Lesson for next time**: for CAP + Fiori Elements `sap.fe.templates.ListReport`
apps, decide on draft vs. non-draft UP FRONT for any entity that needs a UI
Create button — don't discover this requirement after the fact through
capability-annotation archaeology. If an entity genuinely shouldn't have
draft semantics (e.g., pure workflow-status entities), the practical
alternative is to not rely on the List Report's generic Create button at
all — either a custom action/dialog, or programmatic creation (e.g. the
browser-console `fetch` POST approach used earlier in this session).

## 2026-08-07 — "Provide the missing value" blocking Save on new AssetRequests

Draft mode worked — Create button appeared, user got into the New AssetRequest
draft object page. But saving was blocked with "Provide the missing value,"
with no obvious empty field on screen.

### Root cause
`asset_ID` on `AssetRequests` is `@mandatory` (`Common.FieldControl:
Mandatory` in `annotations.cds`) since an `AssetRequest` must reference an
`Asset`. But `app/requests/annotations.cds`'s `UI.FieldGroup` (the object
page form) only ever listed `requestType`, `status`, `justification`,
`decisionRemarks`, `requestDate`, `decisionDate` — **`asset` was never added
to the form fields**, almost certainly left out by whatever generated the
annotations before the `asset` association was fully wired in. So the
framework validates the full mandatory-field set from the model, finds
`asset` empty, and blocks save — but never gave the user anywhere to
actually fill it in.

### Fix
Added an `asset` `UI.DataField` (bound to `asset_ID`, which already has a
`Common.ValueList` annotation wiring up a value-help dialog against
`Assets` by `assetTag`/`category`/`model`/`serialNumber`) to both the
`UI.FieldGroup` (object page form) and `UI.LineItem` (list columns, so
requests are distinguishable by which asset they're about) in
`app/requests/annotations.cds`. Verified locally that `cds.load()` compiles
cleanly, and confirmed the `asset` `DataField` is present in the merged
`gen/srv/srv/csn.json` (the exact model that ships to `eams-srv`) before
deploying.

Known cosmetic follow-up (not blocking): the field will display the raw
`asset_ID` GUID rather than a human-readable asset tag in read-only/list
view, since there's no `Common.Text` annotation resolving it to
`asset.assetTag`. The value-help picker itself works fine (shows
assetTag/category/model/serialNumber to choose from); only the
after-selection display text is not yet friendly. Worth revisiting if it's
distracting during testing.

### Recurring local-dev gotcha noticed during this stretch
After every `mbt build`, the root `node_modules/@sap/cds` disappears —
this project uses npm workspaces (`"workspaces": ["app/*"]`), and `mbt
build` runs `npm ci` inside `app/requests`/`app/assets` as part of their own
build steps, which reshuffles the shared root `node_modules` and drops
packages not needed by those sub-packages. Not a bug, just something to
remember: **run `npm ci` at the repo root again after any `mbt build`**
before trying to compile/verify anything locally with `node -e "require('@sap/cds')..."`.

**Status**: fix deployed and verified present in the live merged metadata.
Awaiting user confirmation that the AssetRequest can now be saved
end-to-end.

## 2026-08-07 — Full lifecycle manually verified; UX polish pass

User completed the entire manual lifecycle test by hand: create → approve
(asset allocated, `currentHolder` correctly set) → return → approve
(asset back to `Available`) → reject → cancel. All state transitions and
guard rails confirmed working via the live UI. Also checked
`InventoryReport` directly (`/requests/eams/InventoryReport`) — correctly
reflected live aggregate counts by category/status.

### UX/integrity polish requested
1. `status` on `AssetRequests` should be read-only (was freely editable via
   the form, letting a user bypass the approve/reject/cancel workflow by
   just typing a new status directly — a real integrity gap, not cosmetic).
2. `asset` on `AssetRequests` should display by `assetTag`, not raw GUID.
3. `currentHolder` on `Assets` should display by `email`, not raw GUID.
4. `requestType` should be a dropdown — already is, via the CDS `enum`'s
   auto-generated `Validation.AllowedValues`; no change needed.

### Fix: `status @readonly`
Added `annotate EAMSService.AssetRequests with { status @readonly; };` in
`srv/service.cds`. Compiles to `Core.Computed: true` in the metadata, which
Fiori Elements uses to exclude the field from create/edit forms (display
only). Confirmed the approve/reject/cancel action handlers in
`srv/service.js` are unaffected — they write `status` via direct
`UPDATE()` CQL statements inside custom `.on(...)` handlers, which bypass
the OData-level read-only restriction (that restriction only blocks
*client* PATCH/POST attempts, not the server's own internal writes).

### Fix: `Common.Text` for `asset`/`currentHolder` — two wrong turns first
Attempted `annotate service.AssetRequests with { asset_ID @Common.Text: asset.assetTag @Common.TextArrangement: #TextOnly; };`
— compiled with "COMPILE OK" and no thrown error, but the annotation was
**silently absent** from the actual output. Two separate bugs stacked here:

1. **Bad chaining syntax**: `elementName @Anno1: val1 @Anno2: val2;` was
   silently dropped rather than erroring. The correct CDS syntax for
   multiple annotations on one element is the grouped form:
   `elementName @( Anno1: val1, Anno2: val2 );`.
2. **Wrong annotation target**: `asset_ID` doesn't exist as an addressable
   element in the CSN at `annotate`-processing time — it's a foreign-key
   shadow property that CAP only materializes in the *final* OData/EDMX
   output, not in the intermediate compiled model. Confirmed directly:
   `csn.definitions['EAMSService.AssetRequests'].elements.asset_ID` is
   `undefined`. The existing (working) `Common.ValueList` annotations were
   already correctly targeting the **association** (`asset`, `currentHolder`),
   not the `_ID` shadow field — CAP propagates the annotation down to the
   generated FK property automatically in the EDMX. Followed the same
   pattern for `Common.Text`/`Common.TextArrangement` and it worked.

**Lesson for next time**: for CAP CDS annotations on a managed-association's
foreign key (value help, display text, anything OData-capability-related),
always annotate the **association name**, never the `<assoc>_ID` shadow
property — the latter doesn't exist as an annotate target until the final
OData compilation step. And don't trust "no compile error" as proof an
annotation took effect — CDS's `annotate` silently no-ops on an
unresolvable target instead of failing loudly; always verify by grepping
the actual compiled EDMX output for the expected annotation term.

Also re-confirmed the recurring npm-workspaces `node_modules` reshuffling
gotcha from earlier — ran into it again needing `npm ci` after `mbt build`.

Rebuilt, verified all three fixes (`Core.Computed` on `status`,
`Common.Text` on `asset_ID` and `currentHolder_ID`) present in
`gen/srv/srv/csn.json` — the exact deployment-ready model — before
deploying. Deployed successfully.

**Status**: awaiting user confirmation that status is now read-only in the
UI and asset/currentHolder display human-readable text instead of GUIDs.

## 2026-08-08 — "Approve" resulted in status "Returned" — real logic bug

User reported: creating an Allocation request, clicking Approve, and the
request coming back as `Returned` instead of `Approved`. Also reported
`requestType` isn't rendering as an enforced dropdown.

### Root cause, confirmed via direct DB query (not guessed)
Used `cf run-task eams-srv` to run a raw CQL query against `eams.AssetRequest`
directly (bypassing the OData layer/UI entirely) to inspect actual stored
values. Found the problem record had **`REQUESTTYPE: null`**.

`approve()` in `srv/service.js` was written as:
```js
if (request.requestType === 'Allocation') { ...allocate... }
else { ...treat as Return... }
```
This silently treats **anything that isn't exactly `'Allocation'`** —
including `null`, a typo, or any future new request type — as a Return.
That's the actual bug: not "it guessed wrong," but that there was no
defense against invalid/missing data at all.

Separately, `requestType` had no `@mandatory` in `db/schema.cds` (unlike
`asset`, which we already fixed earlier), so the form let a request be
saved without ever setting it — consistent with the user's report that it
wasn't behaving like an enforced dropdown.

### Fix (two parts, both needed)
1. `db/schema.cds`: added `@mandatory` to `requestType`. CDS requires
   annotations on an enum-typed field to be prefixed BEFORE the field
   (`@mandatory\n  requestType: String(20) enum {...};`), not appended
   after the closing `enum { }` brace — appending after causes a real
   syntax error (confirmed via the compiler, not just the editor's
   linter this time: `cds.load()` threw). Verified `@mandatory` correctly
   compiles to `Common.FieldControl: Mandatory` in the metadata, and CAP's
   own generic validation will now reject `CREATE`/draft-activate server-side
   if it's missing, independent of our custom logic.
2. `srv/service.js`: changed `approve()`'s `if/else` to
   `if (Allocation) {...} else if (Return) {...} else reject(400, ...)`.
   Now an invalid/missing `requestType` fails loudly instead of silently
   doing the wrong thing — defense in depth even if bad data gets in some
   other way in the future.

Verified both fixes present in `gen/srv/srv/csn.json` /
`gen/srv/srv/service.js` (the exact deployment-ready build) before
deploying, per the discipline established earlier this session.

**Note**: this doesn't retroactively fix the already-corrupted test record
(`requestType: null`, now stuck showing `Returned`) — that's just leftover
test data, not something that needs manual cleanup unless it's confusing
during further testing.

**Lesson for next time**: an `if/else` branching on a business-meaningful
enum-like field should (almost) never have a bare `else` as the final
branch unless there are truly only two possible states *and* the field is
provably non-nullable end-to-end (schema mandatory + generic validation +
UI enforcement all in place). Otherwise `else` becomes a silent catch-all
for "anything unexpected," which turns a data problem into a wrong-behavior
problem instead of a loud error.

## 2026-08-08 — Making `requestType` an actual dropdown

User: mandatory + server-validated wasn't enough, wanted a real functional
dropdown, "don't care how, just don't break the code."

### Why the earlier fix didn't (and couldn't) work
Confirmed via WebSearch (not assumption this time): a plain CDS `enum`
compiles to `Validation.AllowedValues`, which is a **validation-only**
annotation — it makes the backend reject invalid values, but it does
**not** make Fiori Elements render a dropdown/Select control. Rendering an
actual dropdown requires `Common.ValueListWithFixedValues: true` paired
with a `Common.ValueList` pointing to a real, queryable entity
(`CollectionPath`) — there is no annotation-only/entity-less shortcut in
the current Fiori Elements V4 + CAP tooling. Multiple independent SAP
Community threads confirm this is a known, unavoidable gap for plain
enums, not something we were missing a flag for.

### Fix: minimal CAP-native "codelist" entity
Rather than a full backing table with manually-maintained relationships,
added the lightest version of CAP's own recommended pattern:
- `db/schema.cds`: new `RequestTypeCode { key code : String(20) enum {
  Allocation; Return; }; name : String(50); }` — a tiny, standalone
  reference entity, not an association target for `AssetRequest.requestType`
  (which stays exactly as it was: a plain string enum column, so
  `srv/service.js`'s `request.requestType === 'Allocation'` checks are
  completely unaffected).
- `db/data/eams-RequestTypeCode.csv`: 2 seed rows (Allocation, Return).
- `srv/service.cds`: exposed read-only as `RequestTypeCodes`.
- `app/requests/annotations.cds`: annotated `requestType` with
  `Common.ValueListWithFixedValues: true` + `Common.ValueList` pointing
  `CollectionPath: 'RequestTypeCodes'`.

This deliberately keeps `requestType` itself untouched structurally — the
codelist entity exists purely to give the dropdown something to point at,
not to become the source of truth or change any existing logic.

Verified end-to-end before declaring done, same discipline as every other
fix this session:
1. Confirmed `RequestTypeCodes` EntitySet + `Common.ValueListWithFixedValues`
   present in a local compile.
2. After `mbt build`, confirmed the actual HANA deployment artifacts were
   generated: `eams.RequestTypeCode.hdbtable`,
   `eams-RequestTypeCode.hdbtabledata`, `EAMSService.RequestTypeCodes.hdbview`.
3. Re-verified against `gen/srv/srv/csn.json` (the exact deployment-ready
   model) before deploying.
4. After deploying, used `cf run-task eams-srv` to query
   `eams.RequestTypeCode` directly in HANA — confirmed both seed rows
   (`Allocation`, `Return`) actually landed, not just that the deploy
   command exited 0.

Hit one unrelated speed bump mid-deploy: `cf deploy` failed with
"Authentication has expired" (CF CLI session timeout, unrelated to any
app change — a day had passed since the session started). Had the user
re-run `cf login` interactively (via the `!` prefix), then redeployed
successfully.

**Status**: fix deployed, seed data confirmed live in HANA, live traffic
in `cf logs` shows the user already back in the app with a fresh
`$metadata` fetch and a new draft request in progress. Awaiting
confirmation the dropdown actually renders and is selectable.

## 2026-08-08 — Locking down `decisionRemarks`, `approver`, `decisionDate`

User correctly reasoned that `decisionRemarks` has the same integrity gap
as `status` did: it's only meant to be set as a byproduct of calling
`approve`/`rejectRequest` (via their `remarks` action parameter), not
hand-typed on the form. Extended the same fix to `approver` and
`decisionDate` too — same category of backend-only field, all three set
exclusively via direct `UPDATE()` inside the custom action handlers in
`srv/service.js`.

### Another association-vs-FK propagation gap
`status @readonly;` and `decisionRemarks @readonly;` (plain scalar fields)
compiled fine — `Core.Computed: true` correctly appeared on them. But
`approver @readonly;` (an **association**) did NOT propagate to the
generated `approver_ID` foreign key property at all — confirmed by
grepping the actual compiled EDMX, not assumed. This is a different flavor
of the exact same class of bug hit earlier with `Common.Text` (CDS's
convenience shorthand doesn't always propagate through associations the
same way explicit vocabulary terms do). Fix: use the raw `@Core.Computed`
term directly instead of CDS's `@readonly` sugar —
`approver @Core.Computed;` — which propagated correctly. Verified via the
same compile-and-grep check for all four fields before rebuilding.

**Lesson for next time**: `@readonly` (and possibly other CDS convenience
annotations) can NOT be assumed to propagate through an association to its
generated foreign-key shadow property — always verify against the actual
compiled EDMX per-field, don't assume one working case (a plain scalar)
generalizes to another (an association). When it doesn't propagate, drop
to the explicit underlying OData vocabulary term (`@Core.Computed`,
`@Capabilities.*`, etc.) applied to the association directly.

Rebuilt, verified all four fields (`status`, `decisionRemarks`,
`approver_ID`, `decisionDate`) show `Core.Computed: true` in
`gen/srv/srv/csn.json` before deploying. Deployed successfully.
