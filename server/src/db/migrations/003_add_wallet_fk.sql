-- Add foreign key for wallet_address
-- Run after 002_add_otp_sessions_fk.sql

-- First, add unique constraint on users.user_wallet (required for FK)
ALTER TABLE users ADD CONSTRAINT users_user_wallet_key UNIQUE (user_wallet);

-- Add FK on user_wallet
ALTER TABLE otp_sessions
ADD CONSTRAINT otp_sessions_user_wallet_fkey
FOREIGN KEY (user_wallet) REFERENCES users(user_wallet) ON DELETE CASCADE;
