-- Add foreign keys from otp_sessions to users
-- Run after 001_initial.sql

-- First, add unique constraint on users.user_email (required for FK)
ALTER TABLE users ADD CONSTRAINT users_user_email_key UNIQUE (user_email);

-- Add FK on user_id
ALTER TABLE otp_sessions
ADD CONSTRAINT otp_sessions_user_id_fkey
FOREIGN KEY (user_id) REFERENCES users(user_id) ON DELETE CASCADE;

-- Add FK on user_email
ALTER TABLE otp_sessions
ADD CONSTRAINT otp_sessions_user_email_fkey
FOREIGN KEY (user_email) REFERENCES users(user_email) ON DELETE CASCADE;
