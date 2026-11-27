-- Trade3 onboarding and GL sessions (design/granite-lake-trade3-onboarding-design.md).

-- registry_domain stays null for rows created before this migration; those are
-- still derived from the email when read.
alter table users add column if not exists registry_domain text;
alter table users add column if not exists trade3_user_id bigint;
alter table users add column if not exists trade3_company_id bigint;

create unique index if not exists users_trade3_user_id_key on users(trade3_user_id);

-- Trade3 users have no OTP session.
alter table users drop constraint if exists users_user_id_fkey;

create table if not exists auth_challenges (
  nonce_hash text primary key,
  user_wallet text not null,
  expires_at timestamptz not null,
  used_at timestamptz
);

create table if not exists auth_refresh_tokens (
  token_hash text primary key,
  user_id text not null references users(user_id) on delete cascade,
  family_id text not null,
  issued_at timestamptz not null default now(),
  expires_at timestamptz not null,
  used_at timestamptz,
  revoked_at timestamptz
);

create index if not exists auth_refresh_tokens_family_idx on auth_refresh_tokens(family_id);
