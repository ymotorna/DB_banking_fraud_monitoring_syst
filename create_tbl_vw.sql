-- create DATABASE banking_fraud_track;
-- DROP SCHEMA public CASCADE;
-- CREATE SCHEMA public;

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
    join customers c
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


-- transactions for last 30days
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


-- transactions w/ active fraud alerts ('open', 'under_review')
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
    where f.alert_status IN('open', 'under_review');



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
        ON c.country_code=cn.country_code
    left join customer_stats cs
        on c.customer_id=cs.customer_id
    left join accounts a
        on c.customer_id=a.customer_id
    left join transactions t
        on a.account_id=t.account_id
    left join fraud_alerts fa
        on t.transaction_id=fa.transaction_id
    group by 1,2,3,4,5,6,7,8,9,10,11,12,13;



---------------------------------------------------------------------------------------------------------------------------
-- +materialized view
---------------------------------------------------------------------------------------------------------------------------
create MATERIALIZED VIEW mv_daily_fraud_summary AS
    with top_risk_customer as (
        select t.transaction_at::date as transaction_date,
               cp.customer_id,
               cp.country_risk_score*cp.avg_risk_score as customer_risk_score,
               dense_rank() over(partition by t.transaction_at::date
                                    order by cp.country_risk_score*cp.avg_risk_score desc) as risk_rank
        from vw_customer_risk_profile cp
        right join transactions t
            on cp.account_id=t.account_id
        group by transaction_date, cp.customer_id, customer_risk_score
        order by transaction_date asc, risk_rank asc
        ),

        top_risk_json as (
        select transaction_date,
               json_agg(json_build_object(
                        'customer_id', customer_id,
                        'customer_risk_score', customer_risk_score,
                        'risk_rank', risk_rank)) as top_risky_customers
        from top_risk_customer
        where risk_rank <=3
        group by transaction_date
    ),

    daily_risk_stat as(
        select t2.transaction_at::date as transaction_date,
           count(distinct t2.transaction_id) as total_transactions,
           sum(t2.amount) as total_amount,
           count(t2.transaction_id) filter (where t2.status='flagged') as flagged_count,
           count(t2.transaction_id) filter(where t2.risk_score>5) as suspicious_transactions,
           avg(t2.risk_score) as avg_risk_score,
           count(distinct fa.alert_id) as total_fraud_alerts
        from transactions t2
        left join fraud_alerts fa
            ON t2.transaction_id = fa.transaction_id
        group by transaction_date
    )

    select drs.*,
           trj.top_risky_customers
    from daily_risk_stat drs
    left join top_risk_json trj
        on drs.transaction_date=trj.transaction_date;




-- + refresh logic
REFRESH MATERIALIZED VIEW mv_daily_fraud_summary;
-- ...






