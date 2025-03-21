/*
DROP EXTENSION pgtap;

CREATE EXTENSION pgtap schema tap;
*/

create schema if not exists tap;
create schema if not exists pgconf;
create schema if not exists tests;

set search_path to public, tap, pgconf;
set track_functions = 'all'	;

drop function if exists pgconf.get_osv_slice(int, int, int);
drop function if exists pgconf.get_tree_of(int);
drop function if exists pgconf.time_machine_now();
drop procedure if exists pgconf.make_osv_report();
drop procedure if exists tests.create_test_data();
drop function if exists tests.test_osv_on_time();
drop function if exists tests.test_osv_not_on_time();
drop function if exists tests.test_get_tree_of_called_times();

drop table if exists pgconf.osv;
drop table if exists pgconf.transactions;
drop table if exists pgconf.analytic;
drop table if exists pgconf.account;

create table pgconf.account(
    id int generated always as identity primary key
    , parent_id int
    , num text
    , constraint account_01_fk foreign key(parent_id) references pgconf.account(id)
);

create table pgconf.analytic(
	id int generated always as identity primary key
	, subconto text
);

create table pgconf.transactions(
    account_num text 
    , subconto_1 text
    , subconto_2 text
    , subconto_3 text
    , amount_dt numeric(15, 2)
    , amount_ct numeric(15, 2)
);

create table pgconf.osv(
    account_id int 
    , subconto_1_id int
    , subconto_2_id int
    , subconto_3_id int
    , amount_dt numeric(15, 2)
    , amount_ct numeric(15, 2)
    , constraint osv_01_fk foreign key(account_id) references pgconf.account(id)
    , constraint osv_02_fk foreign key(subconto_1_id) references pgconf.analytic(id)
    , constraint osv_03_fk foreign key(subconto_2_id) references pgconf.analytic(id)
    , constraint osv_04_fk foreign key(subconto_3_id) references pgconf.analytic(id)
);

create or replace function pgconf.get_osv_slice(_account_id int, _subc_1 int, _subc_2 int)
returns table(
    ordercol text[]
    , account_num text
    , subconto_1_id int
    , subconto_1 text
    , subconto_2_id int
    , subconto_2 text
    , subconto_3 text
    , amount_dt numeric(15, 2)
    , amount_ct numeric(15, 2)
)
language plpgsql
as $$
begin
return query
with recursive account_tree as (
    select id, parent_id, num
    from pgconf.account
    where (id = _account_id or _account_id is null)
        and parent_id is null
    union all
    select a.id, a.parent_id, a.num
    from account_tree t
    join pgconf.account a
    on a.parent_id = t.id
)search depth first by num set account_order
select 
    t.account_order::text[]
    , t.num                as account_num
    , a1.id              as subconto_1_id
    , a1.subconto        as subconto_1
    , a2.id              as subconto_2_id
    , a2.subconto        as subconto_2
    , a3.subconto        as subconto_3
    , o.amount_dt
    , o.amount_ct
from account_tree t
left join pgconf.osv o
on o.account_id = t.id
left join pgconf.analytic a1
on a1.id = o.subconto_1_id
left join pgconf.analytic a2
on a2.id = o.subconto_2_id
left join pgconf.analytic a3
on a3.id = o.subconto_3_id
where
    pgconf.time_machine_now() between '12:00'::time and '15:00'::time
    and (_account_id is null and o.subconto_1_id is null and o.subconto_2_id is null and o.subconto_3_id is null)
order by t.account_order
;
end;
$$;

create or replace function pgconf.get_tree_of(_account_id int)
 returns table(id int, parent_id int, num text, lev int, is_folder bool)
 language sql
as $function$
with recursive acc as (
    select id, parent_id, num, 1 as l, True as is_folder from pgconf.account 
    where (id = _account_id and _account_id is not null) or (_account_id is null and parent_id is null)
    union all
    select a2.id, a2.parent_id, a2.num, a1.l + 1 as l
        , exists(select from pgconf.account ca where ca.parent_id = a2.id) as is_folder
    from acc a1
    join pgconf.account a2
    on a1.id = a2.parent_id 
)
select * from acc a 
$function$
;

create or replace function pgconf.time_machine_now()
returns time
language sql
as $$
    select now()::time;
$$;

create or replace procedure pgconf.make_osv_report()
language plpgsql
as $$
begin
    insert into pgconf.osv(account_id, subconto_1_id, subconto_2_id, subconto_3_id, amount_dt, amount_ct)
    select a.id, a1.id, a2.id, a3.id, sum(amount_dt), sum(amount_ct)
    from pgconf.account a
    join pgconf.transactions t
    on t.account_num = a.num
    left join pgconf.analytic a1
    on a1.subconto = t.subconto_1
    left join pgconf.analytic a2
    on a2.subconto = t.subconto_2
    left join pgconf.analytic a3
    on a3.subconto = t.subconto_3
    group by a.id, grouping sets(
        (a.id, a1.id, a2.id, a3.id)
        , (a.id, a1.id, a2.id)
        , (a.id, a1.id)
        , (a.id)
    );

    insert into pgconf.osv(account_id, subconto_1_id, subconto_2_id, subconto_3_id, amount_dt, amount_ct)
    select 
        acc.id
        , null, null, null
        , agg.amount_dt
        , agg.amount_ct
    from pgconf.get_tree_of(null) as acc
    left join lateral(
        select 
            sum(osv.amount_dt) as amount_dt
            , sum(osv.amount_ct) as amount_ct
        from pgconf.osv
        where osv.account_id in (select id from pgconf.get_tree_of(acc.id) t where not t.is_folder)
            and subconto_1_id is null and subconto_2_id is null and subconto_3_id is null
    ) as agg on true
    where 
        acc.is_folder;
end;
$$;

create or replace procedure tests.create_test_data()
language plpgsql
as $$
begin
    call tap.fake_table(
        '{pgconf.account, pgconf.analytic, pgconf.osv, pgconf.transactions}'::text[],
		_leave_primary_key => false,
        _make_table_empty => true,
        _drop_not_null => false,
        _drop_collation => false
    );

    insert into pgconf.account(parent_id, num) values(null, '02');

    insert into pgconf.account(parent_id, num)
    select id, '02.01'
    from pgconf.account where num = '02';

    insert into pgconf.account(parent_id, num) values(null, '01');

    insert into pgconf.account(parent_id, num)
    select id, '03.01'
    from pgconf.account where num = '01';

    insert into pgconf.account(parent_id, num)
    select id, '01.01.01'
    from pgconf.account where num = '03.01';
    
    insert into pgconf.account(parent_id, num)
    select id, '01.01.02'
    from pgconf.account where num = '03.01';

    insert into pgconf.account(parent_id, num)
    select id, '01.01.01.01'
    from pgconf.account where num = '01.01.01';

    insert into pgconf.account(parent_id, num)
    select id, '01.01.01.02'
    from pgconf.account where num = '01.01.01';

    insert into pgconf.account(parent_id, num)
    select id, '01.01.02.01'
    from pgconf.account where num = '01.01.02';

    insert into pgconf.analytic(subconto) values('Суб_1'), ('Суб_2'), ('Суб_3'), ('Суб_4'), ('Суб_5'), ('Суб_6'), ('Суб_7');

    insert into pgconf.transactions(account_num, subconto_1, subconto_2, subconto_3, amount_dt, amount_ct) values
    ('01.01.01.01', 'Суб_1', 'Суб_2', 'Суб_4', 10, 0)
    ,  ('01.01.01.01', 'Суб_1', 'Суб_2', 'Суб_5', 10, 0)
    ,  ('01.01.01.01', 'Суб_1', 'Суб_3', 'Суб_6', 10, 0)
    ,  ('01.01.01.02', 'Суб_1', 'Суб_3', 'Суб_7', 10, 0)
    ,  ('01.01.02.01', 'Суб_1', 'Суб_2', 'Суб_4', 10, 0)
    ,  ('02.01', 'Суб_1', 'Суб_3', 'Суб_5', 0, 10)
    ,  ('02.01', 'Суб_1', 'Суб_2', 'Суб_4', 0, 10);

	call pgconf.make_osv_report();
end;
$$;

create or replace function tests.test_osv_ordered_in_depth()
returns setof text
language plpgsql
as $$
begin 
    -- GIVEN
    call tests.create_test_data();
    call tap.mock_func('pgconf', 'time_machine_now', '()'
        , _return_scalar_value => '13:00'::time);
    
    -- WHEN
    perform tap.drop_prepared_statement('{expected, returned}'::text[]);

    prepare expected as 
    select num::text
    from (values ('01', 1), ('03.01', 2), ('01.01.01', 2), ('01.01.01.01', 3), ('01.01.01.02', 4)
        , ('01.01.02', 5), ('01.01.02.01', 6)
        , ('02', 7), ('02.01', 8)) as t(num, id)
    order by id;

    prepare returned as
    select account_num from pgconf.get_osv_slice(null, null, null);

    -- THEN
    return query
    select tap.results_eq(
        'returned',
        'expected',
        'Accounts must be sorted in depth first.'
    );


    create table pgconf.slice as 
    select * from pgconf.get_osv_slice(null, null, null);

    call tap.print_table_as_json('pgconf', 'slice');
    call tap.print_table_as_json('pgconf', 'account');

    -- WHEN 
    perform tap.drop_prepared_statement('{expected, returned}'::text[]);
end;
$$;

create or replace function tests.test_osv_on_time()
returns setof text
language plpgsql
as $$
begin 
    -- GIVEN
    call tests.create_test_data();
    call tap.mock_func('pgconf', 'time_machine_now', '()'
        , _return_scalar_value => '15:01'::time);

    create table pgconf.x as select * from pgconf.time_machine_now();
    call tap.print_table_as_json('pgconf', 'x');

    -- WHEN    
    perform tap.drop_prepared_statement('{returned}'::text[]);

    prepare returned as
    select * from pgconf.get_osv_slice(null, null, null);

    -- THEN
    return query
    select tap.is_empty(
        'returned',
        'It is not good time to make osv report.'
    );

    perform tap.drop_prepared_statement('{returned}'::text[]);
end;
$$;

create or replace function tests.test_osv_not_on_time()
returns setof text
language plpgsql
as $$
begin 
    -- GIVEN
    call tests.create_test_data();
    call tap.mock_func('pgconf', 'time_machine_now', '()'
        , _return_set_value => null, _return_scalar_value => '13:00'::time);

    -- WHEN    
    perform tap.drop_prepared_statement('{returned}'::text[]);

    prepare returned as
    select * from pgconf.get_osv_slice(null, null, null);

    -- THEN
    return query
    select tap.isnt_empty(
        'returned',
        'Time has come. We can make osv report.'
    );

    perform tap.drop_prepared_statement('{expected}'::text[]);
end;
$$;

create or replace function tests.test_get_tree_of_called_times()
returns setof text
language plpgsql
as $$
begin 
    -- GIVEN
    call tests.create_test_data();

    -- THEN
    return query
    select tap.call_count(6, 'pgconf'
		, 'get_tree_of', '{int}'::name[]);
end;
$$;

select * from tap.runtests('tests', '^test_');

select * from tap.runtests('tests', 'test_osv_on_time');