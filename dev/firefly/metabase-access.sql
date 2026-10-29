-- Read-only login for Metabase (dev/metabase).
--
-- Run by the firefly-metabase-access Job with psql -v ro_password=... on every sync.
-- Access is an explicit column whitelist: every grant names its columns, so columns
-- or tables added by a future Firefly upgrade stay unreadable until listed here.
-- Left out on purpose: accounts.iban, the tag location columns, and every other table
-- (users, tokens, sessions, account_meta, notes, attachments, webhooks, ...).

\set ON_ERROR_STOP on

BEGIN;

DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'metabase_ro') THEN
    CREATE ROLE metabase_ro LOGIN;
  END IF;
END
$$;
ALTER ROLE metabase_ro WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION PASSWORD :'ro_password';
ALTER ROLE metabase_ro SET default_transaction_read_only = on;
GRANT CONNECT ON DATABASE firefly TO metabase_ro;

-- Start from nothing so columns removed from this list lose their grant.
-- Revoking table privileges also revokes the column privileges on that table.
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM metabase_ro;

GRANT SELECT (id, created_at, updated_at, deleted_at, user_id, transaction_type_id, bill_id,
              transaction_currency_id, description, date, interest_date, book_date, process_date,
              "order", tag_count, encrypted, completed, transaction_group_id, user_group_id, date_tz)
  ON transaction_journals TO metabase_ro;
GRANT SELECT (id, created_at, updated_at, deleted_at, account_id, transaction_journal_id, description,
              amount, identifier, transaction_currency_id, foreign_amount, foreign_currency_id,
              reconciled, balance_before, balance_after, balance_dirty, native_amount,
              native_foreign_amount)
  ON transactions TO metabase_ro;
GRANT SELECT (id, created_at, updated_at, deleted_at, user_id, title, user_group_id)
  ON transaction_groups TO metabase_ro;
GRANT SELECT (id, created_at, updated_at, deleted_at, type)
  ON transaction_types TO metabase_ro;
GRANT SELECT (id, created_at, updated_at, deleted_at, code, name, symbol, decimal_places, enabled)
  ON transaction_currencies TO metabase_ro;
GRANT SELECT (id, created_at, updated_at, deleted_at, user_id, account_type_id, name, virtual_balance,
              active, encrypted, "order", user_group_id, native_virtual_balance)
  ON accounts TO metabase_ro;
GRANT SELECT (id, created_at, updated_at, type)
  ON account_types TO metabase_ro;
GRANT SELECT (id, created_at, updated_at, deleted_at, user_id, name, encrypted, user_group_id, color)
  ON categories TO metabase_ro;
GRANT SELECT (id, category_id, transaction_journal_id)
  ON category_transaction_journal TO metabase_ro;
GRANT SELECT (id, created_at, updated_at, deleted_at, user_id, name, active, encrypted, "order",
              user_group_id)
  ON budgets TO metabase_ro;
GRANT SELECT (id, budget_id, transaction_journal_id, budget_limit_id)
  ON budget_transaction_journal TO metabase_ro;
GRANT SELECT (id, created_at, updated_at, deleted_at, user_id, tag, tag_mode, date, description,
              user_group_id, date_tz)
  ON tags TO metabase_ro;
GRANT SELECT (id, tag_id, transaction_journal_id)
  ON tag_transaction_journal TO metabase_ro;

COMMIT;
