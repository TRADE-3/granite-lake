-- Ledger of attestation transactions the domain's sponsor wallet has signed
-- gas for (POST /sponsor/submit). Daily spend caps are computed from this
-- table, so they survive restarts. Deliberately stores no attestation content
-- (hashes, GPS, project ids, transaction bytes).
create table if not exists sponsor_transactions (
  tx_digest text primary key,
  user_id text not null references users(user_id),
  kind text not null check (kind in ('photo', 'file')),
  status text not null check (status in ('signed', 'executed', 'failed', 'dropped')),
  gas_budget bigint not null,
  gas_used bigint,
  max_epoch bigint not null,
  error text,
  created_at timestamptz not null default now(),
  resolved_at timestamptz
);

create index if not exists sponsor_transactions_user_created_idx on sponsor_transactions (user_id, created_at);
create index if not exists sponsor_transactions_status_created_idx on sponsor_transactions (status, created_at);

-- Sponsorship pause flag set by the unexpected-spend check. It lives in the
-- database so a pause survives a restart and is only lifted deliberately.
create table if not exists sponsor_state (
  id boolean primary key default true check (id),
  paused boolean not null default false,
  paused_reason text,
  paused_at timestamptz
);

insert into sponsor_state (id) values (true) on conflict (id) do nothing;
