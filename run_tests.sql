-- FUNCTIONS -------------------------------------------------------

-- mask_card_number()
SELECT mask_card_number('1234567890123456');

-- is_high_risk_country()
SELECT is_high_risk_country('NG');  -- risk = 9 - high
SELECT is_high_risk_country('DE');   -- risk =1 - low;

-- get_customer_age()
select * from customers where customer_id=1;
SELECT get_customer_age(1);   -- must be 36 y.o.

-- calculate_customer_daily_volume() — no transactions on ancient date
select * from transactions where account_id=5;
SELECT coalesce(calculate_customer_daily_volume(5, '2026-06-01'), 0);  -- must be 900 + 120 = 1020


-- TRIGGERS -------------------------------------------------------

-- insert clean low-risk transaction (Sophie DE→DE) → should auto-approve
select * from transactions where account_id=5;
INSERT INTO transactions (account_id, card_id, amount, currency, merchant_category, merchant_country, status, risk_score, transaction_at, created_at)
VALUES (5, 5, 50.00, 'EUR', 'groceries', 'DE', 'pending', 0, now(), now());


-- insert large amount transaction (James, $25 000) → should flag + amount_limit alert
select * from transactions where account_id=2;
select * from fraud_alerts;
INSERT INTO transactions (account_id, card_id, amount, currency, merchant_category, merchant_country, status, risk_score, transaction_at, created_at)
VALUES (2, 2, 25000.00, 'USD', 'electronics', 'US', 'pending', 0, now(), now());



-- insert tx from high-risk country (Amara, NG) → geo_block + merchant_block alert
select c.customer_id, c.country_code, a.account_id
from customers c
right join accounts a
on c.customer_id=a.customer_id
where a.account_id=4;
select * from transactions where account_id=4;
select * from fraud_alerts;
-- must +2 alerts
INSERT INTO transactions (account_id, card_id, amount, currency, merchant_category, merchant_country, status, risk_score, transaction_at, created_at)
VALUES (4, 4, 500.00, 'USD', 'atm', 'NG', 'pending', 0, now(), now());



-- status history logged after processing  \\  look at tx in prev insert: pending -> flagged -> declined
select * from transaction_status_history order by transaction_id desc, changed_at asc;



-- balance decreases after approval
select balance from accounts where account_id=5;

INSERT INTO transactions (account_id, card_id, amount, currency, merchant_category, merchant_country, status, risk_score, transaction_at, created_at)
VALUES (5, 5, 100.00, 'EUR', 'groceries', 'DE', 'pending', 0, now(), now());

select balance from accounts where account_id=5; -- must decrease balance by 100



-- PROCEDURES -------------------------------------------------------

-- pr_freeze_account(): suspends account + blocks card
-- INSERT INTO transactions (account_id, card_id, amount, currency, merchant_category, merchant_country, status, risk_score, transaction_at, created_at)
-- VALUES (5, 5, 10050.00, 'EUR', 'groceries', 'DE', 'pending', 0, now(), now());
--
-- SELECT status = 'suspended' AS "P1: account suspended by freeze"
-- FROM accounts WHERE account_id = 1;
--
-- SELECT status = 'blocked' AS "P2: card blocked by freeze"
-- FROM cards WHERE account_id = 1;
--
-- -- restore account 1 for any further tests
-- UPDATE accounts SET status = 'active' WHERE account_id = 1;
-- UPDATE cards    SET status = 'active' WHERE account_id = 1;

-- for this procedure, create test that will check if the inserted transaction will cause pd_freeze_account when the conditions in process_transaction met





-- resolving alert → tx approved
select * from fraud_alerts order by transaction_id desc, created_at asc;
UPDATE fraud_alerts SET alert_status = 'resolved'
WHERE transaction_id = (SELECT max(transaction_id) FROM transactions);

SELECT * FROM transactions ORDER BY transaction_id DESC, transaction_at asc; -- must change prev transaction -> approved


-- dismissing alert → tx declined
select * from transactions order by transaction_at desc limit 5;
INSERT INTO transactions (account_id, card_id, amount, currency, merchant_category, merchant_country, status, risk_score, transaction_at, created_at)
VALUES (5, 5, 10055.00, 'EUR', 'groceries', 'DE', 'pending', 0, now(), now());

select * from fraud_alerts where transaction_id=21;

UPDATE fraud_alerts SET alert_status = 'dismissed'
WHERE transaction_id = (SELECT max(transaction_id) FROM transactions);

select * from fraud_alerts where transaction_id=21;   -- change alert status -> dismissed =>
select * from transactions order by transaction_at desc limit 5;  -- change tx stattus -> declined

select * from transaction_status_history order by transaction_id desc, changed_at asc;



-- audit logs
select * from audit_log order by changed_at asc;



