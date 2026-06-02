
---------------------------------------------------------------------------------------------------------------------------
-- +func
---------------------------------------------------------------------------------------------------------------------------

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
                and t.created_at::date = p_target_date
                and t.status='approved');
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






---------------------------------------------------------------------------------------------------------------------------
-- +procedures
---------------------------------------------------------------------------------------------------------------------------

-- Process transaction
create or replace procedure pd_process_transaction(p_transaction_id BIGINT)
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
        v_open_alerts INTEGER;
    BEGIN
        -- calc risk score
        v_risk_score = calculate_transaction_risk_score(p_transaction_id);

        if v_risk_score>0 then  -- to avoid UPDATE when nth to update
            UPDATE transactions
            set risk_score=v_risk_score
            where transaction_id=p_transaction_id;
        end if;

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

        -- if no fraud_alert created => approve transaction
        select count(*)
        into v_open_alerts
        from fraud_alerts
        where transaction_id=p_transaction_id AND
              alert_status in('open', 'under_review');

        if v_open_alerts=0 then
            UPDATE transactions
            set status='approved'
            where transaction_id=p_transaction_id;
        END IF;

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
        v_geo_rule_id BIGINT;
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
        returning alert_id into v_alert_id;

        -- UPDATE transaction status -> 'flagged'
        UPDATE transactions
        set status='flagged'
        where transaction_id=p_transaction_id;

        -- get customer_id + account_id
        select a.customer_id, a.account_id, a.status
        into v_customer_id, v_account_id, v_account_status
        from transactions t
        join accounts a
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
    BEGIN
        -- get current account status + customer_id
        select status, customer_id
        into v_account_status, v_customer_id
        from accounts
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
            and status in('pending', 'flagged');

    END;
    $$;




-- Approve/decline pending/flagged transactions
create or replace procedure pr_approve_flagged_transactions(p_transaction_id BIGINT)
LANGUAGE plpgsql
AS $$
    DECLARE
        v_open_alerts INTEGER;
        v_dismissed INTEGER;
    begin

        -- check if there otehr non-resolved alerts for transaction
        select count(*)
        into v_open_alerts
        from fraud_alerts
        where transaction_id=p_transaction_id AND
              alert_status in('open', 'under_review');

        -- have open alerts => do nothing
        if v_open_alerts>0 then return;

        else
            -- count dismissed alert_status \\ if >0 => decline transaction, else approve
            select count(*)
            into v_dismissed
            from fraud_alerts
            where transaction_id=p_transaction_id and
                  alert_status='dismissed';

            if v_dismissed>0 then
                UPDATE transactions
                set status='declined'
                where transaction_id=p_transaction_id;

            else
                UPDATE transactions
                set status='approved'
                where transaction_id=p_transaction_id;

            END IF;
        END IF;
    END;
$$;



---------------------------------------------------------------------------------------------------------------------------
-- +triggers
---------------------------------------------------------------------------------------------------------------------------

-- start transaction processing
create or replace function trg_func_process_transaction()
returns TRIGGER
LANGUAGE plpgsql
as $$
    BEGIN
        call pd_process_transaction(new.transaction_id);
        return new;
    END;
$$;

create trigger trg_process_transaction
AFTER INSERT on transactions
for each row
execute function trg_func_process_transaction();




-- UPDATEd fraud_alert status
create or replace function trg_func_close_transaction()
returns TRIGGER
LANGUAGE plpgsql
as $$
    BEGIN
        if new.alert_status in('resolved', 'dismissed')
            and old.alert_status not in('resolved', 'dismissed') then
            call pr_approve_flagged_transactions(new.transaction_id);
        END IF;
        return new;
    END;
$$;

create trigger trg_close_transaction
AFTER UPDATE of alert_status on fraud_alerts
for each row
execute function trg_func_close_transaction();




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
        return NEW;
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
    return NEW;
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
    if tg_op = 'DELETE' then
        return OLD;
    else
        return NEW;
    end if;
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




-- Customer Deletion Protection
create or replace function trg_func_delete_protection()
returns TRIGGER
language plpgsql as $$
    BEGIN
        if old.customer_id in (select customer_id from accounts where status not in('closed')) then
                RAISE EXCEPTION 'Cannot delete customer untill all accounts are closed';
        end if;
        return OLD;
    END;
$$;

create trigger trg_delete_protection
BEFORE DELETE on customers
for each row
execute function trg_func_delete_protection();









--         -- +audit log freeze_acc
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
--
--                 (v_customer_id,
--                'accounts',
--                'UPDATE',
--                json_build_object('status', v_card_status),
--                json_build_object('status', 'suspended'),
--                now()),
--
--              (v_customer_id,
--                'transacions',
--                'UPDATE',
--                v_transaction_list,
--                json_build_object(),        -- ? how to record status change for all atransactiojns?
--                now());



    -- ---------------------------------------
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





