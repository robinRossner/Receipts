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
- **Model.** `claude-haiku-5-5` at effort `high` (see "Model choice" below). `RECEIPTS_LLM_MODEL` and
  `RECEIPTS_LLM_EFFORT` change it for both providers; production leaves them unset.
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

## Parsing fixes (2026-11-01)

- **The model sees the receipt at 1568 px on the long edge** (Mac/iOS `DocumentScanner.modelMaxDimension`), not 1024:
  a tall receipt reached the model at about 241x1024 and was misread, at 1568 px the same one read 18/18 exact.
  Only the picture sent to the model is scaled; stored and uploaded photos are untouched (phones upload up to
  2500 px). The quality steps down from 0.95 if the JPEG would pass 4.5 MB (the API limit is 5 MB). The server
  never rescales a stored photo, and the API works at 1568 px itself.
- **Store names are matched by whole words,** not by exact string, in Swift (`ReceiptPipeline.canonicalizeStore`)
  and the server (`canonicalize_store`), run against the same table of cases: "EDEKA Musterstadt" -> Edeka,
  "REWE Markt GmbH" -> Rewe, "Penny-Markt" -> Penny, "ALDI SÜD" / "ALDI SUED" -> Aldi Süd. Penny only as the first
  word and dm only as "dm" / "dm drogerie ..." (too short or too common elsewhere); a bare "Aldi" stays as printed.
  Stored receipts are not rewritten. Android keeps its exact-match table until it is ported.

## Model choice and the flag gap (2026-11-01)

- **Haiku 5.5 at high effort, hardcoded.** Picked from a 30-receipt comparison of models and effort levels:
  with `claude-haiku-5-5` at `high`, 29 of 30 receipts were exact in every run. The exception is one Edeka receipt
  with text lines between items, where prices shift against names: wrong in 5 of 11 runs, 1 of them with no review flag.
  The Mac app hardcodes the pair in one place (`ClaudeModel` in `LLMSettings.swift`: `--model` / `--effort` for the
  CLI backends, `model` / `output_config.effort` for the API; the free-text model fields in Settings are gone) and
  the server defaults to it (`DEFAULT_MODEL`, `DEFAULT_EFFORT` in `backend/receipts/settings.py`; `/status` shows
  both). The Mac's default backend is now the Claude connection (the `claude` CLI login), Ollama stays selectable.
- **Alternative: Sonnet 5.5 at low effort,** the next best option, at about 16.7x the usage of Haiku high. To switch the
  server, set `RECEIPTS_LLM_MODEL=claude-sonnet-5-5` and `RECEIPTS_LLM_EFFORT=low` in `backend/.env.production` and run
  `deploy/push.sh user@your-server --with-env`; on the Mac change the two constants in `ClaudeModel` and rebuild.
- **A readable item filed under Other > Miscellaneous > General is flagged.** In the test, `no_good_match` never fired
  in 3,184 classifications, while 16 first-pass results were filed straight at the fallback with no flag (so they never
  reached the flagged-items screen). Now an LLM answer that lands on the fallback path for a readable name is flagged
  (with the model's suggestion if it gave one, none otherwise), in Swift (`ItemCategorizer.classifyWithLLM`) and on the
  server (`classify_with_llm`) alike. "Readable" = a word of at least 3 letters with a vowel (`isReadableName` /
  `is_readable_name`); cryptic names ("Hnlt Ktfl", "XQ 7") keep the unflagged fallback the prompt asks for. The prompt
  now says: if nothing fits, set `no_good_match` and propose a category, never choose Miscellaneous for a product you can
  identify. A real check at Haiku high (temp DB): common groceries (Milch, Bananen, Spülmittel) never flagged, "Vinzenz E
  Fleisch" was flagged in 2 of 6 runs and otherwise filed under Meat & Fish.

## Combined prompt and the sign check (2026-11-01)

- **One prompt for the Mac and the server.** The extraction prompt is the short one from the variant `a2_minimal`
  (plain instructions, amounts read one by one, no fitting digits to the sum, the JSON shape left to the output
  schema) and the classification prompt is the one from `b2_columns` (the model first writes `identified`, at most 6
  words naming brand and product type, then translates and picks the number; a readable name always gets its best-guess
  group). Both sit in `backend/receipts/extraction/prompts.py` and in `ReceiptExtractor.swift` /
  `ItemCategorizer.swift`; a backend test pins the Swift copies to the Python ones. The schemas have no descriptions
  and list `identified` before `path_number`, as tested; the Mac writes its schema in that property order too
  (`JSONSchema.keyOrder`) instead of alphabetically. Model and effort are unchanged (Haiku 5.5, high).
- **What was dropped.** The abbreviation glossary is gone (its entries overlapped test receipts; the prompt has
  generic rules about shortened German names instead) and so are the old numbered rules and the worked example. The
  taxonomy notes and the client-added categories are still in the category list, the correction retry for invalid
  numbers, the fallback-path flag rule and the flag handling are unchanged. New in the prompt: the number of
  `Other > Miscellaneous > General` is filled in (`%%FALLBACK%%`), because the prompt names it.
- **Result of the evaluation (combined prompt, Haiku 5.5, high effort).** Unseen set: 53/53 prices right and 96.2% of
  items in the exact category. Main set: 218/218 prices, 92.2% exact categories. Repeats: 260/260 prices. Degraded
  photos: 82/85 prices right, every miss flagged for review, 0 receipts wrong without a flag. Usage was 0.97x that of
  the previous prompt.
- **Checked on the production code, with real calls** (the harness running the repo's own prompts, parsers and
  validation; temp copies, no real database): unseen set 53/53 prices, 94.3% exact categories (one item differs from
  the tested run, within the run-to-run spread); repeats 260/260 prices, 92.7% exact categories (tested: 94.2%).
- **Limits.** The unseen set is only 8 Edeka receipts, so it says little about other stores. The flag may now fire too
  rarely: the prompt asks for a best guess for any readable name, so an item that deserves a new category can be filed
  at an imperfect one without a flag. Degraded photos came out slightly worse than with the previous prompt, but
  every miss was flagged for review.
- **Sign check.** A shifted price column keeps the sum right, so `validate_receipt` (Python and Swift, same word
  tables and tests) also reviews a line whose sign does not fit its name: a positive Leergut / Pfandrueckgabe line, or a
  negative amount on a product that is not a discount, deposit or refund. The review reasons say "deposit return has a
  positive amount" or "product has a negative amount" and ask to check whether the price column shifted by a line.
  Names are matched word by word after folding umlauts, never as substrings.
