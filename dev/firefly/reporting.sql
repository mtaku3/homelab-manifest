-- Read-only reporting layer over the Firefly III database, for Metabase.
--
-- Run by the firefly-reporting Job with psql -v ro_password=... on every sync.
-- The schema is rebuilt from scratch each time, so it always matches this file.
--
-- The queries live in plpgsql functions rather than directly in views: Postgres
-- does not track dependencies inside plpgsql bodies, so a Firefly upgrade that
-- alters these tables is never blocked by our views (at worst the functions error
-- until this file is updated). The functions are SECURITY DEFINER, so metabase_ro
-- only needs the reporting schema and never gets access to Firefly's own tables.

\set ON_ERROR_STOP on

BEGIN;

DROP SCHEMA IF EXISTS reporting CASCADE;
CREATE SCHEMA reporting;

-- One row per journal (a split of a transaction group), with both sides resolved.
-- amount_jpy is the amount in JPY: the amount itself for JPY journals, or the
-- JPY foreign amount recorded on journals in another currency.
CREATE FUNCTION reporting.f_journals()
RETURNS TABLE (
  journal_id integer,
  group_id integer,
  date date,
  type text,
  description text,
  amount numeric,
  currency text,
  amount_jpy numeric,
  source_account text,
  source_type text,
  destination_account text,
  destination_type text,
  category text,
  budget text,
  tags text,
  firefly_url text
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  RETURN QUERY
  WITH legs AS (
    SELECT t.transaction_journal_id AS jid, t.amount AS amt, t.foreign_amount AS famt,
           c.code::text AS cur, fc.code::text AS fcur, a.name::text AS acct, at.type::text AS atype
    FROM transactions t
    JOIN accounts a ON a.id = t.account_id
    JOIN account_types at ON at.id = a.account_type_id
    JOIN transaction_currencies c ON c.id = t.transaction_currency_id
    LEFT JOIN transaction_currencies fc ON fc.id = t.foreign_currency_id
    WHERE t.deleted_at IS NULL
  )
  SELECT tj.id, tj.transaction_group_id, tj.date::date, tt.type::text, tj.description::text,
         dst.amt, dst.cur,
         CASE WHEN dst.cur = 'JPY' THEN dst.amt WHEN dst.fcur = 'JPY' THEN abs(dst.famt) END,
         src.acct, src.atype, dst.acct, dst.atype,
         (SELECT c.name::text FROM category_transaction_journal ctj
            JOIN categories c ON c.id = ctj.category_id AND c.deleted_at IS NULL
           WHERE ctj.transaction_journal_id = tj.id LIMIT 1),
         (SELECT b.name::text FROM budget_transaction_journal btj
            JOIN budgets b ON b.id = btj.budget_id AND b.deleted_at IS NULL
           WHERE btj.transaction_journal_id = tj.id LIMIT 1),
         (SELECT string_agg(tg.tag::text, ', ' ORDER BY tg.tag) FROM tag_transaction_journal ttj
            JOIN tags tg ON tg.id = ttj.tag_id AND tg.deleted_at IS NULL
           WHERE ttj.transaction_journal_id = tj.id),
         'https://firefly.mtaku3.com/transactions/show/' || tj.transaction_group_id
  FROM transaction_journals tj
  JOIN transaction_types tt ON tt.id = tj.transaction_type_id
  JOIN transaction_groups tg ON tg.id = tj.transaction_group_id AND tg.deleted_at IS NULL
  JOIN legs src ON src.jid = tj.id AND src.amt < 0
  JOIN legs dst ON dst.jid = tj.id AND dst.amt > 0
  WHERE tj.deleted_at IS NULL;
END;
$$;

-- Signed movements on asset and liability accounts, including opening balances, so
-- a running sum per account gives its balance over time.
CREATE FUNCTION reporting.f_account_movements()
RETURNS TABLE (
  journal_id integer,
  date date,
  type text,
  account text,
  account_type text,
  amount numeric,
  currency text,
  description text
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  RETURN QUERY
  SELECT tj.id, tj.date::date, tt.type::text, a.name::text, at.type::text,
         t.amount, c.code::text, tj.description::text
  FROM transactions t
  JOIN transaction_journals tj ON tj.id = t.transaction_journal_id AND tj.deleted_at IS NULL
  JOIN transaction_groups tg ON tg.id = tj.transaction_group_id AND tg.deleted_at IS NULL
  JOIN transaction_types tt ON tt.id = tj.transaction_type_id
  JOIN accounts a ON a.id = t.account_id AND a.deleted_at IS NULL
  JOIN account_types at ON at.id = a.account_type_id
  JOIN transaction_currencies c ON c.id = t.transaction_currency_id
  WHERE t.deleted_at IS NULL
    AND at.type IN ('Asset account', 'Cash account', 'Loan', 'Debt', 'Mortgage');
END;
$$;

CREATE VIEW reporting.journals AS SELECT * FROM reporting.f_journals();

-- Money spent: every withdrawal. Transfers between own accounts are not
-- spending and are left out.
CREATE VIEW reporting.spending AS
SELECT journal_id, group_id, date, date_trunc('month', date)::date AS month,
       amount_jpy, amount, currency, category, budget,
       destination_account AS payee, source_account AS account,
       tags, description, firefly_url
FROM reporting.journals
WHERE type = 'Withdrawal';

-- Money coming in. Deposits from a liability account are flagged as borrowing,
-- so dashboards can leave them out of income.
CREATE VIEW reporting.income AS
SELECT journal_id, group_id, date, date_trunc('month', date)::date AS month,
       amount_jpy, amount, currency, category,
       source_account AS payer, destination_account AS account,
       source_type IN ('Loan', 'Debt', 'Mortgage') AS is_borrowing,
       tags, description, firefly_url
FROM reporting.journals
WHERE type = 'Deposit';

CREATE VIEW reporting.account_movements AS SELECT * FROM reporting.f_account_movements();

-- Read-only login for Metabase: it can see the reporting schema and nothing else.
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'metabase_ro') THEN
    CREATE ROLE metabase_ro LOGIN;
  END IF;
END
$$;
ALTER ROLE metabase_ro WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD :'ro_password';
ALTER ROLE metabase_ro SET default_transaction_read_only = on;
ALTER ROLE metabase_ro SET search_path = reporting;
GRANT CONNECT ON DATABASE firefly TO metabase_ro;
REVOKE ALL ON SCHEMA public FROM metabase_ro;
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA reporting FROM PUBLIC;
GRANT USAGE ON SCHEMA reporting TO metabase_ro;
GRANT SELECT ON ALL TABLES IN SCHEMA reporting TO metabase_ro;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA reporting TO metabase_ro;

COMMIT;
