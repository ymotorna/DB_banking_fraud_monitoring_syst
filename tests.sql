-- =============================================================
-- TESTS — Banking Fraud Monitoring System
-- Run after schema + seed_data.sql
-- Read output for PASS / FAIL lines
-- =============================================================


-- FUNCTIONS -------------------------------------------------------

-- mask_card_number()
SELECT mask_card_number('1234567890123456') = '1234********3456' AS "F1: mask_card_number";

-- is_high_risk_country()
SELECT is_high_risk_country('NG') = TRUE  AS "F2: high-risk country NG";
SELECT is_high_risk_country('DE') = FALSE AS "F3: safe country DE";

-- get_customer_age()
SELECT get_customer_age(1) BETWEEN 1 AND 150 AS "F4: customer age is realistic";

-- calculate_customer_daily_volume() — no transactions on ancient date
SELECT coalesce(calculate_customer_daily_volume(1, '2000-01-01'), 0) = 0 AS "F5: daily volume 0 on empty day";


-- TRIGGERS -------------------------------------------------------

-- insert clean low-risk transaction (Sophie DE→DE) → should auto-approve
INSERT INTO transactions (account_id, card_id, amount, currency, merchant_category, merchant_country, status, risk_score, transaction_at, created_at)
VALUES (5, 5, 50.00, 'EUR', 'groceries', 'DE', 'pending', 0, now(), now());

SELECT status = 'approved' AS "T1: clean tx auto-approved"
FROM transactions ORDER BY transaction_id DESC LIMIT 1;

SELECT count(*) = 0 AS "T2: clean tx has no fraud alerts"
FROM fraud_alerts WHERE transaction_id = (SELECT max(transaction_id) FROM transactions);


-- insert large amount transaction (James, $25 000) → should flag + amount_limit alert
INSERT INTO transactions (account_id, card_id, amount, currency, merchant_category, merchant_country, status, risk_score, transaction_at, created_at)
VALUES (2, 2, 25000.00, 'USD', 'electronics', 'US', 'pending', 0, now(), now());

SELECT status = 'flagged' AS "T3: large amount tx flagged"
FROM transactions ORDER BY transaction_id DESC LIMIT 1;

SELECT count(*) >= 1 AS "T4: amount_limit alert created"
FROM fraud_alerts fa
JOIN fraud_rules r ON fa.rule_id = r.rule_id
WHERE fa.transaction_id = (SELECT max(transaction_id) FROM transactions)
  AND r.rule_type = 'amount_limit';


-- insert tx from high-risk country (Amara, NG) → geo_block alert
INSERT INTO transactions (account_id, card_id, amount, currency, merchant_category, merchant_country, status, risk_score, transaction_at, created_at)
VALUES (4, 4, 500.00, 'USD', 'atm', 'NG', 'pending', 0, now(), now());

SELECT count(*) >= 1 AS "T5: geo_block alert for NG customer"
FROM fraud_alerts fa
JOIN fraud_rules r ON fa.rule_id = r.rule_id
WHERE fa.transaction_id = (SELECT max(transaction_id) FROM transactions)
  AND r.rule_type = 'geo_block';


-- insert tx to high-risk merchant country (Sophie → IR) → merchant_block alert
INSERT INTO transactions (account_id, card_id, amount, currency, merchant_category, merchant_country, status, risk_score, transaction_at, created_at)
VALUES (5, 5, 200.00, 'EUR', 'other', 'IR', 'pending', 0, now(), now());

SELECT count(*) >= 1 AS "T6: merchant_block alert for IR merchant"
FROM fraud_alerts fa
JOIN fraud_rules r ON fa.rule_id = r.rule_id
WHERE fa.transaction_id = (SELECT max(transaction_id) FROM transactions)
  AND r.rule_type = 'merchant_block';


-- status history logged after processing
INSERT INTO transactions (account_id, card_id, amount, currency, merchant_category, merchant_country, status, risk_score, transaction_at, created_at)
VALUES (5, 5, 40.00, 'EUR', 'groceries', 'DE', 'pending', 0, now(), now());

SELECT count(*) >= 1 AS "T7: status change logged in history"
FROM transaction_status_history
WHERE transaction_id = (SELECT max(transaction_id) FROM transactions);


-- balance decreases after approval
SELECT balance INTO TEMPORARY tmp_bal FROM accounts WHERE account_id = 5;

INSERT INTO transactions (account_id, card_id, amount, currency, merchant_category, merchant_country, status, risk_score, transaction_at, created_at)
VALUES (5, 5, 100.00, 'EUR', 'groceries', 'DE', 'pending', 0, now(), now());

SELECT (SELECT balance FROM accounts WHERE account_id = 5) < (SELECT balance FROM tmp_bal) AS "T8: balance reduced after approval";

DROP TABLE tmp_bal;


-- PROCEDURES -------------------------------------------------------

-- pr_freeze_account(): suspends account + blocks card
CALL pr_freeze_account(1);

SELECT status = 'suspended' AS "P1: account suspended by freeze"
FROM accounts WHERE account_id = 1;

SELECT status = 'blocked' AS "P2: card blocked by freeze"
FROM cards WHERE account_id = 1;

-- restore account 1 for any further tests
UPDATE accounts SET status = 'active' WHERE account_id = 1;
UPDATE cards    SET status = 'active' WHERE account_id = 1;


-- pr_create_fraud_alert(): inserts alert + flags tx
INSERT INTO transactions (account_id, card_id, amount, currency, merchant_category, merchant_country, status, risk_score, transaction_at, created_at)
VALUES (5, 5, 60.00, 'EUR', 'groceries', 'DE', 'pending', 0, now(), now());

CALL pr_create_fraud_alert(
    (SELECT max(transaction_id) FROM transactions),
    (SELECT rule_id FROM fraud_rules WHERE rule_type = 'amount_limit'),
    'test alert', 5);

SELECT status = 'flagged' AS "P3: pr_create_fraud_alert flags the tx"
FROM transactions ORDER BY transaction_id DESC LIMIT 1;

SELECT count(*) >= 1 AS "P4: pr_create_fraud_alert inserts alert row"
FROM fraud_alerts WHERE transaction_id = (SELECT max(transaction_id) FROM transactions);


-- resolving alert → tx approved
UPDATE fraud_alerts SET alert_status = 'resolved'
WHERE transaction_id = (SELECT max(transaction_id) FROM transactions);

SELECT status = 'approved' AS "P5: resolving alert approves tx"
FROM transactions ORDER BY transaction_id DESC LIMIT 1;


-- dismissing alert → tx declined
INSERT INTO transactions (account_id, card_id, amount, currency, merchant_category, merchant_country, status, risk_score, transaction_at, created_at)
VALUES (5, 5, 55.00, 'EUR', 'groceries', 'DE', 'pending', 0, now(), now());

CALL pr_create_fraud_alert(
    (SELECT max(transaction_id) FROM transactions),
    (SELECT rule_id FROM fraud_rules WHERE rule_type = 'amount_limit'),
    'test dismiss', 5);

UPDATE fraud_alerts SET alert_status = 'dismissed'
WHERE transaction_id = (SELECT max(transaction_id) FROM transactions);

SELECT status = 'declined' AS "P6: dismissing alert declines tx"
FROM transactions ORDER BY transaction_id DESC LIMIT 1;
