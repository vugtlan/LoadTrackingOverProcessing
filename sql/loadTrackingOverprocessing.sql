with sla_performance as
(
select
    lb.load_num,
    
    SUM(S.TRACKING_SLA_PRE_PICK_ACTUAL) TRACKING_SLA_PRE_PICK_ACTUAL,
    SUM(S.TRACKING_SLA_PRE_PICK_POSSIBLE) TRACKING_SLA_PRE_PICK_POSSIBLE,
    div0(SUM(S.TRACKING_SLA_PRE_PICK_ACTUAL),SUM(S.TRACKING_SLA_PRE_PICK_POSSIBLE)) TRACKING_SLA_PRE_PICK,

    SUM(S.TRACKING_SLA_IN_TRANSIT_ACTUAL) TRACKING_SLA_IN_TRANSIT_ACTUAL,
    SUM(S.TRACKING_SLA_IN_TRANSIT_POSSIBLE) TRACKING_SLA_IN_TRANSIT_POSSIBLE,
    div0(SUM(S.TRACKING_SLA_IN_TRANSIT_ACTUAL),SUM(S.TRACKING_SLA_IN_TRANSIT_POSSIBLE)) TRACKING_SLA_IN_TRANSIT,
    
    SUM(S.TRACKING_SLA_TOTAL_SCORE_ACTUAL) TRACKING_SLA_TOTAL_SCORE_ACTUAL,
    SUM(S.TRACKING_SLA_TOTAL_SCORE_POSSIBLE) TRACKING_SLA_TOTAL_SCORE_POSSIBLE,
    div0(SUM(S.TRACKING_SLA_TOTAL_SCORE_ACTUAL),SUM(S.TRACKING_SLA_TOTAL_SCORE_POSSIBLE)) TRACKING_SLA_TOTAL
    
from nast_carrier_domain.broker.load_books lb
inner join nast_customer_domain.broker.metric_customer_order_load_books s on lb.load_num = s.load_num and lb.seq_num = s.book_seq_num
where to_date(booked_datetime) >= TO_DATE({startdate})
group by 1
)

--This filters to truckload, execution, non intermodal, non consolidator, non drop trailer loads that just have one carrier for the entire life of the load
,loads_filter as
(
select lb.load_num, count(distinct seq_num) num_seq_num, count(distinct lb.carrier_code) num_carriers
from nast_carrier_domain.broker.load_books lb
inner join cdc_express.broker.dbo_loads l on l.loadnum = lb.load_num and lower(l.condition) != 'x'
inner join enterprise_reference_domain.broker.ref_carrier_flattened c on c.carrier_party_code = lb.carrier_code
inner join nast_carrier_domain.broker.loads cl on cl.load_num = lb.load_num and cl.is_cross_border_related = 0 -- Removing cross boarder loads
where lb.bounced = False 
    and lb.nast_truckload_flag = True 
    and lb.is_execution_load_book = True
    and c.is_known_consolidator = False
    -- Removes intermodal carriers
    and lb.carrier_branch_code != '0273'
    and droptrailerflag = False
    and activity_date >= {startdate}
group by 1
having num_seq_num = 1 and num_carriers = 1
)

-- select * from sla_performance where tracking_sla_pre_pick != 0 and tracking_sla_total != 0

,tracking_method as
(
select
        a.load_num,
        -- a.book_id,
        a.version_start_datetime_tz,
        a.tracking_identifier_clean,
        a.tracking_identifier_type,
        a.tracking_method_type,
        -- row_number() over (partition by a.load_num order by a.version_start_datetime_tz desc) most_recent_record,
        -- row_number() over (partition by a.load_num order by a.version_start_datetime_tz asc) first_record
        -- count(*) over (partition by load_num) as num_records
    from nast_carrier_domain.broker.tracking_status_audit_log a
    inner join nast_carrier_domain.broker.load_books lb on lb.load_num = a.load_num and lb.seq_num = a.book_id 
    inner join enterprise_reference_domain.broker.ref_carrier_flattened c on c.carrier_party_code = lb.carrier_code
    inner join loads_filter lf on lf.load_num = a.load_num
    where
        tracking_identifier_clean is not null
    and tracking_identifier_type is not null
    and lower(a.tracking_condition) = 'healthy'
    and lb.nast_truckload_flag = TRUE
    and lb.is_execution_load_book = TRUE
    and c.is_known_consolidator = FALSE
    -- Removing Intermodal carriers
    and lb.carrier_branch_code != '0273'
    and to_date(version_start_datetime_tz) >= TO_DATE({startdate})
)

-- select * from tracking_method limit 50

,check_calls as
(
select 
    a.load_num,
    a.check_call_type,
    b.description,
    convert_timezone('America/Chicago',a.entered_datetime_tz) /*::string*/ entered_datetime_cst,
    a.city,
    a.state,
    a.country,
    a.latitude,
    a.longitude,
    a.automated,
    a.is_digital,
    a.is_predicted,
    a.update_user,
    case when c.seven_letter is not null then 1 else 0 end human_entered_checkcall_flag,
    tm.tracking_identifier_clean,
    tm.tracking_identifier_type,
    tm.tracking_method_type,
from nast_carrier_domain.broker.load_tracking a
inner join enterprise_reference_domain.broker.ref_data b on a.check_call_type = b.code and b.type = 'CHECKCALL'
left join enterprise_reference_domain.broker.ref_worker c on c.seven_letter = a.update_user
left join tracking_method tm on tm.load_num = a.load_num and convert_timezone('America/Chicago',tm.version_start_datetime_tz) <= convert_timezone('America/Chicago',a.entered_datetime_tz)
inner join loads_filter lf on lf.load_num = a.load_num
where /*check_call_type = 'CC' and*/ to_date(entered_datetime_tz) >= TO_DATE({startdate})
qualify row_number() over (partition by a.load_num, a.check_call_type, b.description, entered_datetime_cst order by tm.version_start_datetime_tz desc) = 1
)

-- select * from check_calls where load_num = 552554547 limit 25

-- select load_num,
-- count(*) num_check_calls,
-- sum(human_entered_checkcall_flag) num_human_check_calls
-- from check_calls
-- where country = 'US' and tracking_method_type is not null
-- group by 1
-- having num_human_check_calls > 0 and num_check_calls != num_human_check_calls

-- select *
-- from check_calls 
-- where load_num = 550404756 --553360137 (this load has manual and automatic check calls and the carrier is set up for auto tracking)




-- Gets the most updated appointment time for each stop on the load
,latest_sched_pickup_open as
(
    select
        loadnum load_num,
        -- lb.booked_datetime,
        concat(stop_type,'-Open') check_call_type,
        -- stop_num,
        warehousecode description,
        convert_timezone('America/Chicago',apptopendatetime_cst) entered_datetime_cst,
        -- concat(convert_timezone('America/Chicago',apptopendatetime_cst), ' - ', convert_timezone('America/Chicago',apptclosedatetime_cst))::string entered_datetime_cst,
        -- ROW_NUMBER() OVER (
        --     PARTITION BY appt.loadnum, appt.stop_num, appt.stop_type
        --     ORDER BY appt.scheddatetime DESC
        -- ) AS rn_sched
        location.city city,
        location.state state,
        location.country country,
        nullif(location.latitude,'')::FLOAT latitude,
        nullif(location.longitude,'')::FLOAT longitude,
        null automated,
        null is_digital,
        null is_predicted,
        null update_user,
        null human_entered_checkcall_flag,
        null tracking_identifier_clean,
        null tracking_identifier_type,
        null tracking_method_type
    from nast_operations_domain.broker.appointment_universe appt
    inner join nast_carrier_domain.broker.load_books lb on lb.load_num = appt.loadnum
    -- inner join first_booked_date fbd on fbd.load_num = lb.load_num and fbd.first_seq_num = lb.seq_num
    inner join loads_filter lf on lf.load_num = appt.loadnum
    -- Getting only appointments that are in the US
    inner join enterprise_reference_domain.broker.ref_location location on location.location_party_code = appt.warehousecode and location.country = 'United States'
    where /*to_date(lb.booked_datetime) <= to_date(appt.apptopendatetime_cst) and*/ appt.activity in ('APPOINTMENTS SET','RESCHEDULES SET','APPOINTMENT INFO UPDATE','APPOINTMENT REMOVAL') and stop_type = 'P'
        and apptopendatetime_cst is not null
    qualify ROW_NUMBER() OVER (
            PARTITION BY appt.loadnum, appt.stop_num, appt.stop_type
            ORDER BY appt.scheddatetime DESC
        ) = 1
)

,latest_sched_pickup_close as
(
    select
        loadnum load_num,
        -- lb.booked_datetime,
        concat(stop_type,'-Close') check_call_type,
        -- stop_num,
        warehousecode description,
        -- convert_timezone('America/Chicago',apptopendatetime_cst) entered_datetime_cst,
        convert_timezone('America/Chicago',apptclosedatetime_cst) entered_datetime_cst,
        -- concat(convert_timezone('America/Chicago',apptopendatetime_cst), ' - ', convert_timezone('America/Chicago',apptclosedatetime_cst))::string entered_datetime_cst,
        -- ROW_NUMBER() OVER (
        --     PARTITION BY appt.loadnum, appt.stop_num, appt.stop_type
        --     ORDER BY appt.scheddatetime DESC
        -- ) AS rn_sched
        location.city city,
        location.state state,
        location.country country,
        nullif(location.latitude,'')::FLOAT latitude,
        nullif(location.longitude,'')::FLOAT longitude,
        null automated,
        null is_digital,
        null is_predicted,
        null update_user,
        null human_entered_checkcall_flag,
        null tracking_identifier_clean,
        null tracking_identifier_type,
        null tracking_method_type
    from nast_operations_domain.broker.appointment_universe appt
    inner join nast_carrier_domain.broker.load_books lb on lb.load_num = appt.loadnum
    -- inner join first_booked_date fbd on fbd.load_num = lb.load_num and fbd.first_seq_num = lb.seq_num
    inner join loads_filter lf on lf.load_num = appt.loadnum
    -- Getting only appointments that are in the US
    inner join enterprise_reference_domain.broker.ref_location location on location.location_party_code = appt.warehousecode and location.country = 'United States'
    where /*to_date(lb.booked_datetime) <= to_date(appt.apptopendatetime_cst) and*/ appt.activity in ('APPOINTMENTS SET','RESCHEDULES SET','APPOINTMENT INFO UPDATE','APPOINTMENT REMOVAL') and stop_type = 'P'
        and apptclosedatetime_cst is not null
    qualify ROW_NUMBER() OVER (
            PARTITION BY appt.loadnum, appt.stop_num, appt.stop_type
            ORDER BY appt.scheddatetime DESC
        ) = 1
)

,latest_sched_dropoff_open as
(
    select
        loadnum load_num,
        -- lb.booked_datetime,
        concat(stop_type,'-Open') check_call_type,
        -- stop_num,
        warehousecode description,
        convert_timezone('America/Chicago',apptopendatetime_cst) entered_datetime_cst,
        -- convert_timezone('America/Chicago',apptclosedatetime_cst) entered_datetime_cst,
        -- concat(convert_timezone('America/Chicago',apptopendatetime_cst), ' - ', convert_timezone('America/Chicago',apptclosedatetime_cst))::string entered_datetime_cst,
        -- ROW_NUMBER() OVER (
        --     PARTITION BY appt.loadnum, appt.stop_num, appt.stop_type
        --     ORDER BY appt.scheddatetime DESC
        -- ) AS rn_sched
        location.city city,
        location.state state,
        location.country country,
        nullif(location.latitude,'')::FLOAT latitude,
        nullif(location.longitude,'')::FLOAT longitude,
        null automated,
        null is_digital,
        null is_predicted,
        null update_user,
        null human_entered_checkcall_flag,
        null tracking_identifier_clean,
        null tracking_identifier_type,
        null tracking_method_type
    from nast_operations_domain.broker.appointment_universe appt
    inner join nast_carrier_domain.broker.load_books lb on lb.load_num = appt.loadnum
    -- inner join first_booked_date fbd on fbd.load_num = lb.load_num and fbd.first_seq_num = lb.seq_num
    inner join loads_filter lf on lf.load_num = appt.loadnum
    -- Getting only appointments that are in the US
    inner join enterprise_reference_domain.broker.ref_location location on location.location_party_code = appt.warehousecode and location.country = 'United States'
    where /*to_date(lb.booked_datetime) <= to_date(appt.apptopendatetime_cst) and*/ appt.activity in ('APPOINTMENTS SET','RESCHEDULES SET','APPOINTMENT INFO UPDATE','APPOINTMENT REMOVAL') and stop_type = 'D'
        and apptopendatetime_cst is not null
    qualify ROW_NUMBER() OVER (
            PARTITION BY appt.loadnum, appt.stop_num, appt.stop_type
            ORDER BY appt.scheddatetime DESC
        ) = 1
)

,latest_sched_dropoff_close as
(
    select
        loadnum load_num,
        -- lb.booked_datetime,
        concat(stop_type,'-Close') check_call_type,
        -- stop_num,
        warehousecode description,
        -- convert_timezone('America/Chicago',apptopendatetime_cst) entered_datetime_cst,
        convert_timezone('America/Chicago',apptclosedatetime_cst) entered_datetime_cst,
        -- concat(convert_timezone('America/Chicago',apptopendatetime_cst), ' - ', convert_timezone('America/Chicago',apptclosedatetime_cst))::string entered_datetime_cst,
        -- ROW_NUMBER() OVER (
        --     PARTITION BY appt.loadnum, appt.stop_num, appt.stop_type
        --     ORDER BY appt.scheddatetime DESC
        -- ) AS rn_sched
        location.city city,
        location.state state,
        location.country country,
        nullif(location.latitude,'')::FLOAT latitude,
        nullif(location.longitude,'')::FLOAT longitude,
        null automated,
        null is_digital,
        null is_predicted,
        null update_user,
        null human_entered_checkcall_flag,
        null tracking_identifier_clean,
        null tracking_identifier_type,
        null tracking_method_type
    from nast_operations_domain.broker.appointment_universe appt
    inner join nast_carrier_domain.broker.load_books lb on lb.load_num = appt.loadnum
    -- inner join first_booked_date fbd on fbd.load_num = lb.load_num and fbd.first_seq_num = lb.seq_num
    inner join loads_filter lf on lf.load_num = appt.loadnum
    -- Getting only appointments that are in the US
    inner join enterprise_reference_domain.broker.ref_location location on location.location_party_code = appt.warehousecode and location.country = 'United States'
    where /*to_date(lb.booked_datetime) <= to_date(appt.apptopendatetime_cst) and*/ appt.activity in ('APPOINTMENTS SET','RESCHEDULES SET','APPOINTMENT INFO UPDATE','APPOINTMENT REMOVAL') and stop_type = 'D'
        and apptclosedatetime_cst is not null
    qualify ROW_NUMBER() OVER (
            PARTITION BY appt.loadnum, appt.stop_num, appt.stop_type
            ORDER BY appt.scheddatetime DESC
        ) = 1
)


-- select * from latest_sched where loadnum = 552554547 --550404756

-- select *
-- from latest_sched where loadnum = 552554547

-- select ls.*, cc.*
-- from latest_sched ls
-- left join check_calls cc on ls.loadnum = cc.load_num
-- where cc.load_num = 552554547


 /*select cc.*, ls.*
 from check_calls cc
 inner join latest_sched ls on ls.loadnum = cc.load_num and cc.entered_datetime_cst <= ls.apptopendatetime_cst 
 where cc.load_num = 552554547*/


,data_final as
(
select *
from check_calls

union

-- select *
-- from latest_sched

select *
from latest_sched_pickup_open

union

select *
from latest_sched_pickup_close

union

select *
from latest_sched_dropoff_open

union

select *
from latest_sched_dropoff_close
)

,us_loads as
(
select distinct load_num
from data_final
where country = 'United States'
)

-- select * from tracking_method where load_num = 552894790

select a.*, b.TRACKING_SLA_PRE_PICK, b.TRACKING_SLA_IN_TRANSIT, b.TRACKING_SLA_TOTAL, b.TRACKING_SLA_TOTAL_SCORE_ACTUAL, b.TRACKING_SLA_TOTAL_SCORE_POSSIBLE 
from data_final a
left join sla_performance b on a.load_num = b.load_num
-- Filtering to just US loads
inner join us_loads on us_loads.load_num = a.load_num
-- where a.load_num = 552527278 --552554547 
order by a.load_num, a.entered_datetime_cst asc