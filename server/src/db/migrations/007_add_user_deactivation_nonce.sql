-- Self-service deactivation (PATCH /otp/:userId/deactivate) was gated only by
-- the shared app API key plus knowing the userId. Require a signature from
-- the registered wallet over a single-use, short-lived server-issued
-- challenge, stored here until it is consumed or expires.
alter table users add column if not exists deactivate_nonce text;
alter table users add column if not exists deactivate_nonce_expires_at timestamptz;
