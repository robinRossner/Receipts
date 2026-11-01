# Decisions

Design decisions of the Receipts server.

## Receipts backend (2026-10-31)

Contract: `docs/api/receipts.md`; runbook: `deploy/README.md`.

- **Own database.** `receipts.db` with its own Alembic chain (`backend/receipts/alembic`), never part of
  any other database. Sync identity = client UUID, the Mac integer id survives as `legacy_id`.
  Offline-first sync: per-record last write wins by client `updated_at`, tombstones, pull by a
  server change sequence (triggers), but without history windows.
- **`updated_at` is the clock of client writes only.** Extraction and archiving change content but
  not `updated_at`, so an edit with an older clock than an extraction still wins and an extraction
  can never beat an edit. On top, a receipt whose content was edited through a push
  (`user_edited_at`) is never touched by an extraction again, retries included.
- **Model.** `claude-haiku-5-5` (what the Mac app's Messages API provider uses; `RECEIPTS_LLM_MODEL`
  changes it for both providers; the Mac's CLI alias `haiku` maps to the same model). Haiku 5.5 is
  current, not retired.
- **Providers.** `claude_code` (`claude -p` on the subscription, photo as a base64 image block in a
  stream-json user message, no tools, `ANTHROPIC_API_KEY` never in the subprocess environment) and
  `api` (official SDK, `output_config.format`, `stop_reason` checked first), `auto` prefers the
  subscription. No credential: jobs stay queued.
- **Photos.** The laptop is the archive: the server deletes a photo only on a matching sha256
  confirmation after a finished extraction (`failed` needs `accept_failed`), never by age, never
  files without a row. Backup: one `rsync --delete` mirror of the unarchived photos, not dated
  copies (bounded disk, no resurrected photos), also pulled to the Mac (`deploy/pull-backup.sh`).
- **Reminders** (`archive_overdue`, `disk_warning`) are status fields plus a daily job; delivery
  needs `RECEIPTS_NOTIFY_URL` (ntfy style) because the backend has no other channel to reach the operator.
- **Image size.** The server accepts JPEG/PNG up to 15 MB; the Messages API accepts images up to
  5 MB, so clients should send about 2500 px JPEGs (no image library on the server).

## Own server, same VM (2026-10-31)

- **Fully separate server.** Own code (`backend/`, with its own small copies of bearer auth,
  failed-token throttle, settings base, db helpers, redaction and scheduler helper), own deployment
  (`/opt/receipts`), own data (`/opt/receipts/deploy/data`), own backups and nightly cron (03:45).
  Only the VM, the domain and the TLS-terminating Caddy of another stack are shared; Caddy routes `/api/v1/receipts/*`
  to the container alias `receipts-backend` on the existing Docker network.
- **URLs, token, Alembic unchanged.** `/api/v1/receipts/...`, `RECEIPTS_API_TOKEN` (the only token
  accepted), revision `0001` and its chain, so the live database needs no migration.
- **Compose service `receipts-backend`, project `receipts`.** The service name becomes a network alias;
  `backend` is taken by the other stack on the shared network. The project name is pinned because both
  stacks live in a directory called `deploy`.

## Flagged categories (2026-10-31)

- **The flag lives on the dictionary entry** (`category_flagged`, `suggested_category`,
  `suggested_parent`; migration `0002`), because the category does. One resolution fixes every
  receipt that uses the item; the entry is also what the exact-name cache returns, so no further
  LLM call is made for it. Fuzzy matching ignores flagged entries (a poor-fit fallback must not be
  cemented for look-alikes).
- **`needs_review` is set as well** on a flagged entry, so UIs that predate the flag still mark it;
  resolving sets it false again.
- **Taxonomy additions are append-only** (no delete, max 300) and not part of the change sequence:
  pull sends all of them every time, a clients replaces its copy. The merged taxonomy (bundled +
  additions, appended at the end) is read from the database per use (push validation, extraction,
  `/taxonomy`); `taxonomy_version` is unchanged without additions. A wrongly added category costs
  nothing but a picker entry; deleting one would orphan entries that use it.
- **Backward compatible by presence.** The flag fields of a pushed dictionary entry apply only when
  the key is present, and a changed category triple without `category_flagged` clears the flag:
  Android and old Mac / iOS clients, which re-push entries without the new fields, can neither wipe
  a flag by accident nor leave one behind after choosing a category. All wire additions are optional.
- **No auto-delete / auto-resolve.** A flag stays until a client resolves it; the LLM's suggestion is
  only a proposal.
- **The flag UI is one shared screen.** `FlaggedItemsView` is in both apps. On the Mac it replaces the receipt in the review
  pane (a quiet sidebar entry, ⌘3), so the list stays usable and a receipt link is one click; on the iPhone it is pushed from
  a row under the Overview total, because flagged items are what inflates "Other" there, and the receipts tab stays about
  receipts. Both entries are hidden at zero; the row in a receipt opens a one-item version. The one-tap add has no undo, as
  taxonomy additions are append-only.
- **The Mac confirms like the iPhone.** `Confirm all` and `Looks good` leave receipts still being read or failed alone (with
  sync on, a confirmation is an applied push, which keeps the extraction out for good; see the API doc), so the unsafe
  `confirmAllWithoutFlags` is gone.
