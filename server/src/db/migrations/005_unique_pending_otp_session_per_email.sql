-- F-02: a completed on-chain capability could be minted with no matching
-- users row when two otp_sessions were opened for the same email and
-- completed concurrently. The application now rejects a second pending
-- session for an email before minting, but that check has a narrow
-- TOCTOU window under concurrent requests. Enforce it atomically instead.
--
-- This is a partial index so completed/expired sessions never conflict;
-- only one pending_verification row per email can exist at a time.
create unique index if not exists otp_sessions_pending_email_unique
  on otp_sessions (user_email)
  where status = 'pending_verification';
