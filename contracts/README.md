# Granite Lake

Granite Lake is a lightweight Sui-based photo attestation system.

It allows:

- a contract owner to register domains
- a domain admin to authorize wallets and enable or disable them
- enabled wallets to attest photos on-chain
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
attest_photo(user_cap, registry, hash, gps, altitude, project_id)

Contract
    ↓
emit PhotoAttested event
```

---

# Core Design Principles

## 1. Event-Only Photo Attestation

Photo attestations are NOT stored in on-chain maps.

Instead:

```move
event::emit(PhotoAttested { ... })
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
```

The capability also carries the user's domain so the contract can validate the sender against the correct domain record and enforce enabled or disabled state during attestation.

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

## PhotoAttested

Main attestation event.

```move
PhotoAttested {
    photo_hash,
    gps,
    altitude,
    project_id,
    user_wallet
}
```

This is the primary verification source.

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

No OTP flow exists.

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
    project_id
)
```

Validates wallet ownership, checks the wallet is still enabled for that domain, and emits `PhotoAttested`.

No photo data is stored on-chain.

---

# Verification Model

Verification is done OFF-CHAIN through Sui events.

Verification inputs:

```text
domain
admin_wallet
```

---

# Test Coverage Note

Move unit tests are in `contracts/tests/granite_lake_tests.move` and currently cover:

- `add_domain` success and duplicate-domain failure
- `add_user` success, admin-only enforcement, and duplicate-user failure
- `enable_user` and `disable_user` flows
- disabled-user attestation rejection
- `attest_photo` caller ownership enforcement (only the `UserCap` owner)
- event assertions for `DomainAdded`, `UserAdded`, `UserEnabled`, `UserDisabled`, and `PhotoAttested`

Run tests with:

```bash
npm run test:move
```

Or from repository root:

```bash
npm run test:contracts
```
