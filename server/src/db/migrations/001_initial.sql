create table if not exists otp_sessions (
  user_id text primary key,
  user_email text not null,
  user_wallet text,
  otp_hash text not null,
  status text not null check (status in ('pending_verification', 'completed', 'expired')),
  created_at timestamptz not null,
  expires_at timestamptz not null,
  verified_at timestamptz,
  tx_digest text,
  user_cap_id text,
  error text
);

create table if not exists users (
  user_id text primary key,
  user_email text not null,
  user_wallet text not null,
  status text not null check (status in ('active', 'disabled')),
  user_cap_id text not null,
  add_user_tx_digest text not null,
  disable_user_tx_digest text,
  enable_user_tx_digest text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  last_verified_at timestamptz not null,
  disabled_at timestamptz
);

create index if not exists otp_sessions_status_idx on otp_sessions(status);
create index if not exists otp_sessions_user_email_idx on otp_sessions(user_email);
create index if not exists users_status_idx on users(status);
create index if not exists users_user_email_idx on users(user_email);
