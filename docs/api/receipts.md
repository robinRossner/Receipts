# Receipts API

Contract for the Mac, iOS and Android Receipts clients. Everything here is served by the Receipts
server (`backend/`) under `/api/v1/receipts/...`. The examples are real responses of the server, taken from a
test run with a stand-in for the language model (ids, hashes and timestamps differ in real use).

Contents: [Conventions](#conventions) · [Concepts](#concepts) · [Data model](#data-model) ·
[Photo upload](#photo-upload) · [Extraction queue](#extraction-queue) · [Sync](#sync) ·
[Photo archive (laptop)](#photo-archive-laptop) · [Status and reminders](#status-and-reminders) ·
[Taxonomy and dictionary](#taxonomy-and-dictionary) · [Errors](#errors) · [Client checklists](#client-checklists)

## Conventions

- **Auth**: every route needs `Authorization: Bearer <RECEIPTS_API_TOKEN>`. No other token is
  accepted (401), e.g. an `API_TOKEN` in the server environment is ignored. There
  are no public receipts routes (use the unprefixed `GET /health` for connectivity). Wrong or
  missing tokens are counted per client IP and answered with `429` + `Retry-After` past a limit; a
  valid token is never throttled. An unset server token answers `503`.
- **Format**: JSON, `snake_case`. Timestamps are UTC ISO 8601 with milliseconds and `Z`
  (`2026-10-31T12:21:21.775Z`); the server also accepts timestamps without milliseconds and with
  offsets. Money is a JSON number in EUR. Dates are `"YYYY-MM-DD"`, times `"HH:MM"` (receipt
  time, no zone), as in the Mac app.
- **Ids**: receipts, line items and dictionary entries are identified by a **client generated
  UUID** (lowercase canonical form on the wire, the server normalises case). `legacy_id` is the
  Mac app's old integer row id, filled only for migrated rows, `null` otherwise; never use it as a
  key.
- **Errors**: HTTP status plus `{"detail": {"code": "...", "message": "...", ...extra}}`. Branch
  on `code` ([list](#errors)). Validation errors of the framework itself (`422`) use the usual
  FastAPI `detail` list.
- **Base**: `https://<domain>/api/v1/receipts`. Below, `{id}` is a receipt UUID.

| Method | Path | Purpose |
|---|---|---|
| `PUT` | `/{id}/photo` | idempotent photo upload, creates the receipt, queues extraction |
| `GET` | `/{id}/photo` | download a photo the server still holds (archive device) |
| `GET` | `/{id}/extraction` | queue state of one receipt |
| `POST` | `/{id}/extraction/retry` | queue the extraction again |
| `POST` | `/sync/push` | send local changes (last write wins) |
| `GET` | `/sync/pull?since=` | receive server changes (change sequence cursor) |
| `GET` | `/archive/pending` | photos not yet archived |
| `POST` | `/{id}/archive-confirm` | archive device confirms its verified copy; server deletes the file |
| `POST` | `/archive/sync` | archive device finished a run |
| `GET` | `/status` | archive, disk, queue and LLM status |
| `GET` | `/taxonomy` | category taxonomy (ordered) |
| `GET` | `/dictionary` | item dictionary (also delivered through pull) |

## Concepts

- **The server extracts.** A phone photographs a receipt, straightens it and converts it to JPEG
  *on the device*, uploads it, and gets the parsed receipt (store, date, total, line items with
  categories) back through `sync/pull` a few seconds later. The server runs the same pipeline as
  the Mac app (vision call, validation, item dictionary, one batched classification call).
- **Offline first.** Clients keep a local copy of receipts, line items and dictionary entries,
  push their edits and pull everything else. Records are never hard deleted: a delete is a
  tombstone (`deleted_at`).
- **The laptop is the photo archive.** The server keeps a photo only until the laptop has stored a
  verified copy and confirmed it; the server never deletes a photo for any other reason, in
  particular never because of its age. Receipt data stays in sync after that, with
  `photo_location: "archived"` so phones can show "on your laptop".

## Data model

### Receipt

```json
{
  "id": "3b241101-e2bb-4255-8caf-4136c566a962",
  "legacy_id": null,
  "store": "Edeka",
  "date": "2026-03-01",
  "time": "09:12",
  "total": 5.73,
  "computed_sum": 5.73,
  "needs_review": false,
  "review_reasons": [],
  "reviewed_at": null,
  "created_at": "2026-10-31T12:21:21.775Z",
  "photo_location": "server",
  "photo_sha256": "823c3951a6fd2d5495e82e3609069270fd9da3a3f5a4e7d56da948fe29217f0f",
  "photo_bytes": 198,
  "photo_media_type": "image/jpeg",
  "uploaded_at": "2026-10-31T12:21:21.775Z",
  "archived_at": null,
  "extraction_status": "done",
  "extraction_attempts": 1,
  "extraction_error": null,
  "extraction_provider": "claude-cli-token/claude-haiku-5-5",
  "extraction_completed_at": "2026-10-31T12:21:21.790Z",
  "updated_at": "2026-10-31T12:21:21.775Z",
  "deleted_at": null
}
```

| Field | Writable by push | Meaning |
|---|---|---|
| `store`, `date`, `time`, `total`, `computed_sum` | yes | the receipt as printed; `date`/`time` may be `null`. After extraction `store` is canonicalised (`"Aldi Süd"`, `"dm"`, ...) or `"Unknown"` |
| `needs_review`, `review_reasons` | yes | what the validation flagged (texts as in the Mac app: sum mismatch, Pfand correction, "No total found on receipt", "Possible duplicate of receipt <id>", ...); recompute them on the client after editing items, like the Mac app |
| `reviewed_at` | yes | **review status**: `null` = not confirmed yet, a timestamp = the user confirmed it. Sidebar order "needs review first" = `reviewed_at == null` first, flag icon = `needs_review` |
| `created_at` | create only | when the receipt was created (upload: `?created_at=` or server time) |
| `updated_at`, `deleted_at` | yes | last-write-wins clock and tombstone, see [Sync](#sync) |
| `photo_location` | create only | `server` (file on the server), `archived` (stored on the archive device, server file removed), `none` (no photo). A push may create a receipt as `none` or `archived` (for data that already lives on the laptop); the value of an existing receipt is changed only by the server |
| `photo_sha256`, `photo_bytes`, `photo_media_type`, `uploaded_at`, `archived_at` | no | facts about the photo; the sha256 stays after archiving |
| `extraction_status` | no | `none` (no photo yet), `queued`, `processing`, `done`, `failed` |
| `extraction_attempts`, `extraction_error`, `extraction_provider`, `extraction_completed_at` | no | queue bookkeeping. `extraction_error` is also set while the status is `queued` after a failed attempt ("retrying") |

`updated_at` is the clock of *client* writes only. Extraction fills the content without touching
it (see [user edits](#a-users-edit-is-never-overwritten)). A receipt created by an upload gets the
upload time (or the client's `created_at`) as `updated_at`.

### Line item

```json
{
  "id": "9773404b-69b9-4a69-848f-2eeb0a80845f",
  "legacy_id": null,
  "receipt_id": "3b241101-e2bb-4255-8caf-4136c566a962",
  "item_dictionary_id": "0625a3cf-1f76-4ece-982c-8ce3214be232",
  "position": 0,
  "raw_text": "Bio Eier 10er",
  "name_de": "Bio Eier 10er",
  "quantity": 1.0,
  "unit_price": 2.49,
  "total_price": 2.49,
  "price_normalized": false,
  "updated_at": "2026-10-31T12:21:21.790Z",
  "deleted_at": null
}
```

One printed line of the receipt (never merged: the same product twice is two rows). `quantity` is
positive, refunds/deposit returns have negative prices. `price_normalized` marks an automatic
Pfand price correction. `position` orders the items of a receipt (ascending, ties by id).
`item_dictionary_id` points at the dictionary entry that carries the category.

### Dictionary entry

```json
{
  "id": "0625a3cf-1f76-4ece-982c-8ce3214be232",
  "legacy_id": null,
  "canonical_name": "bio eier 10er",
  "display_name_de": "Bio Eier 10er",
  "translation_en": "organic eggs",
  "category": "Food",
  "subcategory": "Dairy & Eggs",
  "item_group": "Eggs",
  "aliases": ["bio eier 10er"],
  "is_manual_override": true,
  "needs_review": false,
  "category_flagged": false,
  "suggested_category": null,
  "suggested_parent": null,
  "times_seen": 1,
  "created_at": "2026-10-31T12:21:21.789Z",
  "last_seen_at": "2026-10-31T12:21:21.789Z",
  "updated_at": "2026-10-31T12:30:00.000Z",
  "deleted_at": null
}
```

One canonical product, shared by all receipts; the category lives here (a correction changes every
receipt that uses the entry). `canonical_name` is the normalised name (lowercase, pack sizes and
punctuation removed) and unique among live entries. `is_manual_override = true` means a user set
the category: extraction and re-categorisation never change it. `times_seen`, `last_seen_at` are
server-owned counters; `aliases` is only ever added to (a push is unioned into the stored list).
Merging two entries (as the Mac dictionary editor does) = push the affected line items with the new
`item_dictionary_id` and a tombstone for the merged-away entry.

**Flag fields** (additive; see [Flagged categories](#flagged-categories)): `category_flagged`
(default `false`) = the extraction found no good category in the taxonomy, so the category is the
fallback `Other > Miscellaneous > General` until a client resolves it; `suggested_category` (short
leaf name, e.g. `"Pet Food"`) and `suggested_parent` (`"Category"` or `"Category > Subcategory"`)
say what is missing. Both suggestions are `null` unless `category_flagged` is `true`. The resulting
taxonomy path is (parent, leaf) for a two-part parent, else (category, leaf, `"General"`). A
flagged entry also has `needs_review: true`, so UIs that only know `needs_review` mark it too.

## Photo upload

`PUT /api/v1/receipts/{id}/photo` with the **raw image bytes** as the body (not multipart).

Headers: `Content-Type: image/jpeg` or `image/png` (or `application/octet-stream`),
optional `X-Content-SHA256: <hex>` (the server rejects the upload if it does not match what it
received, i.e. a damaged transfer). Optional query `?created_at=2026-10-31T12:20:55Z`: when the
photo was taken (used as the receipt's `created_at` / initial `updated_at`; never later than now).

- `{id}` is a UUID the client generated for the receipt. It is the **idempotency key**: send the
  same bytes again (a retry after a lost response, after a restart, after the receipt was archived)
  and nothing changes; you get the current receipt back. Always retry until you get a 2xx.
- First upload: `201 {"created": true, "receipt": {...}}` (`created`: this request stored the
  photo), the receipt has `photo_location: "server"`, `extraction_status: "queued"`. Repeat:
  `200 {"created": false, ...}` with the receipt as it is now (also after extraction or archiving).
- Other bytes under an id that already has a photo: `409 photo_conflict`, nothing is overwritten.
  The same bytes under another id: `409 duplicate_image` with `duplicate_of` (the Mac app's
  "already imported"): drop your local receipt and use the existing one.
- Only **JPEG and PNG**; convert HEIC and straighten/crop on the device first. The type is judged
  from the content, not from the header or a file name: the file must be a *complete* JPEG (start
  and end markers) or PNG (valid chunks and checksums) with sensible dimensions (at most 20000 px
  per side); anything else is `415 invalid_image`. A `Content-Type` that names the other of the two
  types is `415 content_type_mismatch`.
- Maximum **15 MB** (`413 too_large`). Practical advice: send a JPEG of about 2000-2600 px on the
  long edge and well under 5 MB; the Claude API rejects images over 5 MB, so a bigger photo is
  stored but its extraction fails with an explanatory `extraction_error`.
- The server stores the file under a name derived from the UUID only and records its sha256.

```
PUT /api/v1/receipts/3b241101-e2bb-4255-8caf-4136c566a962/photo
Content-Type: image/jpeg
X-Content-SHA256: 823c3951a6fd2d5495e82e3609069270fd9da3a3f5a4e7d56da948fe29217f0f

<binary>
```
```json
{
  "created": true,
  "receipt": {
    "id": "3b241101-e2bb-4255-8caf-4136c566a962",
    "legacy_id": null,
    "store": null,
    "date": null,
    "time": null,
    "total": null,
    "computed_sum": null,
    "needs_review": false,
    "review_reasons": [],
    "reviewed_at": null,
    "created_at": "2026-10-31T12:21:21.775Z",
    "photo_location": "server",
    "photo_sha256": "823c3951a6fd2d5495e82e3609069270fd9da3a3f5a4e7d56da948fe29217f0f",
    "photo_bytes": 198,
    "photo_media_type": "image/jpeg",
    "uploaded_at": "2026-10-31T12:21:21.775Z",
    "archived_at": null,
    "extraction_status": "queued",
    "extraction_attempts": 0,
    "extraction_error": null,
    "extraction_provider": null,
    "extraction_completed_at": null,
    "updated_at": "2026-10-31T12:21:21.775Z",
    "deleted_at": null
  }
}
```

Duplicate:

```json
{"detail": {"code": "duplicate_image", "message": "This exact photo belongs to another receipt.",
            "duplicate_of": "3b241101-e2bb-4255-8caf-4136c566a962"}}
```

**Order of operations for a client**: create the local receipt with its UUID, upload the photo
*first*, and only then push anything about that receipt. (A pushed receipt with no content is
harmless, see [stubs](#a-users-edit-is-never-overwritten), but the photo upload is what creates the
server side receipt with its queue entry.) Uploading a photo for a receipt that exists only through
push (no photo yet) attaches the photo to it and queues the extraction.

## Extraction queue

State per receipt, mirrored into the receipt (`extraction_status`, `extraction_attempts`,
`extraction_error`) so it arrives through pull, and readable on its own:

```
GET /api/v1/receipts/{id}/extraction
{"receipt_id": "3b24...", "status": "done", "attempts": 1, "max_attempts": 3, "last_error": null,
 "queued_at": "2026-10-31T12:21:21.777Z", "not_before": null,
 "started_at": "2026-10-31T12:21:21.786Z", "finished_at": "2026-10-31T12:21:21.791Z"}
```

- `queued` -> `processing` -> `done` | `failed`. One extraction runs at a time, in the server
  process; the queue is persisted, so it survives restarts (a job interrupted by a restart is
  queued again).
- A failed attempt that can plausibly succeed again (rate limit, timeout, overloaded API, invalid
  model answer) goes back to `queued` with an exponential backoff (`not_before`) until
  `max_attempts` (3) attempts are used; then it is `failed`. Errors that retrying cannot fix
  (refusal, expired subscription login, photo too large for the API, photo no longer on the server)
  fail at once. `extraction_error` says why.
- **A failed extraction leaves the photo and the receipt in place**: the receipt exists with
  empty content, `extraction_status: "failed"` and the error text. Show it ("could not read this
  receipt") and offer *Retry* or *enter manually* (edit and push).
- Without a configured LLM credential on the server, jobs simply stay `queued` (see `llm` in
  [status](#status-and-reminders)).
- `POST /api/v1/receipts/{id}/extraction/retry` (no body) queues it again with a fresh attempt
  budget: `202` with the extraction state. `409 already_queued` if it is queued or running,
  `409 photo_not_on_server` if the photo was already archived (or never uploaded), `404` if the
  receipt is unknown. Retry also works on a `done` receipt (re-read it with the current model).
- Result: a successful run replaces the receipt's header fields and **tombstones the old line items
  and creates new ones**; `reviewed_at` is cleared. All of that arrives through pull.

### A user's edit is never overwritten

Rule: **once a client push has been applied to a receipt or to one of its line items, no
extraction (first run or any retry) changes that receipt's content again.** The extraction's raw
answer is then only kept server side for reference. Details:

- "Applied push" = the receipt record or any of its line items was created, changed, confirmed
  (`reviewed_at`) or deleted through `sync/push` and was not `stale`.
- A push that *creates* a receipt with no content at all (no `store`, `date`, `time`, `total`,
  `reviewed_at`, i.e. a stub) does not count: a client may push its local stub before the photo
  upload without blocking the extraction. A stub with the same or an older `updated_at` than the
  server's receipt is `stale` and ignored anyway.
- So: edits made while the extraction is still running win, edits made before a retry win, and a
  retry of an untouched receipt replaces the content freely.
- To discard your edits and re-extract, there is deliberately no switch; delete the receipt and
  upload the photo again (new UUID) if you really want that.

## Sync

### Push

`POST /api/v1/receipts/sync/push`

```json
{
  "device_id": "iphone-demo",
  "dictionary": [ { "id": "0625a3cf-...", "canonical_name": "bio eier 10er", "display_name_de": "Bio Eier 10er",
                    "translation_en": "organic eggs", "category": "Food", "subcategory": "Dairy & Eggs",
                    "item_group": "Eggs", "aliases": ["bio eier 10er"], "is_manual_override": true,
                    "needs_review": false, "category_flagged": false, "updated_at": "2026-10-31T12:30:00Z" } ],
  "taxonomy_additions": [ { "category": "Household", "subcategory": "Pets", "item_group": "Pet Food",
                            "created_at": "2026-10-31T12:29:00Z" } ],
  "receipts": [ { "id": "3b241101-e2bb-4255-8caf-4136c566a962", "store": "Edeka", "date": "2026-03-01",
                  "time": "09:12", "total": 5.73, "computed_sum": 5.73, "needs_review": false,
                  "review_reasons": [], "reviewed_at": "2026-10-31T12:30:05Z",
                  "updated_at": "2026-10-31T12:30:05Z", "deleted_at": null } ],
  "line_items": [ { "id": "3e8556b8-...", "receipt_id": "3b241101-...", "item_dictionary_id": "0625a3cf-...",
                    "position": 0, "raw_text": "Bio Eier 10er", "name_de": "Bio Eier 10er", "quantity": 1,
                    "unit_price": 2.49, "total_price": 2.49, "price_normalized": false,
                    "updated_at": "2026-10-31T12:30:05Z", "deleted_at": "2026-10-31T12:31:00Z" } ]
}
```

Response (one entry per record, in request order taxonomy additions, dictionary, receipts, line
items; `taxonomy_additions` is optional and absent for older clients, which then get exactly the
results they always got):

```json
{
  "server_time": "2026-10-31T12:21:39.102Z",
  "results": [
    {"entity": "taxonomy_addition", "id": "Household > Pets > Pet Food", "status": "applied", "reason": null},
    {"entity": "dictionary", "id": "184bd480-...", "status": "applied", "reason": null},
    {"entity": "receipt", "id": "3b241101-e2bb-4255-8caf-4136c566a962", "status": "applied", "reason": null},
    {"entity": "line_item", "id": "3e8556b8-...", "status": "applied", "reason": null},
    {"entity": "line_item", "id": "6c0b9d6e-...", "status": "rejected",
     "reason": "unknown item_dictionary_id 00000000-0000-4000-8000-000000000000"}
  ]
}
```

Rules:

- **Per-record last write wins.** The pushed record replaces the stored one only if its
  `updated_at` is **strictly newer** than the stored `updated_at`; otherwise it is `stale` and
  nothing changes. Re-pushing the same payload is therefore a no-op (`stale` for everything), so
  clients may resend until they got a response. Clients set `updated_at` to the time of the user's
  edit, only when the user changed the record (not when they merely received or displayed it).
- A record is sent **in full** (all client-writable fields); fields you omit become `null`/default.
  Unknown fields, and server-owned fields (`photo_*`, `archived_at`, `extraction_*`, `times_seen`,
  ...), are ignored. A pushed `deleted_at` is a tombstone; a newer record with `deleted_at: null`
  undeletes.
- **Flag fields of a dictionary entry follow a different rule: each of `category_flagged`,
  `suggested_category`, `suggested_parent` is applied only if the key is present in the pushed
  object; absent keeps the stored value** (clients that predate them re-push entries without them
  and must not wipe a flag). If the pushed `category` / `subcategory` / `item_group` differs from
  the stored triple and `category_flagged` is absent, the flag and both suggestions are cleared
  (the user chose a category = resolution). Afterwards: `category_flagged` false (or `null`
  counts as absent) means both suggestions are stored as `null`; suggestions are trimmed and cut
  to 80 characters. Last-write-wins by `updated_at` is unchanged.
- **Taxonomy additions** (`taxonomy_additions`, optional, append-only, no deletes) are applied
  first, so a dictionary entry of the same request may use the new path. One result per addition
  (`entity: "taxonomy_addition"`, `id` = `"Category > Subcategory > Group"`): `applied` (new);
  `stale` (the path already exists in the bundled taxonomy or in the additions, compared
  case-insensitively; also what re-pushing an addition gives); `rejected` (a part is missing,
  empty, longer than 60 characters, contains `>` or a control character, or 300 additions are
  stored already). `created_at` (optional, ISO UTC) is kept as the ordering key, default: server
  time.
- **A bad record is `rejected` alone** (the rest of the request is applied): invalid ids/dates
  (`"invalid: date: ..."`), unknown `receipt_id` or `item_dictionary_id` (push dictionary entries
  and receipts first or in the same request; the server applies dictionary, then receipts, then
  line items), a dictionary `canonical_name` already used by another live entry ("merge into it
  instead"), a category path that is not in the [taxonomy](#taxonomy-and-dictionary), moving a line
  item to another receipt. Do not retry a rejected record unchanged.
- Everything runs in one transaction; the HTTP status is `200` unless the whole request is malformed
  (`422`) or unauthorised.
- A receipt unknown to the server can be created by push (manual receipt without photo, or data
  whose photo already lives on the laptop: `photo_location: "archived"`). Its photo can still be
  uploaded later unless it was created as `archived`.

### Pull

`GET /api/v1/receipts/sync/pull?since=<cursor>&limit=<n>`

- First call: `since=` empty (everything, in pages). Afterwards pass back the `cursor` of the last
  response. Treat the cursor as an opaque string.
- `limit` is the page size (default 2000, max 5000). While `has_more` is `true`, call again
  immediately with the new cursor; persist the cursor only after the page was applied.
- The cursor is a **server change sequence**, independent of any clock: every change on the server
  (a push, an extraction result, an archive confirmation, a migration) gets a new sequence number,
  so nothing is missed because of clock differences, and a record that changes again later comes
  again. Records may repeat across pulls; applying a record twice is harmless.
- Each response contains `dictionary`, `receipts` and `line_items` (full records, tombstones
  included), `server_time` and `taxonomy_version` (refetch `/taxonomy` when it changed), and
  `taxonomy_additions`: **all** client-added category paths, in every response, ordered by
  `created_at`, `id` (a short list; no cursor, not part of the change sequence). Replace your local
  copy of the additions with it.

```json
{
  "cursor": "c16",
  "has_more": false,
  "server_time": "2026-10-31T12:21:39.119Z",
  "taxonomy_version": "1b014dce5b21c26a",
  "taxonomy_additions": [ {"category": "Household", "subcategory": "Pets", "item_group": "Pet Food",
                           "created_at": "2026-10-31T12:29:00.000Z"} ],
  "dictionary": [ {"...": "dictionary entries"} ],
  "receipts": [ {"...": "receipts"} ],
  "line_items": [ {"...": "line items"} ]
}
```

Client rules when applying a pulled record:

1. Apply all three lists of a page together, then resolve references (a line item may arrive
   before its dictionary entry within a page).
2. If you have **no unsent local edit** of that record, replace your copy with the server's.
3. If you have an unsent local edit, keep yours and push it: last write wins decides (compare
   `updated_at`); the server's copy comes back on a later pull if it won.
4. Server-owned fields (`photo_location`, `archived_at`, `extraction_*`, `times_seen`) always come
   from the server, even next to a local edit.
5. A tombstone (`deleted_at` set) means: remove from lists. Keep the row so a later undelete
   works; a stale local record that is older than the tombstone loses.
6. `cursor` is global to the database (all clients see the same sequence); keep one per
   server/account.

Extraction results reach clients exactly this way: after the upload the receipt shows
`extraction_status: "queued"`; poll `sync/pull` (every few seconds while the app shows a pending
receipt) until it says `done` and the fields and line items are there, or `failed`.

## Photo archive (laptop)

The laptop (Mac app) is the long-term photo archive. A device identifies itself as the archive
device by calling the archive endpoints with its `device_id`; the server remembers when it last did
(`last_archive_sync_at`) and from which device.

**Retention rules (firm)**

- The server **never deletes a photo because of its age**, and no job does either. The only thing
  that removes a photo is a successful `archive-confirm`.
- `archive-confirm` needs the **sha256 of the copy the laptop saved**. Match and finished
  extraction -> the server records `archived_at`, sets `photo_location: "archived"` and deletes the
  file. Mismatch -> `409 sha256_mismatch`, the file stays. Confirming twice is a no-op
  (`already_archived`).
- Extraction must be finished: `done`, or `failed` together with `accept_failed: true` (the user
  gave up on that receipt; the receipt data stays). `queued`/`processing` or an un-accepted
  `failed` -> `409` and the file stays.
- Files that no database row points at are never deleted (they may belong to a restored database).

### Protocol for the archive client

1. `GET /archive/pending` -> `{"count": n, "photos": [...]}`:
   ```json
   {
     "count": 1,
     "photos": [
       {
         "id": "3b241101-e2bb-4255-8caf-4136c566a962",
         "sha256": "823c3951a6fd2d5495e82e3609069270fd9da3a3f5a4e7d56da948fe29217f0f",
         "bytes": 198,
         "media_type": "image/jpeg",
         "uploaded_at": "2026-10-31T12:21:21.775Z",
         "extraction_status": "queued",
         "archivable": false,
         "blocked_reason": "extraction_pending",
         "download": "/api/v1/receipts/3b241101-e2bb-4255-8caf-4136c566a962/photo"
       }
     ]
   }
   ```
   `archivable` is `true` when the extraction is `done`; `blocked_reason` is
   `extraction_pending` or `extraction_failed` otherwise. The list contains deleted (tombstoned)
   receipts too, so their photos get archived as well.
2. For each photo: `GET {download}` (token required; no public links). The response carries
   `Content-Type`, `X-Content-SHA256` and `Cache-Control: private, no-store`. A photo that is no
   longer on the server answers `410 photo_archived` (`404` if there never was one).
3. Save it into the archive folder, flush it to disk, **re-read the saved file and compute its
   sha256** (do not trust the download's header), compare with `sha256` from the list.
4. If equal and the photo is `archivable`:
   `POST /{id}/archive-confirm {"sha256": "<hex of the saved file>", "device_id": "macbook-archive"}`
   (+ `"accept_failed": true` only when the user explicitly gave up on a failed receipt).
   ```json
   {"status": "archived", "receipt_id": "3b241101-e2bb-4255-8caf-4136c566a962"}
   ```
   Repeat: `{"status": "already_archived", ...}`. Mismatch:
   ```json
   {"detail": {"code": "sha256_mismatch",
               "message": "The checksum of the saved copy does not match the server's photo; it was kept."}}
   ```
   Not yet archivable: `409` with `code` `extraction_pending` or `extraction_failed`. Keep the saved
   file and confirm again later; never delete the local copy before a success answer.
5. At the end of **every** run (also when nothing was pending): `POST /archive/sync
   {"device_id": "macbook-archive"}` -> `{"last_archive_sync_at": "2026-10-31T12:21:39.115Z"}`.
   A successful confirm counts as a sync too.

After the archive, `sync/pull` keeps delivering the receipt with `photo_location: "archived"`,
`archived_at`, and the unchanged `photo_sha256`, so phones can show "on your laptop". The server can
no longer re-extract such a receipt (`retry` answers `409 photo_not_on_server`), and a late retry of
the original upload is answered `200` without storing the photo again.

## Status and reminders

`GET /api/v1/receipts/status`:

```json
{
  "server_time": "2026-10-31T12:21:39.104Z",
  "last_archive_sync_at": null,
  "archive_device_id": null,
  "unarchived_count": 1,
  "unarchived_bytes": 198,
  "oldest_unarchived_at": "2026-10-31T12:21:39.074Z",
  "disk_free_bytes": 110736093184,
  "disk_total_bytes": 494332366848,
  "archive_reminder_days": 30,
  "disk_warning_free_mb": 2048,
  "archive_overdue": false,
  "disk_warning": false,
  "queue": {"queued": 0, "processing": 0, "done": 1, "failed": 0},
  "flagged_items": 0,
  "llm": {"provider": "none", "requested_provider": "auto", "credential_configured": false,
          "billing": null, "model": "claude-haiku-5-5", "effort": "high"}
}
```

- `unarchived_count` / `unarchived_bytes`: photos the server still holds (`photo_location:
  "server"`).
- `archive_overdue`: there are unarchived photos **and** the archive device has not synced for more
  than `archive_reminder_days` (default 30; configurable `RECEIPTS_ARCHIVE_REMINDER_DAYS`).
  Before the first ever archive sync the age of the oldest waiting photo is used instead.
- `disk_warning`: the server's free disk is below `disk_warning_free_mb` (default 2048;
  `RECEIPTS_DISK_WARNING_FREE_MB`).
- Clients should show a banner when either flag is true ("N photos wait on the server, archive them
  on your laptop"). `flagged_items` = live dictionary entries
  waiting for a category ([Flagged categories](#flagged-categories)); `queue` counts extraction jobs; `llm.provider` is `none` when no credential is
  configured (receipts then stay `queued`). `llm` never contains a credential.
- A daily scheduled job (09:00 `Europe/Vienna`, `RECEIPTS_REMINDER_TIME`) sends a reminder when
  `archive_overdue` or `disk_warning` is true, at most once every 3 days
  (`RECEIPTS_REMINDER_REPEAT_DAYS`). **Delivery needs `RECEIPTS_NOTIFY_URL`** (an ntfy.sh-style URL
  that the operator's phone listens to). The backend has no other channel to reach him, so without it the
  reminder is only written to the server log and the status flags above are the signal.

## Taxonomy and dictionary

- `GET /api/v1/receipts/taxonomy`: the ordered category tree (the same data the Mac app bundles,
  `category_taxonomy.json`), for category pickers. A sub-category without item groups offers
  `["General"]`.
  ```json
  {"version": "1b014dce5b21c26a",
   "categories": [{"name": "Food", "subcategories": [
       {"name": "Vegetables", "item_groups": ["Tomatoes", "Leafy Greens", "Root Vegetables", "..."]}, "..."]},
     "..."],
   "notes": {"Food > Vegetables > Tomatoes": "Includes cherry, roma, ..."}}
  ```
  A dictionary entry's `category` / `subcategory` / `item_group` must be a path of this tree
  (otherwise the push of that entry is `rejected`). Refetch when `taxonomy_version` of a pull
  changes. The tree is the **merged** taxonomy: the bundled one plus the `taxonomy_additions`
  (each appended at the end: a group to an existing subcategory, else a new subcategory of an
  existing category, else a new category). `version` is unchanged while there are no additions
  and changes with every addition.
- `GET /api/v1/receipts/dictionary[?include_deleted=true][&flagged=true]`: all entries
  (`flagged=true`: only live flagged entries, i.e. what still needs a category),
  `{"count": 2, "taxonomy_version": "...", "entries": [...]}`. Normally not needed: entries arrive
  through pull. Stats (Overview charts, exports) stay on the client, computed from the synced
  receipts, line items and dictionary.

## Flagged categories

When the extraction LLM knows what an item is but no category of the (merged) taxonomy is a
reasonable home, it does not force a poor fit: the dictionary entry is created with
`category_flagged: true`, the fallback category `Other > Miscellaneous > General`,
`needs_review: true` and a proposal (`suggested_category`, `suggested_parent`). Unreadable names
are not flagged (plain fallback, `needs_review`). Flagging is rare, and a proposal that names a
path that exists is simply assigned. Exact name / alias hits on a flagged entry return it
unchanged (no new LLM call); look-alike names (fuzzy match) do not inherit it. One resolution fixes
every receipt that uses the entry.

Find them: `GET /dictionary?flagged=true`, the count in `/status.flagged_items`, or
`category_flagged` on pulled entries. To **resolve**, push the dictionary entry with the chosen path,
`is_manual_override: true`, `needs_review: false`, `category_flagged: false` (and a newer
`updated_at`). Either an existing path from the taxonomy, or, when the path is new, a
`taxonomy_additions` item for it in the same push request (applied before the entry). There is no
deletion of additions in this version, and nothing is resolved automatically: an unresolved flag
stays until a client pushes.

## Errors

| HTTP | `code` | When |
|---|---|---|
| 400 | `empty_body` | photo upload without a body |
| 400 | `bad_cursor` | `since` is not a cursor the server issued |
| 401 | - | missing / wrong token; header `WWW-Authenticate: Bearer` |
| 404 | `receipt_not_found`, `no_photo`, `photo_file_missing` | unknown receipt; nothing to download |
| 409 | `photo_conflict` | other bytes already stored under this receipt id |
| 409 | `duplicate_image` | same bytes belong to another receipt (`duplicate_of`) |
| 409 | `photo_archived` | upload of different bytes for an archived receipt |
| 409 | `sha256_mismatch` | archive-confirm checksum differs; file kept |
| 409 | `extraction_pending`, `extraction_failed` | archive-confirm before the extraction finished / failed without `accept_failed` |
| 409 | `already_queued`, `photo_not_on_server` | extraction retry not possible |
| 409 | `no_photo` | archive-confirm for a receipt without a server photo |
| 410 | `photo_archived` | download of a photo that was archived and removed |
| 413 | `too_large` | upload over `max_bytes` (15 MB) |
| 415 | `invalid_image`, `content_type_mismatch` | not a complete JPEG / PNG |
| 422 | `invalid_id`, `sha256_mismatch` | not a UUID; `X-Content-SHA256` does not match the body |
| 429 | - | too many wrong tokens from this IP (`Retry-After`) |
| 503 | - | `RECEIPTS_API_TOKEN` is not configured on the server |

## Client checklists

**Phone (iOS / Android)**
1. Capture, straighten, convert to JPEG (<= 5 MB), create a UUID, store locally.
2. `PUT /{id}/photo` until 2xx (same bytes, same UUID; idempotent). On `409 duplicate_image`
   discard the local receipt.
3. Loop `sync/push` (local edits) and `sync/pull` (results, other devices).
4. Show `extraction_status` / `extraction_error`; offer retry (`POST .../extraction/retry`) or manual
   entry. Show "on your laptop" for `photo_location: "archived"`.
5. Show a banner when `status.archive_overdue` or `status.disk_warning` is true.

**Mac / archive device**
1. Same as the phone for receipts, plus the [archive protocol](#protocol-for-the-archive-client)
   after each sync (and at least regularly, the server reminds after 30 days).
2. Migrating the existing Mac database is a one-off job for the backend operator
   (`python -m receipts.migrate_mac_data`, see `deploy/README.md`, section 8); afterwards the
   Mac app can pull everything. Its photos are marked `archived` and are never uploaded.
