create or replace function public.igr_v2_min_players(p_scenario text)
returns integer
language sql
immutable
set search_path to 'public'
as $function$
  select case
    when p_scenario in ('001','003','004','005','006') then 4
    when p_scenario in ('002','007','008','009','010','011','012','013','014','015','016') then 5
    when p_scenario = '018' then 6
    when p_scenario = '017' then 7
    when p_scenario = '019' then 9
    when p_scenario = '020' then 13
    else 5
  end;
$function$;

create or replace function public.igr_v2_max_players(p_scenario text)
returns integer
language sql
immutable
set search_path to 'public'
as $function$
  select case
    when p_scenario in ('001','003','004','005','006') then 5
    when p_scenario = '002' then 6
    when p_scenario in ('007','008','009','010','011','012') then 5
    when p_scenario in ('013','014') then 6
    when p_scenario = '015' then 7
    when p_scenario = '016' then 8
    when p_scenario = '017' then 8
    when p_scenario = '018' then 6
    when p_scenario = '019' then 9
    when p_scenario = '020' then 16
    else 5
  end;
$function$;
