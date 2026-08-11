# EAMS — Employee Asset Management System

A SAP Cloud Application Programming Model (CAP) application for tracking company
assets (laptops, monitors, mobile devices, etc.), allocating them to employees, and
routing allocation/return requests through an approval workflow.

## Architecture

| Layer | Tech | Location |
|---|---|---|
| Domain model | CDS (CAP) | `db/schema.cds` |
| Service layer | CDS + Node.js handlers | `srv/service.cds`, `srv/service.js` |
| Database | SQLite (dev), SAP HANA (production) | `db/data/*.csv` seed data |
| Assets UI | Fiori Elements (List Report / Object Page) | `app/assets` |
| Requests UI | Fiori Elements (List Report / Object Page) | `app/requests` |
| Auth | Mocked users (dev), XSUAA (production) | `xs-security.json` |
| Deployment | Multi-Target Application | `mta.yaml` |

### Domain model

- **Employee** — name, email, department, designation, reporting manager,
  and a `userID` linking the record to an XSUAA/mock user.
- **Asset** — asset tag, category (Laptop/Monitor/Mobile/Other), model, serial
  number, status (Available/Allocated/UnderMaintenance/Retired), current holder.
- **AssetRequest** — an Allocation or Return request against an asset, with
  status (Pending/Approved/Rejected/Returned/Cancelled), approver, and remarks.
- **RequestTypeCode** — value-help list for request types.

### Service (`EAMSService` at `/eams`)

| Entity/Action | Access |
|---|---|
| `Assets` | Read: Employee, Manager, AssetAdmin, SysAdmin, ITSupport · Create/Delete: AssetAdmin · Update: AssetAdmin, ITSupport |
| `Employees` | SysAdmin only |
| `AssetRequests` | Read/Create: Employee, Manager · full access: Manager · Read: ITSupport |
| `AssetRequests.approve(remarks)` | Approves a pending request; allocates or frees the asset accordingly |
| `AssetRequests.rejectRequest(remarks)` | Rejects a pending request (remarks required) |
| `AssetRequests.cancel()` | Withdraws a pending request |
| `InventoryReport` | Read-only asset counts by category/status — AssetAdmin, SysAdmin |
| `RequestTypeCodes` | Read-only, unrestricted |

Business rules enforced in `srv/service.js`:
- Every request is tied to the calling user's own `Employee` record (looked up
  by `userID`); a user with no linked Employee record is rejected with 403.
- An Allocation request requires the asset to be `Available`; a Return request
  requires the requester to be the asset's `currentHolder`.
- Approving a request flips the asset's status/holder and stamps the approver
  and decision date; rejecting/cancelling only changes the request status.

## Prerequisites

- Node.js 20+
- npm

## Getting started

```bash
npm install
npm start          # cds-serve — plain service, no UI proxy
# or, to develop against a specific Fiori app with live reload:
npm run watch-assets
npm run watch-requests
```

`npm start` / `cds watch` boots an in-memory SQLite database seeded from
`db/data/*.csv` and serves:

- Service metadata: `http://localhost:4004/eams/$metadata`
- Assets app: `http://localhost:4004/assets/webapp/index.html`
- Requests app: `http://localhost:4004/requests/webapp/index.html`

### Mock users (dev only, see `package.json` → `cds.requires.auth`)

| User | Password | Roles |
|---|---|---|
| alice | alice | Employee |
| bob | bob | Employee, Manager |
| carol | carol | AssetAdmin |

Note: mock users authenticate by username, but service logic resolves the
*employee* record via `Employee.userID` — a mock user only sees their own
requests/assets correctly if a matching row exists in `db/data/eams-Employee.csv`.

## Project layout

```
app/
  assets/       Fiori Elements app for managing the asset inventory
  requests/     Fiori Elements app for raising/approving asset requests
  router/       Approuter config for production deployment
db/
  schema.cds    Domain model
  data/         Seed CSV data
srv/
  service.cds   Service definition, authorization rules
  service.js    Custom handlers (validation, approve/reject/cancel actions)
xs-security.json   XSUAA scopes/role templates
mta.yaml            Multi-target application deployment descriptor
```

## Deployment

The app is packaged as an MTA (`mta.yaml`) targeting Cloud Foundry:
HANA HDI container for persistence, XSUAA for auth, HTML5 App Repository +
Approuter for serving the Fiori apps, and an `nodejs` module for the CAP
service. Build and deploy with the MultiApps Build Tool / Cloud MTA Build
Tool (`mbt build`) and `cf deploy`.

## Learn more

<https://cap.cloud.sap>
