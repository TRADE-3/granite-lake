# Granite Lake

Granite Lake is a lightweight Sui-based photo and file attestation system.

It allows:

- a contract owner to register domains
- a domain admin to authorize wallets and enable or disable them
- enabled wallets to attest photos and uploaded files on-chain
- public verification through Sui events

The system is intentionally designed to:

- minimize gas cost
- use event-only attestation for scalability
- support fast off-chain indexing and verification

---

# Architecture

## High-level Flow

```text
Contract Owner
    ↓
add_domain(domain, admin_wallet)

Domain Admin
    ↓
add_user(domain, user_wallet)

Contract
    ↓
mint UserCap
transfer UserCap → user wallet

User
    ↓
attest_photo(user_cap, registry, hash, gps, altitude, project_id,
             captured_at, is_online, is_forced_offline, internet_null_reason_hash,
             has_gps, is_gps_forced_null, gps_null_reason_hash, clock)

Contract
    ↓
emit PhotoAttested event

User
    ↓
attest_file(user_cap, registry, hash, file_id, project_id,
            captured_at, is_online, is_forced_offline, internet_null_reason_hash, clock)

Contract
    ↓
emit FileAttested event
```

`captured_at`/`is_online`/`is_forced_offline`/`internet_null_reason_hash` (and, for
photos, `has_gps`/`is_gps_forced_null`/`gps_null_reason_hash`) support field crews
attesting while offline and/or without a GPS fix — see
[the offline-capture design](../granite-lake-offline-capture-design.md) for the full
rationale. `clock` is the shared Sui `Clock` object, used to derive `attested_at`
on-chain so it can't be client-spoofed.

---

# Core Design Principles

## 1. Event-Only Attestation

Photo and file attestations are NOT stored in on-chain maps.

Instead:

```move
event::emit(PhotoAttested { ... })
event::emit(FileAttested { ... })
```

This keeps attestation transactions extremely cheap.

Benefits:

- low gas
- infinite scalability
- easy indexing
- fast verification APIs

---

## 2. Capability-Based Authorization

Users receive a `UserCap` object.

Only wallets holding that capability can call:

```move
attest_photo(...)
attest_file(...)
```

The capability also carries the user's domain so the contract can validate the sender against the correct domain record and enforce enabled or disabled state during attestation.

---

## 3. On-Chain Connectivity & GPS Provenance

Internet and GPS are each independently optional at capture time, and neither is ever allowed to go missing (or have a working state overridden) silently. Whenever a field is null, **or** the crew deliberately overrides an available connection/fix via a client-side force toggle, a reason is required and its hash goes on-chain — the plaintext reason itself never does.

The contract enforces this directly rather than trusting the client:

```move
assert!(
    internet_null_reason_hash.is_empty() == (is_online && !is_forced_offline),
    E_INTERNET_NULL_REASON_MISMATCH,
);
assert!(
    gps_null_reason_hash.is_empty() == (has_gps && !is_gps_forced_null),
    E_GPS_NULL_REASON_MISMATCH,
);
```

A reason hash present when it shouldn't be, or missing when it's required, reverts the transaction — a malformed submission can never land a capture whose reason disclosure is unverifiable. See [the offline-capture design](../granite-lake-offline-capture-design.md) for the full field-crew rationale.

---

# Move Package

Package name:

```text
granite_lake
```

Module:

```text
granite_lake::photo_attestation
```

---

# Main Objects

## OwnerCap

Owned by the contract owner.

Required for:

```move
add_domain()
set_domain_admin()
```

---

## Registry

Shared object containing all domains.

Created during package publish.

---

## UserCap

Transferred directly to approved user wallets.

Stores:

```move
domain
user_wallet
```

Required for:

```move
attest_photo()
attest_file()
```

---

# Events

## DomainAdded

Emitted when owner adds a domain.

```move
DomainAdded {
    domain,
    admin_wallet
}
```

---

## UserAdded

Emitted when admin adds a user wallet.

```move
UserAdded {
    domain,
    admin_wallet,
    user_wallet
}
```

---

## UserEnabled

Emitted when admin enables a user wallet.

---

## UserDisabled

Emitted when admin disables a user wallet.

---

## DomainAdminChanged

Emitted when the owner rotates a domain's admin wallet via `set_domain_admin`.

```move
DomainAdminChanged {
    domain,
    old_admin_wallet,
    new_admin_wallet
}
```

Gated on `OwnerCap`, not the domain's own current admin wallet — if the admin key itself is what was compromised or lost, requiring its signature to replace itself would defeat the point. Without this, a compromised or lost admin key was permanent and unrecoverable.

---

## PhotoAttested

Main photo attestation event.

```move
PhotoAttested {
    photo_hash,
    gps,
    altitude,
    project_id,
    user_wallet,
    domain,
    captured_at,
    attested_at,
    is_online,
    is_forced_offline,
    internet_null_reason_hash,
    has_gps,
    is_gps_forced_null,
    gps_null_reason_hash
}
```

This is the primary verification source for photo attestations. `domain` lets a verifier read attribution straight from the event instead of reconstructing it from whichever `UserCap` the attesting wallet currently happens to hold. `captured_at` is client-supplied (an offline-safe synced-clock fallback when no live clock was reachable at capture time); `attested_at` is derived on-chain from the shared `Clock` object, so it can't be spoofed by the client. `is_online`/`has_gps` are ground truth (untouched by the force toggles); `is_forced_offline`/`is_gps_forced_null` record whether the crew deliberately overrode a working connection or an available GPS fix. See [§3](#3-on-chain-connectivity--gps-provenance) for the null-reason-hash invariant.

---

## FileAttested

Main file attestation event.

```move
FileAttested {
    file_hash,
    user_wallet,
    file_id,
    project_id,
    domain,
    captured_at,
    attested_at,
    is_online,
    is_forced_offline,
    internet_null_reason_hash
}
```

This is the primary verification source for uploaded files. Same connectivity-provenance fields as `PhotoAttested`; file attestation never carries GPS fields since file uploads have no location data.

---

# Contract Functions

## add_domain

Owner-only.

```move
add_domain(
    domain,
    admin_wallet
)
```

Registers a new domain.

---

## set_domain_admin

Owner-only.

```move
set_domain_admin(
    registry,
    domain,
    new_admin_wallet
)
```

Rotates a domain's admin wallet. Emits `DomainAdminChanged`.

---

## add_user

Domain-admin-only.

```move
add_user(
    domain,
    user_wallet
)
```

Creates and transfers a `UserCap` directly to the user wallet.

New users are enabled by default.

---

## enable_user

Domain-admin-only.

Marks an existing user as enabled.

---

## disable_user

Domain-admin-only.

Marks an existing user as disabled.

---

## attest_photo

User-only.

```move
attest_photo(
    user_cap,
    registry,
    hash,
    gps,
    altitude,
    project_id,
    captured_at,
    is_online,
    is_forced_offline,
    internet_null_reason_hash,
    has_gps,
    is_gps_forced_null,
    gps_null_reason_hash,
    clock
)
```

Creates a photo attestation event. Reverts (`E_INTERNET_NULL_REASON_MISMATCH`/`E_GPS_NULL_REASON_MISMATCH`) if either null-reason hash doesn't match whether its field is actually null/overridden — see [§3](#3-on-chain-connectivity--gps-provenance).

---

## attest_file

User-only.

```move
attest_file(
    user_cap,
    registry,
    hash,
    file_id,
    project_id,
    captured_at,
    is_online,
    is_forced_offline,
    internet_null_reason_hash,
    clock
)
```

Creates a file attestation event. Same `internet_null_reason_hash` enforcement as `attest_photo`; no GPS fields.

---

# Why Events Matter

The verification portal and verification API both rely on event scans.

That means the contract design intentionally keeps attestations event-only rather than storing per-asset objects or maps.
