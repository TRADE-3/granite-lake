-- Admin-wallet -> sponsor address-balance top-ups (POST /admin/sponsor/top-up).
-- Rows are written before the transfer executes so the daily ceiling counts
-- in-flight top-ups; `pending` rows are resolved from chain by digest.
create table if not exists sponsor_topups (
  id text primary key,
  amount_mist bigint not null check (amount_mist > 0),
  status text not null check (status in ('pending', 'executed', 'failed')),
  tx_digest text,
  gas_used bigint,
  error text,
  created_at timestamptz not null default now(),
  resolved_at timestamptz
);

create index if not exists sponsor_topups_created_idx on sponsor_topups (created_at);
