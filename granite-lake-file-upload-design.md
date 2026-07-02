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

### 6.1 New event

Add a `FileAttested` event parallel to `PhotoAttested`.

```move
struct FileAttested has copy, drop {
     file_hash: vector<u8>,
     uploader: address,
     domain: vector<u8>,
     walrus_blob_id: Option<vector<u8>>, // none for local-only mode
     file_type: u8, // 0=pdf, 1=image, 2=other
     timestamp_ms: u64,
}
```

### 6.2 Verification model

- Verification remains independent of storage location.
- Verifier recomputes `sha256(file_bytes)` and compares with `FileAttested.file_hash`.
- On-chain event remains the source of truth.

## 7. Storage strategy

### 7.1 Path A: Walrus (shared access)

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
  - storage path (Walrus/local)
  - transaction link
- Reuse existing hash-match verification pattern for file verification

## 10. Open decisions

1. Does domain admin require routine access to file content, or hash verification only?
2. Should supervisor be included in v1 file access policy, or deferred?
3. Is v1 file type scope limited to PDF + image, or do we include docx from day one? A: We should support all abritrary file types
4. Looking ahead, how would one query by wallet address, eg "get me all file hashes from wallet X" 

## 11. Rollout plan

1. Implement post-fingerprint Select Method routing
2. Keep existing photo path intact behind chooser
3. Implement Upload File UI flow (select, preview, success)
4. Add API upload endpoint + idempotency by hash
5. Add `FileAttested` event and submission flow
6. Update history with Photos/Files/All filter
7. Release local-only path first
8. Add Walrus shared-access path after access policy confirmation
