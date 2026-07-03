# Granite Lake — File Upload & Attestation Design

**Author:** Nethmi Jayakody
**Status:** Draft for review  
**Related:** Sangwon request for contracts/QC report file uploads

## 1. Problem

Granite Lake currently supports photo attestation only. We need to support arbitrary file uploads (PDFs, QC reports, contracts, etc.) with the same on-chain verification guarantees as photos.

## 2. Product goals

- Allow an authenticated user to upload a file and attest it on Sui.
- Keep verification storage-independent: anyone can recompute file hash and match against on-chain events.
- Support both shared-access and local-only storage paths.
- Keep UX simple by routing both "take photo" and "upload file" from one post-authentication screen.
- Show files and photos together in history with filters.

## 3. Non-goals for v1

- Complex per-file ACL matrix beyond uploader and domain admin.
- OCR/indexing/search over document contents.

## 4. Existing patterns to reuse

### 4.1 Granite Ridge patterns

- Reuse file hashing and attestation approach from Granite Ridge policy attestation.
- Reuse idempotent processing mindset from webhook/event workflows.

### 4.2 Granite Lake patterns

- Keep the same trust model as photo attestation: hash is source of truth.
- Keep public verification event-driven.
- Keep storage decoupled from verification.

## 5. UX flow (updated)

### 5.1 New post-fingerprint method selection

After fingerprint authentication succeeds, users land on a new chooser screen before starting an attestation.

Actions:

1. Take a Picture
2. Upload File

This becomes the single entry point for new attestations.

### 5.2 UI references

- Select method design: https://drive.google.com/file/d/1g9rO1QBEiBXwnDBKKzuOtVKjyVXNuPdt/view?usp=drive_link
- File preview design: https://drive.google.com/file/d/1drAii93oxCdqJnHQrk_Tt4ROvMrXNzsK/view?usp=drive_link
- File success design: https://drive.google.com/file/d/174JyGIOGdBtGcbxtXVQk1UVVieeWdySg/view?usp=drive_link

### 5.3 End-to-end flow

1. Fingerprint authentication success
2. Select Method screen
3. User picks one path:
   - Take a Picture: continue existing camera flow
   - Upload File: enter new file flow

### 5.4 Upload File path

1. Select Method -> Upload File
2. File picker opens
3. File preview screen shows:
   - file name
   - size
   - file type
   - storage mode indicator
4. Confirm upload
5. Hash + attest processing state
6. Success screen with:
   - attestation success state
   - hash (truncated + copy)
   - transaction reference
   - actions: view history, upload another

### 5.5 Take a Picture path

No change to core photo attestation logic. Only entry point changes:

1. Fingerprint success -> Select Method
2. Select Method -> Take a Picture
3. Continue current photo flow

### 5.6 UX behavior requirements

- User can always return to Select Method from both paths before final submit.
- Show clear loading and retry states during hashing/upload/transaction submission.
- Keep button labels and state messages consistent between photo and file flows.

## 6. Contract design

### 6.1 `FileAttested` event

`FileAttested` is defined in `contracts/sources/granite_lake.move` and emitted from `attest_file`. It mirrors `PhotoAttested` in shape so a single indexer can read both:

```move
public struct FileAttested has copy, drop {
    file_hash: vector<u8>,
    user_wallet: address,
    file_id: vector<u8>,
    project_id: vector<u8>,
}
```

Field semantics:

- `file_hash` — raw SHA-256 of the file bytes. Source of truth for verification.
- `user_wallet` — caller's Sui address; the same address that owns the `UserCap` used to sign the tx. (Note: the field is named `user_wallet`, not `uploader`.)
- `file_id` — client-generated identifier for this specific upload (e.g. a UUID). Lets a wallet list its files without scanning storage.
- `project_id` — project/domain tag the file is being attested against. `domain` is **not** on the event; the API resolves it from `user_wallet` via the `Registry` if needed.

Fields that are **not** on the event, by design, because we decided not to integrate Walrus in v1:

- `walrus_blob_id` — storage location is off-chain metadata; the event stays small and storage-agnostic. See §11.6.
- `file_type` — display metadata, not trust-bearing. Recorded off-chain; see §11.5 and §11.6.
- `timestamp_ms` — Sui assigns this on the event envelope at emission time, not in the struct. The indexer reads it from `event.timestampMs` (see §11.5).

### 6.2 Verification model

- Verification remains independent of storage location.
- Verifier recomputes `sha256(file_bytes)` and compares with `FileAttested.file_hash`.
- On-chain event remains the source of truth.

## 7. Storage strategy

### 7.1 Path A: Walrus (shared access) (Not in V1)

Use when another party needs to retrieve file content.

- File bytes stored in Walrus (Seal-encrypted).
- Requires file-access policy support for uploader + domain admin (and optional supervisor).

### 7.2 Path B: Local-only (uploader-only retrieval)

Use when shared content access is not needed.

- File remains on device.
- Only hash + metadata are attested on-chain.
- Lower cost and faster implementation.

### 7.3 Path selection policy

Proposed default:

- Domain-level default set by admin
- Optional per-upload override

Pending product confirmation on admin content access expectations.

## 8. API and processing

### 8.1 Upload processing pipeline

1. Client computes hash from raw file bytes
2. Client calls Fastify upload endpoint
3. API applies storage path logic
4. API submits `FileAttested` transaction on Sui
5. API returns attestation response (new or already-existing)

### 8.2 Idempotency

- Idempotency key: file hash
- Re-uploading identical file bytes returns existing attestation result
- Prevents duplicate attestations for same content

## 9. History and verification UI

Extend existing history to include files and photos in one list.

Requirements:

- Type filter: Photos / Files / All
- File row fields:
  - file name
  - uploaded time
  - hash (truncated + copy)
  - storage path (Walrus/local) : Decided local for V1
  - transaction link
- Reuse existing hash-match verification pattern for file verification

## 10. Open decisions

1. Does domain admin require routine access to file content, or hash verification only?
2. Should supervisor be included in v1 file access policy, or deferred?
3. Is v1 file type scope limited to PDF + image, or do we include docx from day one? A: We should support all abritrary file types
4. Looking ahead, how would one query by wallet address, eg "get me all file hashes from wallet X"

## 11. Indexer (proposed)

### 11.1 Why an indexer

Today, `verification_api` reads attestations by paging Sui's `suix_queryEvents` (see `verification_api/src/services/attestVerification.ts:199`, `:232`). That works for one-off verification of a known hash, but it is not viable for open-ended reads like:

- "all files attested by wallet X" (open question #4)
- "all attestations in domain D in the last 24h"
- "all attestations from a project_id"

`suix_queryEvents` is paginated by checkpoint and bounded in page size; the verification API does not (and should not) hold that scan in memory. A dedicated indexer is the right boundary for these queries.

The indexer is intentionally narrow in scope: it materializes on-chain `PhotoAttested` and `FileAttested` events. **We are focused on file hashes here** — display/storage metadata (file name, mime type, Walrus blob id, file size) is out of scope for the indexer. The on-chain event already carries the only thing that matters for verification: the file hash.

### 11.2 Goals

- Materialize `PhotoAttested` and `FileAttested` events into a Postgres table the rest of the system can query cheaply.
- Support wallet, project_id, and time-range filters for files (and photos, for free).
- Be safe to re-run from any checkpoint without producing duplicates.
- Keep `verification_api` as a thin read layer over the indexed store for file verification too.

### 11.3 Non-goals (v1)

- Indexing non-attestation events (`DomainAdded`, `UserAdded`, etc.) — `verification_api` already covers those.
- Indexing off-chain file metadata (file name, mime type, storage path, Walrus blob id, file size). The event does not carry these, and the indexer does not need them.
- Backfilling from Sui archives before the indexer's first run; we start indexing from the package publish checkpoint.
- Real-time push (websocket fanout) — Postgres + a polling read path is enough for v1.

### 11.4 Architecture

A new TypeScript worker, `indexer/`, runs alongside `server` and `verification_api`. One process per Sui environment (testnet/mainnet) is enough.

```
Sui checkpoint stream  ──>  indexer worker  ──>  Postgres  ──>  verification_api (read-only)
                              │
                              └─ stores parsed on-chain fields per event
```

Three pieces:

1. **Checkpoint cursor** — a small `indexer_state` table holding `last_checkpoint: bigint` per event type (`PhotoAttested`, `FileAttested`). One row per event type so photo and file cursors advance independently if a check fails.
2. **Worker loop** — every N seconds, call `suix_queryEvents({ MoveEventType })` with `cursor = last_checkpoint` and a small page size (e.g. 50). For each event: parse, upsert into `attestations`, advance cursor to `event.id.txDigest` (or the underlying checkpoint sequence number). Use a Postgres advisory lock keyed on the event type so two indexer instances can't double-write.
3. **Read API** — extend `verification_api` with read endpoints that query `attestations` directly. The existing per-hash verify path stays as-is (it works without the indexer and remains the trust anchor); the indexer powers list/history-style reads.

### 11.5 Database schema

Add three migrations under `server/src/db/migrations/`. The server's existing `pool` is reused; no new connection. The table holds on-chain fields only — see §6.1 for the canonical event shapes.

```sql
-- 1. indexer_state: one row per event type
CREATE TABLE indexer_state (
  event_type    text PRIMARY KEY,
  last_tx_digest text NOT NULL,
  last_checkpoint bigint NOT NULL,
  last_event_seq  bigint NOT NULL,
  updated_at    timestamptz NOT NULL DEFAULT now()
);

-- 2. attestations: unified table for attest_photo and attest_file events
-- On-chain fields only. We do not store file_name, file_type, file_size,
-- storage_path, or walrus_blob_id — those are off-chain display/storage
-- concerns and out of scope for the indexer.
-- `domain` is filled by the indexer from the user's UserCap (§11.6); it is
-- not on the event itself.
CREATE TYPE attestation_kind AS ENUM ('attest_photo', 'attest_file');

CREATE TABLE attestations (
  id              bigserial PRIMARY KEY,
  kind            attestation_kind NOT NULL,
  tx_digest       text NOT NULL,
  checkpoint      bigint NOT NULL,
  event_seq       bigint NOT NULL,
  occurred_at_ms  bigint NOT NULL,        -- from Sui event envelope
  indexed_at      timestamptz NOT NULL DEFAULT now(),

  -- common
  user_wallet     text NOT NULL,
  domain          text,                   -- resolved from UserCap; see §11.6
  project_id      text NOT NULL,
  content_hash    text NOT NULL,          -- hex of photo_hash / file_hash

  -- file-only on-chain field (NULL for photos)
  file_id         text,

  UNIQUE (kind, tx_digest, event_seq),
  CHECK (kind <> 'attest_file' OR file_id IS NOT NULL)
);

-- Symmetric across both kinds: a "list attestations for wallet X" query is
-- equally valid for photos and files. The non-partial btree covers both
-- kinds with no asymmetry; a separate partial index is not needed.
CREATE INDEX attestations_user_wallet_idx  ON attestations (user_wallet, occurred_at_ms DESC);
CREATE INDEX attestations_domain_idx       ON attestations (domain,      occurred_at_ms DESC);
CREATE INDEX attestations_project_idx      ON attestations (project_id,  occurred_at_ms DESC);
CREATE INDEX attestations_content_hash_idx ON attestations (content_hash);
```

The `UNIQUE (kind, tx_digest, event_seq)` plus `ON CONFLICT DO NOTHING` is the dedup primitive — re-running from an older checkpoint is safe.

### 11.6 Worker details

- **Cadence:** poll every 5s when idle, immediately continue while a page returns 50 events. Backoff to 30s on RPC errors; alert after 5 consecutive failures.
- **Page size:** 50 events per call, matching what `verification_api` already uses.
- **Cursor advancement:** only after the row is committed, never before. On crash mid-page, the next run re-sees the same events; the `UNIQUE` constraint absorbs them.
- **Reorg safety:** Sui is checkpoint-finalized, so within a checkpoint events are stable. The worker only advances `last_checkpoint` after the whole page is committed; if the RPC returns events from a checkpoint that later gets replaced, the worker will re-process them on the next pass and `ON CONFLICT DO NOTHING` keeps the table correct.
- **Backpressure:** if Postgres is slow, drop pages with `LIMIT 50` and re-poll; do not buffer unbounded in memory.
- **Domain resolution:** `domain` is not on the `attest_photo` / `attest_file` events — it lives on the user's `UserCap` (`granite_lake.move:30-34`, fields `id`, `domain`, `user_wallet`). Before inserting each row, the worker looks up the `UserCap` for `user_wallet` via `suix_getOwnedObjects` filtered on the `UserCap` struct type, reads `domain` from the object, and stores it on the row. To avoid one Sui RPC per event, the worker keeps a small in-memory `wallet -> domain` cache (and a `user_caps` table) so repeated events from the same wallet reuse the cached value.
- **Observability:** `/health` endpoint exposing `last_checkpoint` per event type, `attestations` row count, and `user_caps` row count, with a 5-minute freshness alert.

```sql
-- 3. user_caps: indexer-maintained wallet -> domain lookup
-- Populated on first sighting of each wallet during attestation indexing.
-- Read by the API to filter attestations by domain without a Sui RPC hop.
CREATE TABLE user_caps (
  user_wallet   text PRIMARY KEY,
  domain        text NOT NULL,
  user_cap_id   text NOT NULL,            -- Sui object id of the UserCap
  resolved_at   timestamptz NOT NULL DEFAULT now(),
  last_seen_at  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX user_caps_domain_idx ON user_caps (domain);
```

`user_caps` is best-effort, not a source of truth: if a user's `UserCap` is transferred to a new wallet, the next attestation from that wallet updates `user_caps` on first sight. Historical rows keep whatever `domain` was resolved at index time — the read API can document this as a known lag. We do **not** try to rewrite old rows when a domain changes; the indexer's job is to record what was true at attestation time.

### 11.7 New `verification_api` endpoints

Read-only, no signer needed, all backed by `attestations` (and joined to `user_caps` for the wallet→domain cache):

- `GET /files/by-wallet/:wallet?limit=&before=` → list of `file_id`, `content_hash`, `project_id`, `domain`, `occurred_at_ms`, `tx_digest`. This directly answers open question #4 ("get me all file hashes from wallet X").
- `GET /files/by-hash/:hash` → exists today for verify; extend response with `tx_digest`, `user_wallet`, `domain`, `project_id`, `file_id` so a client has the chain anchor.
- `GET /files/by-domain/:domain?limit=&before=` → all files in a domain, regardless of wallet. Backed by `attestations_domain_idx`. Useful for admin/domain views.
- `GET /files/by-project/:projectId?limit=&before=` → for admin/project views.

The existing per-hash verification path (recompute hash, match against event) stays untouched — it is the trust anchor and must not depend on the indexer being up.

### 11.8 Deployment and runbook

- New `indexer/` package at the repo root with its own `package.json`, `tsconfig.json`, and `Dockerfile`. Reuses the workspace's existing TypeScript + ESLint config.
- One deployment per Sui environment. `docker compose` adds a service next to `server` and `verification_api` with `restart: always`.
- Env: `SUI_RPC_URL`, `SUI_NETWORK`, `SUI_PACKAGE_ID`, `SUI_MODULE`, `DATABASE_URL` (same Postgres as `server`), `POLL_INTERVAL_MS`, `EVENT_TYPES=PhotoAttested,FileAttested`.
- Runbook entry: if `last_checkpoint` stalls for >10 min, page on-call; if `attestations` row count diverges from `suix_queryEvents` over a known checkpoint range, trigger a re-index by resetting `indexer_state.last_tx_digest` to the previous safe digest.

### 11.9 Open items for the indexer

1. Decide whether to backfill from a known safe checkpoint at launch, or start at `SUI_PACKAGE_ID` publish time. Default: package publish time.
2. Decide retention — keep all rows forever, or archive `attestations` older than N years? Default: keep forever, the table is small (one row per attestation, indexed by hash).

## 12. Rollout plan

1. Implement post-fingerprint Select Method routing
2. Keep existing photo path intact behind chooser
3. Implement Upload File UI flow (select, preview, success)
4. Add API upload endpoint + idempotency by hash
5. Add `FileAttested` event and submission flow
6. Update history with Photos/Files/All filter
7. Release local-only path first
8. Add Walrus shared-access path after access policy confirmation
