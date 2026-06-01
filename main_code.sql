-- create DATABASE banking_fraud_track;

---------------------------------------------------------------------------------------------------------------------------
-- +tbls w/ constraints
---------------------------------------------------------------------------------------------------------------------------

-- new dim_tbl w/ countries + risk lvl
create table if not exists countries (
    country_code VARCHAR PRIMARY KEY,
    country_name VARCHAR not null,
    risk_score INTEGER not null check(risk_score BETWEEN 0 AND 10)
);

create table if not exists customers (
    customer_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    first_name VARCHAR not null,
    last_name VARCHAR not null,
    email VARCHAR not null unique,
    birth_date DATE not null,
    country_code VARCHAR not null,
    FOREIGN KEY (country_code) references countries(country_code) ON DELETE RESTRICT,
    created_at TIMESTAMP not null,
    is_active BOOLEAN not null
);

create table if not exists accounts (
    account_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id BIGINT not null,
    FOREIGN KEY (customer_id) references customers(customer_id) ON DELETE RESTRICT,
    account_number VARCHAR not null unique,
    currency VARCHAR not null check(currency IN ('UAH', 'USD', 'EUR')),
    balance DECIMAL not null check(balance >= 0),
    status VARCHAR not null check(status IN ('active', 'inactive', 'suspended', 'closed')),
    opened_at TIMESTAMP not null
);

create table if not exists cards (
    card_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    account_id BIGINT not null,
    FOREIGN KEY (account_id) references accounts(account_id) ON DELETE RESTRICT,
    card_number_hash VARCHAR not null unique,
    card_type VARCHAR not null check(card_type IN ('debit', 'credit', 'prepaid', 'virtual')),
    status VARCHAR not null check(status IN ('active', 'inactive', 'blocked', 'expired')),
    expiration_date DATE not null
);

create table if not exists transactions (
    transaction_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    account_id BIGINT not null,
    FOREIGN KEY (account_id) references accounts(account_id) ON DELETE RESTRICT,
    card_id BIGINT not null,
    FOREIGN KEY (card_id) references cards(card_id) ON DELETE RESTRICT,
    amount DECIMAL not null check(amount >= 0),
    currency VARCHAR not null check(currency IN ('UAH', 'USD', 'EUR')),
    merchant_category VARCHAR not null check(merchant_category IN ('groceries', 'restaurants', 'travel', 'accommodation', 'fuel',
                                                                    'entertainment', 'healthcare', 'education', 'utilities',
                                                                    'retail', 'electronics', 'gambling', 'crypto', 'atm', 'other')),
    merchant_country VARCHAR not null,
    FOREIGN KEY (merchant_country) references countries(country_code) ON DELETE RESTRICT,
    status VARCHAR not null check(status IN ('pending', 'approved', 'declined', 'flagged')),
    risk_score INTEGER not null check(risk_score BETWEEN 0 AND 10),
    transaction_at TIMESTAMP not null,
    created_at TIMESTAMP not null
);

create table if not exists transaction_status_history (
    history_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    transaction_id BIGINT not null,
    FOREIGN KEY (transaction_id) references transactions(transaction_id) ON DELETE RESTRICT,
    old_status VARCHAR check(old_status IN ('pending', 'approved', 'declined', 'flagged')),                   -- mb null
    new_status VARCHAR not null check(new_status IN ('pending', 'approved', 'declined', 'flagged')),
    changed_at TIMESTAMP not null,
    changed_by VARCHAR not null
);

create table if not exists fraud_rules (
    rule_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    rule_name VARCHAR not null,
    rule_type VARCHAR not null check(rule_type IN ('velocity', 'amount_limit', 'geo_block', 'merchant_block', 'unusual_pattern', 'high_overall_risk')),
    threshold_value INTEGER not null check(threshold_value>0),
    is_active BOOLEAN not null
);

-- thresholds
--  ('velocity' > 5,
--  'amount_limit'>10000,
--  'geo_block',
--  'merchant_block'
--  'unusual_pattern' > 5
--  high_overall_risk > 6))

create table if not exists fraud_alerts (
    alert_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    transaction_id BIGINT not null,
    FOREIGN KEY (transaction_id) references transactions(transaction_id) ON DELETE RESTRICT,
    rule_id BIGINT not null,
    FOREIGN KEY (rule_id) references fraud_rules(rule_id) ON DELETE RESTRICT,
    reason VARCHAR(50) not null,
    risk_score INTEGER not null check(risk_score BETWEEN 0 AND 100),
    alert_status VARCHAR not null check(alert_status IN ('open', 'under_review', 'resolved', 'dismissed')),
    created_at TIMESTAMP not null
);

create table if not exists audit_log (
    audit_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id BIGINT not null,
    FOREIGN KEY (customer_id) references customers(customer_id) ON DELETE RESTRICT,
    table_name VARCHAR not null check(table_name IN ('customers', 'accounts', 'cards', 'transactions',
                                                    'transaction_status_history', 'fraud_rules', 'fraud_alerts')),
    operation VARCHAR not null,
    old_value JSON,                   -- mb null
    new_value JSON,
    changed_at TIMESTAMP not null
);

-- +stat tbl of transactions/customer
create table if not exists customer_stats (
    customer_id BIGINT not null,
    FOREIGN KEY (customer_id) references customers(customer_id) ON DELETE RESTRICT,
    total_transactions INTEGER not null default 0,
    approved_transactions INTEGER not null default 0,
    declined_transactions INTEGER not null default 0,
    total_amount DECIMAL not null default 0,
    avg_transaction_amount DECIMAL not null default 0,
    avg_risk_score DECIMAL not null default 0,
    last_updated TIMESTAMP not null default now()
);



---------------------------------------------------------------------------------------------------------------------------
-- +views
---------------------------------------------------------------------------------------------------------------------------

-- many accounts for 1 customer  \\  combined tbls
create view vw_customer_accounts AS
    select a.account_id,
           c.customer_id,
           c.email,
           c.country_code,
           a.account_number,
           a.currency,
           a.balance,
           a.status,
           a.opened_at
    from accounts a
    left join customers c
    ON a.customer_id = c.customer_id;

-- account info + country risk  \\  => calculate_transaction_risk_score()
create view vw_account_details as
    select a.account_id,
           a.customer_id,
           a.currency,
           a.status,
           c.country_code,
           cn.risk_score as country_risk_score
    from accounts a
    join customers c
        on a.customer_id  = c.customer_id
    join countries cn
        on c.country_code = cn.country_code;


-- transactions for last 30days  \\  +- other data?
create view vw_recent_transactions AS
    select t.*,
           c.customer_id,
           c.country_code,
           cards.card_type
    from transactions t
    left join accounts a
        ON t.account_id = a.account_id
    left join customers c
        ON a.customer_id = c.customer_id
    left join cards
        on t.card_id=cards.card_id
    where transaction_at >= now() - interval '30 days';


-- transactions w/ active fraud alerts ('open', 'under_review', 'escalated')  \\ +triggered rule
create view vw_flagged_transactions as
    select f.transaction_id,
           t.account_id,
           t.amount,
           t.merchant_category,
           t.status,
           t.risk_score,
           t.transaction_at,
           t.created_at,
           f.alert_id,
           f.alert_status,
           f.reason,
           f.rule_id,
           r.rule_name,
           r.rule_type
    from fraud_alerts f
    join transactions t
        ON t.transaction_id = f.transaction_id
    join fraud_rules r
        ON f.rule_id = r.rule_id
    where f.alert_status IN('open', 'under_review', 'escalated');



-- customer info + stats + fraud alerts
create view vw_customer_risk_profile as
    select c.customer_id,
           a.account_id,
           c.first_name,
           c.last_name,
           c.email,
           c.country_code,
           cn.risk_score as country_risk_score,
           cs.total_transactions,
           cs.total_amount,
           cs.approved_transactions,
           cs.declined_transactions,
           cs.avg_transaction_amount,
           cs.avg_risk_score,
           count(fa.alert_id) as total_alerts,
           max(fa.created_at) as last_alert
    from customers c
    left join countries cn
        ON c.country_code = cn.country_code
    left join customer_stats cs
        on c.customer_id    = cs.customer_id
    left join accounts a
        on c.customer_id    = a.customer_id
    left join transactions t
        on a.account_id     = t.account_id
    left join fraud_alerts fa
        on t.transaction_id = fa.transaction_id
    group by 1,2,3,4,5,6,7,8,9,10,11,12,13;



---------------------------------------------------------------------------------------------------------------------------
-- +materialized view
---------------------------------------------------------------------------------------------------------------------------
create MATERIALIZED VIEW mv_daily_fraud_summary AS
    select t.transaction_at::date as transaction_date,
           count(distinct t.transaction_id) as total_transactions,
           sum(t.amount) as total_amount,
           count(t.transaction_id) filter (where t.status='flagged') as flagged_count,
           count(t.transaction_id) filter(where t.risk_score>5) as suspicious_transactions,
           avg(t.risk_score) as avg_risk_score,
           count(distinct fa.alert_id) as fraud_alerts,
           (select json_agg(top_risk_cust) from (
                                select cp.customer_id,
                                       cp.country_risk_score*cp.avg_risk_score as customer_risk_score
                                from vw_customer_risk_profile cp
                                join transactions t2
                                    on cp.account_id=t2.account_id
                                where t2.transaction_at=t.transaction_at
                                group by cp.customer_id
                                order by customer_risk_score desc
                                limit 5)  as top_risk_cust)
               as top_risky_customers
    from transactions t
    left join fraud_alerts fa
        ON t.transaction_id = fa.transaction_id
    group by t.transaction_at::date;

---------------------------------------------------------------------------------------------------------------------------
-- +func
---------------------------------------------------------------------------------------------------------------------------

-- Calculate customer daily transaction volume
create or replace function calculate_customer_daily_volume(
    p_customer_id BIGINT,
    p_target_date DATE)
returns DECIMAL
language plpgsql AS $$
    BEGIN
        return (
            select sum(amount) as total_volume
            from transactions t
            join accounts a
                on t.account_id = a.account_id
            where a.customer_id = p_customer_id
                and t.created_at::date = p_target_date);
    END;
    $$;



-- Check whether country is high-risk
create or replace function is_high_risk_country(p_country_code VARCHAR)
returns BOOLEAN
language plpgsql AS $$
    BEGIN
        return(
            select risk_score > 7
            from countries
            where country_code=p_country_code);
    END;
    $$;



-- Calculate transaction risk score
-- https://github.com/sumit3178/AML-Risk-Scoring-Pipeline-SQL/tree/main
-- trigger on insert new transaction BEFORE  -> count avg before this transaction -> insert in other tbls
create or replace function calculate_transaction_risk_score(p_transaction_id BIGINT)
returns INTEGER
language plpgsql AS $$
    BEGIN
        return(
            select
                case when t.amount > 10000 then 2 else 0 end +                        -- big transaction
                case when ad.country_code != t.merchant_country then 2 else 0 end +       -- country mismatch
                case when t.currency != ad.currency then 2 else 0 end +                   -- currency mismatch
                case when ad.country_risk_score>7 then 2                                 -- user country risk lvl
                    when ad.country_risk_score>4 then 1
                    else 0 end +
                case when coalesce(t.amount/nullif(cs.avg_transaction_amount,0), 0) > 5 then 2                 -- how much transaction > avg transaction (~outliers)
                    when coalesce(t.amount/nullif(cs.avg_transaction_amount,0), 0) > 2 then 1
                    else 0 end
            from transactions t
            join vw_account_details ad
                on t.account_id=ad.account_id
            join customer_stats cs
                on ad.customer_id=cs.customer_id
            where t.transaction_id=p_transaction_id);
    END;
    $$;



-- Mask card number
-- +domain for 1111 1111 1111 1111 -> 1111 **** **** 1111 formatting
create domain secure_card_number as VARCHAR
check (value ~'^\d{4}\*{8}\d{4}$');

create or replace function mask_card_number(p_card_number VARCHAR)
returns secure_card_number
language plpgsql AS $$
    BEGIN
        return concat(left(p_card_number,4), '********', right(p_card_number,4));
    END;
    $$;


-- Get customer age
create or replace function get_customer_age(p_customer_id BIGINT)
returns INTEGER
language plpgsql AS $$
    BEGIN
        return (select date_part('year', AGE(birth_date))::integer
                from customers
                where customer_id = p_customer_id);
    END;
    $$;

--



---------------------------------------------------------------------------------------------------------------------------
-- +procedures
---------------------------------------------------------------------------------------------------------------------------

-- Process transaction
create or replace procedure process_transaction(
    p_transaction_id BIGINT)
LANGUAGE plpgsql
AS $$
    DECLARE
        v_risk_score INTEGER;
        v_velocity INTEGER;
        v_transaction_amount DECIMAL;
        v_avg_transaction DECIMAL;
        v_customer_cn VARCHAR;
        v_merchant_cn VARCHAR;
        v_account_id BIGINT;
        v_rule_velocity BIGINT;
        v_rule_amount BIGINT;
        v_rule_geo BIGINT;
        v_rule_merchant BIGINT;
        v_rule_unusual BIGINT;
        v_rule_high_risk BIGINT;
        v_velocity_threshold INTEGER;
        v_amount_threshold DECIMAL;
        v_unusual_threshold INTEGER;
        v_high_risk_threshold INTEGER;
    BEGIN
        -- calc risk score
        UPDATE transactions
        set risk_score=calculate_transaction_risk_score(p_transaction_id)
        where transaction_id=p_transaction_id
        RETURNING risk_score into v_risk_score;

        -- check vals w/ thresholds in fraud_rules => call pr_create_fraud_alert on evr violation

        select amount, merchant_country, account_id
        into v_transaction_amount, v_merchant_cn, v_account_id
        from transactions
        where transaction_id=p_transaction_id;

        select cs.avg_transaction_amount, at.country_code
        into v_avg_transaction, v_customer_cn
        from customer_stats cs
        join vw_account_details at
            on cs.customer_id=at.customer_id
        join transactions t
            ON at.account_id = t.account_id
        where transaction_id=p_transaction_id;

        select count(*)
        into v_velocity
        from transactions
        where account_id=v_account_id
            and transaction_at >= now() - interval '1 hour';

        -- select all rules ids to feed into procedure +fraud_alert
        select rule_id, threshold_value into v_rule_velocity, v_velocity_threshold from fraud_rules where rule_type='velocity' and is_active=TRUE;
        select rule_id, threshold_value into v_rule_amount, v_amount_threshold from fraud_rules where rule_type='amount_limit' and is_active=TRUE;
        select rule_id into v_rule_geo from fraud_rules where rule_type='geo_block' and is_active=TRUE;
        select rule_id into v_rule_merchant from fraud_rules where rule_type='merchant_block' and is_active=TRUE;
        select rule_id, threshold_value into v_rule_unusual, v_unusual_threshold from fraud_rules where rule_type='unusual_pattern' and is_active=TRUE;
        select rule_id, threshold_value into v_rule_high_risk, v_high_risk_threshold from fraud_rules where rule_type='high_overall_risk' and is_active=TRUE;

        if v_velocity>v_velocity_threshold
                then call pr_create_fraud_alert(p_transaction_id, v_rule_velocity,
                                                    'Too many transactions during last hour were made', v_risk_score); end if;
        if v_transaction_amount>v_amount_threshold
                then call pr_create_fraud_alert(p_transaction_id, v_rule_amount,
                                                    'Transaction amount exceeds limit of 10,000', v_risk_score); end if;           -- no currency change mechanosm
        if is_high_risk_country(v_customer_cn)=TRUE
                then call pr_create_fraud_alert(p_transaction_id, v_rule_geo,
                                                    concat('Transaction from high-risk country:', v_customer_cn) , v_risk_score); end if;
        if  is_high_risk_country(v_merchant_cn)=TRUE
                then call pr_create_fraud_alert(p_transaction_id, v_rule_merchant,
                                                    concat('Transaction to high-risk merchant country:', v_merchant_cn), v_risk_score); end if;
        if coalesce(v_transaction_amount/nullif(v_avg_transaction,0), 0) > v_unusual_threshold
                then call pr_create_fraud_alert(p_transaction_id, v_rule_unusual,
                                                    'Unusually high transaction', v_risk_score); end if;
        if v_risk_score>v_high_risk_threshold
                then call pr_create_fraud_alert(p_transaction_id, v_rule_high_risk,
                                                    concat('High overall risk score:', v_risk_score), v_risk_score); end if;
    END;
$$;



-- Create fraud alert
create or replace procedure pr_create_fraud_alert(
    p_transaction_id BIGINT,
    p_rule_id BIGINT,
    p_reason VARCHAR,
    p_risk_score INTEGER)
LANGUAGE plpgsql
AS $$
    DECLARE
         v_customer_id BIGINT;
        v_alert_id BIGINT;
        v_account_id BIGINT;
        v_geo_rule_id VARCHAR;
        v_curr_alerts INTEGER;
        v_account_status VARCHAR;
    BEGIN
        -- INSERT into fraud_alerts
        INSERT INTO fraud_alerts (
            transaction_id,
              rule_id,
              reason,
              risk_score,
              alert_status,
              created_at)
        values (
               p_transaction_id,
                p_rule_id,
                p_reason,
                p_risk_score,
                'open',
               now())
        returning alert_id into v_alert_id;;

        -- UPDATE transaction status -> 'flagged'
        UPDATE transactions
        set status='flagged'
        where transaction_id=p_transaction_id;

        -- get customer_id + account_id
        select a.customer_id, a.account_id, a.status
        into v_customer_id, v_account_id, v_account_status
        from transactions t
        left join accounts a
            on a.account_id = t.account_id
        where t.transaction_id=p_transaction_id;

        -- get rule_id for geo_block rule_name => freeze account
        select rule_id
        into v_geo_rule_id
        from fraud_rules
        WHERE rule_name='geo_block';

        -- count open fraud alerts for account
        select count(*)
        into v_curr_alerts
        from fraud_alerts fa
        join transactions t2
            ON fa.transaction_id = t2.transaction_id
        where t2.account_id=v_account_id
            and fa.alert_status in('open', 'escalated');

        -- trigger freeze_account procedure if needed
        if v_account_status != 'suspended' and (   -- to avoid repetetive freeze trigger when 1 transactio has multiple fraud_alerts and account was alredy freezed
            p_risk_score = 10
               or p_rule_id=v_geo_rule_id
                or v_curr_alerts>5)
            then call pr_freeze_account(v_account_id);
        end if;
    END;
$$;


-- Freeze account
create or replace procedure pr_freeze_account(
    p_account_id BIGINT)
LANGUAGE plpgsql
AS $$
    DECLARE
         v_account_status VARCHAR;
        v_customer_id BIGINT;
        v_card_status VARCHAR;
        v_transaction_list JSON;
    BEGIN
        -- get current account status + customer_id
        select status, customer_id
        into v_account_status, v_customer_id
        from accounts
        where account_id=p_account_id;

        -- get curr card status
        select status
        into v_card_status
        from cards
        where account_id=p_account_id;

        -- UPDATE status='suspended'
        if v_account_status IN('active', 'inactive') then
            UPDATE accounts
            set status='suspended'
            where account_id=p_account_id;
        end if;

        -- UPDATE card status->'blocked'
        UPDATE cards
        set status='blocked'
        where account_id=p_account_id;

        -- UPDATE all pending transactions -> declined
        UPDATE transactions
        set status='declined'
        where account_id=p_account_id
        RETURNING transaction_id into v_transaction_list;                    -- ?

        -- INSERT in transacion history transaction_id from json v_transaction_list
--         ...


    END;
    $$;

--         -- +audit log
--         INSERT INTO audit_log (
--                                customer_id,
--                                table_name,
--                                operation,
--                                old_value,
--                                new_value,
--                                changed_at)
--         VALUES(
--                v_customer_id,
--                'cards',
--                'UPDATE',
--                json_build_object('status', v_account_status),
--                json_build_object('status', 'blocked'),
--                now()),

--                 (v_customer_id,
--                'accounts',
--                'UPDATE',
--                json_build_object('status', v_card_status),
--                json_build_object('status', 'suspended'),
--                now()),

--              (v_customer_id,
--                'transacions',
--                'UPDATE',
--                v_transaction_list,
--                json_build_object(),        -- ? how to record status change for all atransactiojns?
--                now());


-- Approve pending transactions 
create or replace procedure pr_approve_pending_transactions(
    p_transaction_id BIGINT,
    p_alert_status VARCHAR)
LANGUAGE plpgsql
AS $$
    DECLARE
        v_account_status VARCHAR;
        v_customer_id BIGINT;
        v_transaction_status VARCHAR;
    begin
        select a.status , a.customer_id, t.status
        into v_account_status, v_customer_id, v_transaction_status
        from transactions t
        join accounts a
            on a.account_id=t.account_id
        where transaction_id=p_transaction_id;

        -- if--else logic
        if v_account_status='suspended'
            then UPDATE transactions
                    set status='declined'
                    where transaction_id=p_transaction_id;
                -- +audit log
                    INSERT INTO audit_log (
                               customer_id,
                               table_name,
                               operation,
                               old_value,
                               new_value,
                               changed_at)
                    VALUES(
                           v_customer_id,
                           'transactions',
                           'UPDATE',
                           json_build_object('status', v_transaction_status),
                           json_build_object('status', 'declined'),
                           now());

                    -- UPDATE transaction status -> approved
                    UPDATE transactions
                    set status='approved'
                    where p_transaction_id=p_transaction_id;

            if v_transaction_status='pending' or (
                    v_transaction_status='flagged' and p_alert_status='resolved') then
                UPDATE transactions
                set status='approved'
                where transaction_id=p_transaction_id;

                -- trg_balance_update

            if v_transaction_status='flagged' and
                p_alert_status='dismissed' then
                UPDATE transactions
                set status='declined'
                where transaction_id=p_transaction_id;

                -- trg_customer_stat_apdate
            END IF;
    END;
    $$



-- Refresh fraud dashboard
-- refresh_fraud_dashboard()
-- procedure sgould refresh mv_daily_fraud_summary() stat  \\  triggered daily automatically (Scheduled Refresh via pg_cron)


---------------------------------------------------------------------------------------------------------------------------
-- +triggers
---------------------------------------------------------------------------------------------------------------------------

-- Balance Updates
create or replace function trg_func_transaction_update_balance()
returns TRIGGER
language plpgsql as $$
    BEGIN
        if NEW.status='approved' and old.status!='approved' then
            UPDATE accounts
            set balance = balance - new.amount
            where new.account_id=account_id;
        end if;
    END;
$$;

create trigger trg_update_balance
AFTER UPDATE of status on transactions
for each row
execute function trg_func_transaction_update_balance();



-- Transaction Status History
create or replace function trg_func_transaction_status_history()
returns TRIGGER
language plpgsql as $$
    BEGIN
        INSERT into transaction_status_history (transaction_id, old_status, new_status, changed_at, changed_by)
        values(
               new.transaction_id,
               old.status,
               new.status,
               now(),
               current_user);            -- postrgres autodetect
        return NEW;
    END;
$$;

create trigger trg_transaction_status_history
AFTER UPDATE of status on transactions
for each row
execute function trg_func_transaction_status_history();


-- update customers_stat after approving/declining transaction
create or replace function trg_func_update_customer_stat()
returns TRIGGER
language plpgsql as $$
    declare
        v_customer_id BIGINT;
        v_total_amount DECIMAL;
        v_total_transactions INTEGER;
        v_avg_risk_score DECIMAL;
    BEGIN

        -- skip all actions \\ change stat only id approved/declined status
        if new.status not in ('approved', 'declined') then
            return NEW; end if;

        -- get required vars
        select cs.customer_id, cs.total_amount, cs.total_transactions, cs.avg_risk_score
        into v_customer_id, v_total_amount, v_total_transactions, v_avg_risk_score
        from customer_stats cs
        join accounts a on cs.customer_id = a.customer_id
        where a.account_id=NEW.account_id;

        -- UPDATE stat
        if new.status='approved' then
            UPDATE customer_stats
            set  total_amount = total_amount + new.amount,
                 approved_transactions = approved_transactions+1,
                 avg_transaction_amount = (v_total_amount+new.amount) / (v_total_transactions+1)
            where customer_id=v_customer_id;

        elsif new.status='declined' then
            UPDATE customer_stats
            set  declined_transactions=declined_transactions +1
            where customer_id=v_customer_id;

        end if;

        UPDATE customer_stats
            set total_transactions=v_total_transactions+1,
                avg_risk_score = (v_avg_risk_score*v_total_transactions+new.risk_score) / (v_total_transactions+1),
                last_updated=now()
            where customer_id=v_customer_id;
    END;
$$;

create trigger trg_update_customer_stat
AFTER UPDATE of status on transactions
for each row
execute function trg_func_update_customer_stat();




-- Audit Logging
create or REPLACE function trg_func_log_audit()
returns TRIGGER
language plpgsql as $$
    DECLARE
        v_customer_id BIGINT;
    BEGIN

        if tg_op='DELETE' then
            select customer_id
            into v_customer_id
            from accounts
            where account_id=old.account_id;

        else
            select customer_id
            into v_customer_id
            from accounts
            where account_id=new.account_id;
        end if;

        INSERT INTO audit_log (customer_id, table_name, operation, old_value, new_value, changed_at)
                    VALUES(
                           v_customer_id,
                           tg_table_name,
                           tg_op,
                           to_jsonb(old),
                           to_jsonb(new),
                           now());
    END;
$$;

create trigger trg_log_audit_transactions
AFTER UPDATE or INSERT or DELETE on transactions
for each row
execute function trg_func_log_audit();

create trigger trg_log_audit_accounts
AFTER UPDATE or INSERT or DELETE on accounts
for each row
execute function trg_func_log_audit();

--         INSERT INTO audit_log (
--                                customer_id,
--                                table_name,
--                                operation,
--                                old_value,
--                                new_value,
--                                changed_at)
--         VALUES(
--                v_customer_id,
--                'fraud_alerts',
--                'INSERT',
--                null,
--                json_build_object(
--                     'alert_id', v_alert_id,
--                     'transaction_id', p_transaction_id,
--                     'rule_id', p_rule_id,
--                     'reason', p_reason,
--                     'risk_score', p_risk_score,
--                     'alert_status', 'open'),
--                now()
--               );


-- Customer Deletion Protection
-- Prevent deleting customers that still have active accounts.
--     trigger before changing account status -> 'closed'
create or replace function trg_func_delete_protection()
returns TRIGGER
language plpgsql as $$
    BEGIN
        if old.customer_id in (select customer_id from accounts where status not in('closed')) then
                RAISE EXCEPTION 'Cannot delete customer untill all accounts are closed';
        end if;
    END;
$$;

create trigger trg_delete_protection
BEFORE DELETE on customers
for each row
execute function trg_func_delete_protection();








-- ensure all func are used

-- insert row in transaction - always status='pending', risk_level=0 => after insert trigger trg_transaction_pr =>
-- update transactions
