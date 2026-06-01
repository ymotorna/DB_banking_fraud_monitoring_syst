-- =============================================================
-- SEED DATA — Banking Fraud Monitoring System
-- =============================================================

-- -------------------------------------------------------------
-- 1. COUNTRIES  (risk_score 0-10)
-- -------------------------------------------------------------
INSERT INTO countries (country_code, country_name, risk_score) VALUES
    ('UA', 'Ukraine',        3),
    ('US', 'United States',  2),
    ('DE', 'Germany',        1),
    ('NG', 'Nigeria',        9),   -- high-risk  (>7) → geo_block triggers
    ('IR', 'Iran',           10),  -- high-risk  (>7) → geo_block triggers
    ('PL', 'Poland',         2),
    ('RO', 'Romania',        5);


-- -------------------------------------------------------------
-- 2. CUSTOMERS
-- -------------------------------------------------------------
INSERT INTO customers (first_name, last_name, email, birth_date, country_code, created_at, is_active) VALUES
    ('Olena',  'Kovalenko', 'olena.kovalenko@email.com', '1990-03-15', 'UA', '2023-01-10 09:00:00', TRUE),   -- customer_id 1  normal
    ('James',  'Carter',    'james.carter@email.com',    '1985-07-22', 'US', '2023-02-14 11:30:00', TRUE),   -- customer_id 2  high-volume
    ('Dmytro', 'Petrenko',  'dmytro.petrenko@email.com', '1992-11-05', 'UA', '2023-03-01 08:00:00', TRUE),   -- customer_id 3  suspicious
    ('Amara',  'Okafor',    'amara.okafor@email.com',    '1988-05-30', 'NG', '2023-04-20 14:00:00', TRUE),   -- customer_id 4  high-risk country
    ('Sophie', 'Müller',    'sophie.mueller@email.com',  '1995-09-12', 'DE', '2023-05-05 10:00:00', TRUE);   -- customer_id 5  low-risk / clean


-- -------------------------------------------------------------
-- 3. ACCOUNTS
-- -------------------------------------------------------------
INSERT INTO accounts (customer_id, account_number, currency, balance, status, opened_at) VALUES
    (1, 'UA-001-0000001', 'UAH', 45000.00,  'active',    '2023-01-10 09:05:00'),  -- account_id 1
    (2, 'US-001-0000002', 'USD', 120000.00, 'active',    '2023-02-14 11:35:00'),  -- account_id 2
    (3, 'UA-001-0000003', 'UAH', 8000.00,   'active',    '2023-03-01 08:10:00'),  -- account_id 3  (low balance → unusual_pattern easy to trigger)
    (4, 'NG-001-0000004', 'USD', 30000.00,  'active',    '2023-04-20 14:05:00'),  -- account_id 4  high-risk country customer
    (5, 'DE-001-0000005', 'EUR', 75000.00,  'active',    '2023-05-05 10:05:00'),  -- account_id 5  clean customer
    (3, 'UA-002-0000006', 'USD', 5000.00,   'suspended', '2023-06-01 12:00:00');  -- account_id 6  already suspended (Dmytro second account)


-- -------------------------------------------------------------
-- 4. CARDS
-- -------------------------------------------------------------
INSERT INTO cards (account_id, card_number_hash, card_type, status, expiration_date) VALUES
    (1, 'hash_card_001', 'debit',   'active',  '2027-01-31'),  -- card_id 1
    (2, 'hash_card_002', 'credit',  'active',  '2026-09-30'),  -- card_id 2
    (3, 'hash_card_003', 'debit',   'active',  '2026-12-31'),  -- card_id 3
    (4, 'hash_card_004', 'prepaid', 'active',  '2025-06-30'),  -- card_id 4
    (5, 'hash_card_005', 'virtual', 'active',  '2027-03-31'),  -- card_id 5
    (6, 'hash_card_006', 'debit',   'blocked', '2026-08-31');  -- card_id 6  blocked (matches suspended account)


-- -------------------------------------------------------------
-- 5. FRAUD RULES
-- Note: threshold_value is INTEGER per schema.
--       geo_block / merchant_block have no numeric threshold in
--       business logic, so we store 1 as a placeholder.
-- -------------------------------------------------------------
INSERT INTO fraud_rules (rule_name, rule_type, threshold_value, is_active) VALUES
    ('velocity',          'velocity',        5,     TRUE),   -- rule_id 1  >5 tx/hour
    ('amount_limit',      'amount_limit',    10000, TRUE),   -- rule_id 2  >10 000
    ('geo_block',         'geo_block',       1,     TRUE),   -- rule_id 3  country risk_score >7
    ('merchant_block',    'merchant_block',  1,     TRUE),   -- rule_id 4  merchant country risk_score >7
    ('unusual_pattern',   'unusual_pattern', 5,     TRUE),   -- rule_id 5  amount > 5× avg_transaction
    ('high_overall_risk', 'high_overall_risk', 6,   TRUE);   -- rule_id 6  risk_score >6


-- -------------------------------------------------------------
-- 6. CUSTOMER STATS  (baseline before any transactions below)
-- -------------------------------------------------------------
INSERT INTO customer_stats (customer_id, total_transactions, approved_transactions, declined_transactions,
                             total_amount, avg_transaction_amount, avg_risk_score, last_updated) VALUES
    (1, 20, 18, 2,  85000.00, 4250.00, 2.1, now()),   -- Olena   — normal history
    (2, 50, 47, 3, 320000.00, 6400.00, 1.8, now()),   -- James   — high-volume, clean
    (3,  8,  5, 3,   9600.00, 1200.00, 3.5, now()),   -- Dmytro  — low avg → unusual_pattern easy to fire
    (4, 15, 10, 5,  45000.00, 3000.00, 5.2, now()),   -- Amara   — already some risk
    (5, 30, 30, 0, 210000.00, 7000.00, 1.2, now());   -- Sophie  — perfectly clean


-- -------------------------------------------------------------
-- 7. TRANSACTIONS
-- All inserted with status='pending', risk_score=0 — the
-- trg_process_transaction trigger fires pd_process_transaction()
-- which updates both fields automatically.
--
-- Scenarios covered:
--   T1  — normal, low-risk                     (Olena,  UA→UA)
--   T2  — amount_limit breach                  (James,  USD 15 000)
--   T3  — unusual_pattern  (amount >> avg)     (Dmytro, 8 000 vs avg 1 200)
--   T4  — geo_block  (customer in NG >7)       (Amara)
--   T5  — merchant_block  (merchant in IR >7)  (Sophie → IR merchant)
--   T6  — clean, reference                     (Sophie, DE→DE)
--   T7–T12 — velocity burst  (6 tx in 1 hour)  (Dmytro, account_id 3)
-- -------------------------------------------------------------

-- T1  Normal transaction — Olena (UA→UA, groceries, small amount)
INSERT INTO transactions (account_id, card_id, amount, currency, merchant_category,
                           merchant_country, status, risk_score, transaction_at, created_at)
VALUES (1, 1, 350.00, 'UAH', 'groceries', 'UA', 'pending', 0, now() - interval '2 days', now() - interval '2 days');

-- T2  Amount-limit breach — James (USD 15 000 > 10 000 threshold)
INSERT INTO transactions (account_id, card_id, amount, currency, merchant_category,
                           merchant_country, status, risk_score, transaction_at, created_at)
VALUES (2, 2, 15000.00, 'USD', 'electronics', 'US', 'pending', 0, now() - interval '1 day', now() - interval '1 day');

-- T3  Unusual pattern — Dmytro (8 000 UAH vs avg 1 200 → ratio ≈ 6.7 > 5)
INSERT INTO transactions (account_id, card_id, amount, currency, merchant_category,
                           merchant_country, status, risk_score, transaction_at, created_at)
VALUES (3, 3, 8000.00, 'UAH', 'retail', 'UA', 'pending', 0, now() - interval '3 hours', now() - interval '3 hours');

-- T4  Geo-block — Amara (customer country NG, risk_score 9 > 7)
INSERT INTO transactions (account_id, card_id, amount, currency, merchant_category,
                           merchant_country, status, risk_score, transaction_at, created_at)
VALUES (4, 4, 2500.00, 'USD', 'atm', 'NG', 'pending', 0, now() - interval '6 hours', now() - interval '6 hours');

-- T5  Merchant-block — Sophie (merchant in IR, risk_score 10 > 7)
INSERT INTO transactions (account_id, card_id, amount, currency, merchant_category,
                           merchant_country, status, risk_score, transaction_at, created_at)
VALUES (5, 5, 900.00, 'EUR', 'other', 'IR', 'pending', 0, now() - interval '5 hours', now() - interval '5 hours');

-- T6  Clean reference — Sophie (DE→DE, normal amount)
INSERT INTO transactions (account_id, card_id, amount, currency, merchant_category,
                           merchant_country, status, risk_score, transaction_at, created_at)
VALUES (5, 5, 120.00, 'EUR', 'restaurants', 'DE', 'pending', 0, now() - interval '4 hours', now() - interval '4 hours');

-- T7–T12  Velocity burst — Dmytro, 6 transactions within the last hour
--         After the 6th insert the velocity rule (>5) fires.
INSERT INTO transactions (account_id, card_id, amount, currency, merchant_category,
                           merchant_country, status, risk_score, transaction_at, created_at)
VALUES (3, 3, 200.00, 'UAH', 'fuel',           'UA', 'pending', 0, now() - interval '55 minutes', now() - interval '55 minutes');

INSERT INTO transactions (account_id, card_id, amount, currency, merchant_category,
                           merchant_country, status, risk_score, transaction_at, created_at)
VALUES (3, 3, 150.00, 'UAH', 'groceries',      'UA', 'pending', 0, now() - interval '48 minutes', now() - interval '48 minutes');

INSERT INTO transactions (account_id, card_id, amount, currency, merchant_category,
                           merchant_country, status, risk_score, transaction_at, created_at)
VALUES (3, 3, 300.00, 'UAH', 'restaurants',    'UA', 'pending', 0, now() - interval '40 minutes', now() - interval '40 minutes');

INSERT INTO transactions (account_id, card_id, amount, currency, merchant_category,
                           merchant_country, status, risk_score, transaction_at, created_at)
VALUES (3, 3, 180.00, 'UAH', 'entertainment',  'UA', 'pending', 0, now() - interval '30 minutes', now() - interval '30 minutes');

INSERT INTO transactions (account_id, card_id, amount, currency, merchant_category,
                           merchant_country, status, risk_score, transaction_at, created_at)
VALUES (3, 3, 220.00, 'UAH', 'utilities',      'UA', 'pending', 0, now() - interval '15 minutes', now() - interval '15 minutes');

-- 6th tx — velocity threshold breached (>5 in 1 hour)
INSERT INTO transactions (account_id, card_id, amount, currency, merchant_category,
                           merchant_country, status, risk_score, transaction_at, created_at)
VALUES (3, 3, 190.00, 'UAH', 'atm',            'UA', 'pending', 0, now() - interval '5 minutes',  now() - interval '5 minutes');


-- =============================================================
-- NOTE
-- After each INSERT above the trigger trg_process_transaction
-- fires pd_process_transaction(), which will:
--   • recalculate risk_score
--   • check every fraud rule and call pr_create_fraud_alert() for violations
--   • set status = 'approved' if no alerts were created
--   • set status = 'flagged'  if any alert was created
--   • potentially call pr_freeze_account() for severe violations
-- =============================================================
