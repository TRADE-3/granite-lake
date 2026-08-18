-- Registration accepted any wallet address string with no proof the
-- caller holds its private key - whatever address the caller supplied
-- received the on-chain capability. Add a per-session nonce for the wallet
-- to sign; completeOtpSession now verifies that signature against the
-- claimed address before minting a capability for it.
alter table otp_sessions add column if not exists wallet_nonce text;
