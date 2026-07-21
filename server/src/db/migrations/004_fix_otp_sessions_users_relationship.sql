-- Fix backwards foreign keys added in 002/003.
--
-- otp_sessions is the pending/originating record: a new otp_sessions row is
-- created on every /otp/request, before any users row exists. A users row is
-- only created later, during /otp/verify, using that same otp_sessions row's
-- user_id. The FKs added in 002/003 required a matching users row to already
-- exist before otp_sessions could be inserted, which made every first-time
-- OTP request fail with a foreign key violation.

ALTER TABLE otp_sessions DROP CONSTRAINT IF EXISTS otp_sessions_user_id_fkey;
ALTER TABLE otp_sessions DROP CONSTRAINT IF EXISTS otp_sessions_user_email_fkey;
ALTER TABLE otp_sessions DROP CONSTRAINT IF EXISTS otp_sessions_user_wallet_fkey;

-- otp_sessions.user_id is already unique (primary key), and always exists
-- before the corresponding users row is created, so this direction is safe.
-- user_email/user_wallet are not reversed: otp_sessions.user_email is not
-- unique (a user can have multiple pending/expired sessions for the same
-- email before ever completing one), so it can't be a FK target.
ALTER TABLE users
ADD CONSTRAINT users_user_id_fkey
FOREIGN KEY (user_id) REFERENCES otp_sessions(user_id) ON DELETE CASCADE;
