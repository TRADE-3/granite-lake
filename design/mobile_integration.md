# Granite Mobile — Trade3 API Integration Guide

This guide covers the features, environment setup, user flows, and API endpoints required to integrate the **Granite** mobile app with the **Trade3** backend.

- **Trade3 Main Project Base API URL:** `https://dev-api.trade3.io`

---

## 1. Routes Overview

| ID | Method | Endpoint | Auth | Content-Type | Purpose |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **EP-01** | `POST` | `/api/auth/pairing/consume` | None | `application/json` | Exchange pairing code for `access_token` & `refresh_token` |
| **EP-02** | `POST` | `/api/auth/refresh` | None (Refresh Token in body) | `application/json` | Obtain a new `access_token` using `refresh_token` |
| **EP-03** | `GET` | `/api/granite/sync/hierarchy` | `Bearer <access_token>` | None | Fetch the user's Trade3 project tree |
| **EP-04** | `POST` | `/api/granite/pin/bonus` | `Bearer <access_token>` | `multipart/form-data` | Upload & pin 1–10 Granite-verified documents |
| **EP-05** | `POST` | `/api/auth/logout` | `Bearer <access_token>` | `application/json` | Revoke the session and unlink the mobile device |

---

## 2. Requested Features

1. **Account Pairing & Token Management (`EP-01`, `EP-02`)**
   - Add a pairing screen (and deep-link handler) where the user links Granite to their Trade3 account via a UUID pairing code.
   - Call **`EP-01`** to exchange `pairing_code` (and an optional `device_id`) for an `access_token` and `refresh_token`, then store them securely on the device.
   - Upon receiving a `401 Unauthorized` (or before making authenticated requests when expired), call **`EP-02`** with the stored `refresh_token` to obtain a fresh `access_token`.

2. **Trade3 Hierarchy Sync & Explorer (`EP-03`)**
   - Call **`EP-03`** to retrieve the user's full Trade3 workspace structure:
     `Master Contract` → `Transaction` → `Payment Schedule` → `Documents`.
   - Display existing documents under each Payment Schedule and allow users to select a target Payment Schedule when attaching single or batch photos.

3. **Document Upload — Sui + Trade3 Pinning (`EP-04`)**
   - After pushing captured photos/documents to **Sui**, upload the same files to **`EP-04`** via `multipart/form-data`.
   - The backend handles deterministic encryption, Pinata/IPFS pinning, SHA-256 hashing, and database persistence, flagging each file as Granite-verified (`is_verified_by_granite: true`).

4. **Disconnect / Unlink Account (`EP-05`)**
   - Provide a **Disconnect** button in the app that calls **`EP-05`** to invalidate the session server-side, then deletes the locally stored `access_token` and `refresh_token` from the device. Removing `refresh_token` from local storage prevents any future token refreshes, effectively unlinking the account.

---

## 3. Environment Setup & Deep-Link Flow

### Prerequisites
1. Connect to **Tailscale VPN** and select the exit node **`trade3`**.
2. Open **`https://dev.evm.trade3.io`**.
3. Go to your **Profile** and click **"Link Mobile App Granite"**.
4. Scan the **QR code** or click the pairing link depending on your device.

### Deep-Link Manager (`granite.trade3.io`)
Opening the pairing link routes through **`granite.trade3.io`**, which automatically redirects to the Granite mobile app via deep link:

```text
[https://granite.trade3.io/?code=bc35112c-4bdb-4aab-](https://granite.trade3.io/?code=bc35112c-4bdb-4aab-)*********....
```

> **⚠️ WARNING:** If the mobile app build or signing certificate changes (updating the app hash / SHA-256 fingerprint), **notify the backend team immediately** so the deep-link config files on `granite.trade3.io` can be updated with the new hash.

---

## 4. End-to-End Integration Flow

1. **Pair (`EP-01`)**: Intercept `https://granite.trade3.io/?code=<pairing_code>` (or accept manual UUID code entry directly inside the app) and send it as `pairing_code` to **`EP-01`** (`https://dev-api.trade3.io/api/auth/pairing/consume`) to retrieve and store `access_token` and `refresh_token`.
2. **Refresh (`EP-02`)**: Attach `Authorization: Bearer <access_token>` to all protected calls. If the token is expired, send `refresh_token` to **`EP-02`** (`https://dev-api.trade3.io/api/auth/refresh`) first.
3. **Sync (`EP-03`)**: Silently on app launch—and whenever the user taps **Sync** or a refresh button—call **`EP-03`** to fetch and render the user's hierarchy.
4. **Capture & Link**: When creating or selecting photos, let the user choose the target **Master Contract → Transaction → Payment Schedule**.
5. **Upload (`EP-04`)**: Once pushed to Sui, send the files to **`EP-04`** as `multipart/form-data` with the chosen `transaction_id` and `payment_schedule_id`.
6. **Disconnect (`EP-05`)**: When the user taps **Disconnect**, call **`EP-05`** and clear all locally stored tokens.

---

## 5. Endpoint Breakdown

### `EP-01` — Exchange Pairing Code
- **Endpoint:** `POST https://dev-api.trade3.io/api/auth/pairing/consume`
- **Auth:** None
- **Content-Type:** `application/json`
- **Request Body:**
  ```json
  {
    "pairing_code": "bc35112c-4bdb-4aab-9c12-3456789abcde",
    "device_id": "optional-device-identifier"
  }
  ```

| Field | Type | Required | Validation / Notes |
| :--- | :--- | :--- | :--- |
| `pairing_code` | `string` (UUID) | Yes | Valid UUID obtained from the deep-link `code` query parameter |
| `device_id` | `string` | No | Optional unique identifier for the mobile device |

- **Response (`200 OK`):**
  ```json
  {
    "message": "Appaired successfully",
    "token": "eyJhbGciOi...",
    "access_token": "eyJhbGciOi...",
    "refresh_token": "a1b2c3d4-e5f6-7890-abcd-ef1234567890"
  }
  ```
  > **Note:** `token` is deprecated and kept strictly for backward compatibility. Always read and store `access_token` and `refresh_token`.

---

### `EP-02` — Refresh Access Token
- **Endpoint:** `POST https://dev-api.trade3.io/api/auth/refresh`
- **Auth:** None (authenticated via `refresh_token` in the JSON payload)
- **Content-Type:** `application/json`
- **Request Body:**
  ```json
  {
    "refresh_token": "a1b2c3d4-e5f6-7890-abcd-ef1234567890"
  }
  ```

| Field | Type | Required | Validation / Notes |
| :--- | :--- | :--- | :--- |
| `refresh_token` | `string` (UUID) | Yes | Valid UUID refresh token issued during **`EP-01`** |

- **Response (`200 OK`):** Returns a fresh `access_token` (and updated session tokens if rotated). Call proactively before **`EP-03`**, **`EP-04`**, or **`EP-05`** when the `access_token` has expired.

---

### `EP-03` — Sync User Hierarchy
- **Endpoint:** `GET https://dev-api.trade3.io/api/granite/sync/hierarchy`
- **Auth:** `Authorization: Bearer <access_token>`
- **Content-Type:** None (`GET` request, no body required)
- **Permissions:**
  - Without `can_view_transactions`: returns `200 OK` with `master_contracts: []`.
  - Without `can_view_documents`: returns the folder tree with empty `documents: []` arrays.
- **Response (`200 OK`):**
  ```json
  {
    "message": "Hierarchy synced successfully",
    "master_contracts": [
      {
        "id": "12",
        "title": "Master Contract Title",
        "reference": "mc-slug",
        "status": "ACTIVE",
        "transactions": [
          {
            "id": "45",
            "title": "Shipment #1",
            "status": "IN_PROGRESS",
            "payment_schedules": [
              {
                "id": "101",
                "title": "Customs Clearance",
                "status": "PENDING",
                "documents": [
                  {
                    "id": "502",
                    "file_name": "bill_of_lading.pdf",
                    "document_type": "BILL_OF_LADING",
                    "status": "Pending",
                    "is_required": true
                  }
                ]
              }
            ]
          }
        ]
      }
    ]
  }
  ```

---

### `EP-04` — Upload & Pin Bonus Documents
- **Endpoint:** `POST https://dev-api.trade3.io/api/granite/pin/bonus`
- **Auth:** `Authorization: Bearer <access_token>`
- **Content-Type:** `multipart/form-data`
- **Permissions:** Requires `can_deposit_documents` and access to `transaction_id`.

| FormData Field | Type | Required | Validation / Description |
| :--- | :--- | :--- | :--- |
| `transaction_id` | `string` (numeric) | Yes | Target transaction ID (parsed to `number` server-side) |
| `payment_schedule_id` | `string` (numeric) | Yes | Target payment schedule ID (parsed to `number` server-side; must belong to `transaction_id`) |
| `documents` | `File` (repeatable) | Yes | **1 to 10 valid NFT-supported files**, all appended under the same `documents` key (single file or array accepted) |

- **Response (`200 OK`):** Returns an array of the inserted database records (`id`, `payment_schedule_id`, `document_hash`):
  ```json
  {
    "message": "Bonus documents pinned successfully",
    "documents": [
      {
        "id": 610,
        "payment_schedule_id": 101,
        "document_hash": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
      }
    ]
  }
  ```

- **Error Codes:**
  - `400 Bad Request` — Missing/invalid FormData fields, unsupported file type, or file count outside `1–10`.
  - `401 Unauthorized` — Missing or expired Bearer token (trigger **`EP-02`**).
  - `403 Forbidden` — Missing company link, `can_deposit_documents` permission, or transaction access.
  - `404 Not Found` — `payment_schedule_id` does not belong to `transaction_id`.
  - `500 Internal Server Error` — Files uploaded to IPFS, but database persistence failed.

---

### `EP-05` — Logout / Disconnect
- **Endpoint:** `POST https://dev-api.trade3.io/api/auth/logout`
- **Auth:** `Authorization: Bearer <access_token>`
- **Content-Type:** `application/json`
- **Purpose:** Invalidates the current mobile session on the Trade3 backend. After calling this route, clear `access_token` and `refresh_token` from local device storage.

---

## 6. Swagger API Reference

For full schemas and interactive testing (requires Tailscale VPN):

- **URL:** `https://izimio.github.io/swagger/`
- **Password:** `<given_later>`
