-- ============================================================
-- 20260909013109_inside_grey_room_v2_core.sql
-- ============================================================

create extension if not exists pgcrypto;

create table if not exists public.igr_v2_rooms (
  code text primary key,
  scenario_id text not null,
  status text not null default 'lobby' check (status in ('lobby','playing','closed')),
  cycle integer not null default 0,
  phase text not null default 'lobby',
  host_token uuid not null default gen_random_uuid(),
  config jsonb not null default '{}'::jsonb,
  state jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.igr_v2_players (
  id uuid primary key default gen_random_uuid(),
  room_code text not null references public.igr_v2_rooms(code) on delete cascade,
  pseudo text not null check (char_length(pseudo) between 1 and 22),
  seat_index integer not null,
  is_host boolean not null default false,
  public_role text,
  secret_role text,
  player_token uuid not null default gen_random_uuid(),
  ready boolean not null default false,
  private_state jsonb not null default '{}'::jsonb,
  joined_at timestamptz not null default now(),
  unique(room_code, pseudo),
  unique(room_code, seat_index)
);

create table if not exists public.igr_v2_events (
  id bigint generated always as identity primary key,
  room_code text not null references public.igr_v2_rooms(code) on delete cascade,
  event_type text not null,
  visibility text not null default 'public' check (visibility in ('public','investigation','private','defense')),
  target_player_id uuid references public.igr_v2_players(id) on delete cascade,
  payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create table if not exists public.igr_v2_actions (
  id bigint generated always as identity primary key,
  room_code text not null references public.igr_v2_rooms(code) on delete cascade,
  player_id uuid not null references public.igr_v2_players(id) on delete cascade,
  action_type text not null,
  payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index if not exists igr_v2_players_room_idx on public.igr_v2_players(room_code, seat_index);
create index if not exists igr_v2_events_room_idx on public.igr_v2_events(room_code, id);
create index if not exists igr_v2_actions_room_idx on public.igr_v2_actions(room_code, id);

alter table public.igr_v2_rooms enable row level security;
alter table public.igr_v2_players enable row level security;
alter table public.igr_v2_events enable row level security;
alter table public.igr_v2_actions enable row level security;

revoke all on public.igr_v2_rooms from anon, authenticated;
revoke all on public.igr_v2_players from anon, authenticated;
revoke all on public.igr_v2_events from anon, authenticated;
revoke all on public.igr_v2_actions from anon, authenticated;

create or replace function public.igr_v2_min_players(p_scenario text)
returns integer language sql immutable as $$
  select case
    when p_scenario = '019' then 9
    when p_scenario = '020' then 13
    when p_scenario = '017' then 7
    when p_scenario = '018' then 6
    when p_scenario in ('013','014') then 5
    else 4
  end;
$$;

create or replace function public.igr_v2_max_players(p_scenario text)
returns integer language sql immutable as $$
  select case
    when p_scenario = '019' then 9
    when p_scenario = '020' then 16
    when p_scenario = '017' then 8
    when p_scenario = '018' then 6
    when p_scenario = '016' then 8
    when p_scenario = '015' then 7
    when p_scenario in ('013','014') then 6
    else 5
  end;
$$;

create or replace function public.igr_v2_create_room(p_code text, p_scenario_id text, p_pseudo text)
returns table(room_code text, player_id uuid, player_token uuid, host_token uuid)
language plpgsql security definer set search_path = public as $$
declare
  v_player public.igr_v2_players%rowtype;
  v_room public.igr_v2_rooms%rowtype;
begin
  if p_code !~ '^[A-Z2-9]{5}$' then raise exception 'invalid room code'; end if;
  if p_scenario_id !~ '^0(0[1-9]|1[0-9]|20)$' then raise exception 'invalid scenario'; end if;
  insert into public.igr_v2_rooms(code,scenario_id) values (upper(p_code),p_scenario_id) returning * into v_room;
  insert into public.igr_v2_players(room_code,pseudo,seat_index,is_host,public_role)
    values (v_room.code,trim(p_pseudo),0,true,'enqueteur') returning * into v_player;
  insert into public.igr_v2_events(room_code,event_type,payload) values(v_room.code,'room_created',jsonb_build_object('scenario_id',p_scenario_id));
  return query select v_room.code,v_player.id,v_player.player_token,v_room.host_token;
end;
$$;

create or replace function public.igr_v2_join_room(p_code text, p_pseudo text)
returns table(room_code text, player_id uuid, player_token uuid)
language plpgsql security definer set search_path = public as $$
declare
  v_room public.igr_v2_rooms%rowtype;
  v_player public.igr_v2_players%rowtype;
  v_seat integer;
  v_count integer;
begin
  select * into v_room from public.igr_v2_rooms where code=upper(trim(p_code)) for update;
  if not found then raise exception 'room not found'; end if;
  if v_room.status <> 'lobby' then raise exception 'game already started'; end if;
  select count(*),coalesce(max(seat_index),-1)+1 into v_count,v_seat from public.igr_v2_players where room_code=v_room.code;
  if v_count >= public.igr_v2_max_players(v_room.scenario_id) then raise exception 'room full'; end if;
  insert into public.igr_v2_players(room_code,pseudo,seat_index,is_host,public_role)
    values(v_room.code,trim(p_pseudo),v_seat,false,'en attente') returning * into v_player;
  insert into public.igr_v2_events(room_code,event_type,payload) values(v_room.code,'player_joined',jsonb_build_object('pseudo',v_player.pseudo));
  return query select v_room.code,v_player.id,v_player.player_token;
end;
$$;

create or replace function public.igr_v2_lobby(p_code text, p_player_token uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_room public.igr_v2_rooms%rowtype;
  v_ok boolean;
  v_players jsonb;
begin
  select exists(select 1 from public.igr_v2_players where room_code=upper(trim(p_code)) and player_token=p_player_token) into v_ok;
  if not v_ok then raise exception 'unauthorized'; end if;
  select * into v_room from public.igr_v2_rooms where code=upper(trim(p_code));
  select coalesce(jsonb_agg(jsonb_build_object('id',id,'pseudo',pseudo,'seat_index',seat_index,'is_host',is_host,'public_role',public_role,'ready',ready) order by seat_index),'[]'::jsonb)
    into v_players from public.igr_v2_players where room_code=v_room.code;
  return jsonb_build_object('room',jsonb_build_object('code',v_room.code,'scenario_id',v_room.scenario_id,'status',v_room.status,'cycle',v_room.cycle,'phase',v_room.phase,'min_players',public.igr_v2_min_players(v_room.scenario_id),'max_players',public.igr_v2_max_players(v_room.scenario_id)),'players',v_players);
end;
$$;

create or replace function public.igr_v2_start_game(p_code text, p_host_token uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_room public.igr_v2_rooms%rowtype;
  v_count integer;
  v_p public.igr_v2_players%rowtype;
  v_role text;
  v_secret text;
  v_suspect_ids uuid[] := array[]::uuid[];
  v_spy_pos integer;
begin
  select * into v_room from public.igr_v2_rooms where code=upper(trim(p_code)) and host_token=p_host_token for update;
  if not found then raise exception 'unauthorized'; end if;
  if v_room.status <> 'lobby' then raise exception 'already started'; end if;
  select count(*) into v_count from public.igr_v2_players where room_code=v_room.code;
  if v_count < public.igr_v2_min_players(v_room.scenario_id) then raise exception 'not enough players'; end if;

  for v_p in select * from public.igr_v2_players where room_code=v_room.code order by seat_index loop
    v_role := 'suspect'; v_secret := 'suspect';
    if v_room.scenario_id='019' then
      v_role := (array['enqueteur','analyste','suspect','suspect','suspect','procureur','juge','journaliste','maitre'])[v_p.seat_index+1];
      v_secret := v_role;
    elsif v_room.scenario_id='020' then
      v_role := (array['enqueteur','analyste','inspecteur','procureur','juge','expert','suspect','suspect','suspect','suspect','maitre','journaliste','temoin','maitre','journaliste','temoin'])[v_p.seat_index+1];
      v_secret := v_role;
    elsif v_room.scenario_id='018' then
      v_role := (array['enqueteur','analyste','inspecteur','suspect','suspect','suspect'])[v_p.seat_index+1]; v_secret:=v_role;
    elsif v_room.scenario_id='017' then
      v_role := (array['enqueteur','analyste','procureur','suspect','suspect','suspect','temoin','temoin'])[v_p.seat_index+1]; v_secret:=v_role;
    elsif v_room.scenario_id='016' then
      v_role := (array['enqueteur','analyste','suspect','suspect','suspect','maitre','journaliste','juge'])[v_p.seat_index+1]; v_secret:=v_role;
    elsif v_room.scenario_id='015' then
      v_role := (array['enqueteur','analyste','suspect','suspect','suspect','journaliste','juge'])[v_p.seat_index+1]; v_secret:=v_role;
    elsif v_room.scenario_id='014' then
      v_role := (array['enqueteur','analyste','suspect','suspect','suspect','juge'])[v_p.seat_index+1]; v_secret:=v_role;
    elsif v_room.scenario_id='013' then
      v_role := (array['enqueteur','analyste','suspect','suspect','suspect','procureur'])[v_p.seat_index+1]; v_secret:=v_role;
    else
      v_role := case v_p.seat_index when 0 then 'enqueteur' when 1 then 'analyste' else 'suspect' end; v_secret:=v_role;
    end if;
    update public.igr_v2_players set public_role=v_role,secret_role=v_secret,ready=true where id=v_p.id;
    if v_role='suspect' then v_suspect_ids := array_append(v_suspect_ids,v_p.id); end if;
  end loop;

  if v_room.scenario_id in ('014','020') and array_length(v_suspect_ids,1) > 0 then
    v_spy_pos := 1 + (abs(hashtext(v_room.code)) % array_length(v_suspect_ids,1));
    update public.igr_v2_players set secret_role='espion' where id=v_suspect_ids[v_spy_pos];
  end if;

  update public.igr_v2_rooms set status='playing',phase='role_reading',cycle=0,updated_at=now() where code=v_room.code;
  insert into public.igr_v2_events(room_code,event_type,payload) values(v_room.code,'roles_distributed',jsonb_build_object('players',v_count));
  return jsonb_build_object('ok',true,'players',v_count,'phase','role_reading');
end;
$$;

create or replace function public.igr_v2_my_state(p_code text, p_player_token uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_p public.igr_v2_players%rowtype;
  v_room public.igr_v2_rooms%rowtype;
begin
  select * into v_p from public.igr_v2_players where room_code=upper(trim(p_code)) and player_token=p_player_token;
  if not found then raise exception 'unauthorized'; end if;
  select * into v_room from public.igr_v2_rooms where code=v_p.room_code;
  return jsonb_build_object('player',jsonb_build_object('id',v_p.id,'pseudo',v_p.pseudo,'seat_index',v_p.seat_index,'is_host',v_p.is_host,'public_role',v_p.public_role,'secret_role',case when v_room.status='playing' then v_p.secret_role else null end,'ready',v_p.ready,'private_state',v_p.private_state),'room',jsonb_build_object('code',v_room.code,'scenario_id',v_room.scenario_id,'status',v_room.status,'cycle',v_room.cycle,'phase',v_room.phase));
end;
$$;

create or replace function public.igr_v2_public_events(p_code text, p_player_token uuid, p_after bigint default 0)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_player public.igr_v2_players%rowtype;
  v_events jsonb;
begin
  select * into v_player from public.igr_v2_players where room_code=upper(trim(p_code)) and player_token=p_player_token;
  if not found then raise exception 'unauthorized'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('id',e.id,'event_type',e.event_type,'payload',e.payload,'created_at',e.created_at) order by e.id),'[]'::jsonb)
    into v_events
  from public.igr_v2_events e
  where e.room_code=v_player.room_code and e.id>p_after and (e.visibility='public' or (e.visibility='private' and e.target_player_id=v_player.id));
  return v_events;
end;
$$;

grant execute on function public.igr_v2_min_players(text) to anon, authenticated;
grant execute on function public.igr_v2_max_players(text) to anon, authenticated;
grant execute on function public.igr_v2_create_room(text,text,text) to anon, authenticated;
grant execute on function public.igr_v2_join_room(text,text) to anon, authenticated;
grant execute on function public.igr_v2_lobby(text,uuid) to anon, authenticated;
grant execute on function public.igr_v2_start_game(text,uuid) to anon, authenticated;
grant execute on function public.igr_v2_my_state(text,uuid) to anon, authenticated;
grant execute on function public.igr_v2_public_events(text,uuid,bigint) to anon, authenticated;


-- ============================================================
-- 20260909013305_fix_v2_join_room_qualification.sql
-- ============================================================

create or replace function public.igr_v2_join_room(p_code text, p_pseudo text)
returns table(room_code text, player_id uuid, player_token uuid)
language plpgsql security definer set search_path = public as $$
declare
  v_room public.igr_v2_rooms%rowtype;
  v_player public.igr_v2_players%rowtype;
  v_seat integer;
  v_count integer;
begin
  select r.* into v_room from public.igr_v2_rooms r where r.code=upper(trim(p_code)) for update;
  if not found then raise exception 'room not found'; end if;
  if v_room.status <> 'lobby' then raise exception 'game already started'; end if;
  select count(*),coalesce(max(p.seat_index),-1)+1 into v_count,v_seat from public.igr_v2_players p where p.room_code=v_room.code;
  if v_count >= public.igr_v2_max_players(v_room.scenario_id) then raise exception 'room full'; end if;
  insert into public.igr_v2_players(room_code,pseudo,seat_index,is_host,public_role)
    values(v_room.code,trim(p_pseudo),v_seat,false,'en attente') returning * into v_player;
  insert into public.igr_v2_events(room_code,event_type,payload) values(v_room.code,'player_joined',jsonb_build_object('pseudo',v_player.pseudo));
  return query select v_room.code,v_player.id,v_player.player_token;
end;
$$;


-- ============================================================
-- 20260909013755_harden_v2_helper_search_path.sql
-- ============================================================

alter function public.igr_v2_min_players(text) set search_path = public;
alter function public.igr_v2_max_players(text) set search_path = public;


-- ============================================================
-- 20260909025516_align_igr_v2_player_limits.sql
-- ============================================================

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


-- ============================================================
-- 20260909100802_expand_hidden_espion_scenarios.sql
-- ============================================================

create or replace function public.igr_v2_start_game(p_code text, p_host_token uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_room public.igr_v2_rooms%rowtype;
  v_count integer;
  v_p public.igr_v2_players%rowtype;
  v_role text;
  v_secret text;
  v_suspect_ids uuid[] := array[]::uuid[];
  v_spy_pos integer;
begin
  select * into v_room from public.igr_v2_rooms where code=upper(trim(p_code)) and host_token=p_host_token for update;
  if not found then raise exception 'unauthorized'; end if;
  if v_room.status <> 'lobby' then raise exception 'already started'; end if;
  select count(*) into v_count from public.igr_v2_players where room_code=v_room.code;
  if v_count < public.igr_v2_min_players(v_room.scenario_id) then raise exception 'not enough players'; end if;

  for v_p in select * from public.igr_v2_players where room_code=v_room.code order by seat_index loop
    v_role := 'suspect'; v_secret := 'suspect';
    if v_room.scenario_id='019' then
      v_role := (array['enqueteur','analyste','suspect','suspect','suspect','procureur','juge','journaliste','maitre'])[v_p.seat_index+1];
      v_secret := v_role;
    elsif v_room.scenario_id='020' then
      v_role := (array['enqueteur','analyste','inspecteur','procureur','juge','expert','suspect','suspect','suspect','suspect','maitre','journaliste','temoin','maitre','journaliste','temoin'])[v_p.seat_index+1];
      v_secret := v_role;
    elsif v_room.scenario_id='018' then
      v_role := (array['enqueteur','analyste','inspecteur','suspect','suspect','suspect'])[v_p.seat_index+1]; v_secret:=v_role;
    elsif v_room.scenario_id='017' then
      v_role := (array['enqueteur','analyste','procureur','suspect','suspect','suspect','temoin','temoin'])[v_p.seat_index+1]; v_secret:=v_role;
    elsif v_room.scenario_id='016' then
      v_role := (array['enqueteur','analyste','suspect','suspect','suspect','maitre','journaliste','juge'])[v_p.seat_index+1]; v_secret:=v_role;
    elsif v_room.scenario_id='015' then
      v_role := (array['enqueteur','analyste','suspect','suspect','suspect','journaliste','juge'])[v_p.seat_index+1]; v_secret:=v_role;
    elsif v_room.scenario_id='014' then
      v_role := (array['enqueteur','analyste','suspect','suspect','suspect','juge'])[v_p.seat_index+1]; v_secret:=v_role;
    elsif v_room.scenario_id='013' then
      v_role := (array['enqueteur','analyste','suspect','suspect','suspect','procureur'])[v_p.seat_index+1]; v_secret:=v_role;
    else
      v_role := case v_p.seat_index when 0 then 'enqueteur' when 1 then 'analyste' else 'suspect' end; v_secret:=v_role;
    end if;
    update public.igr_v2_players set public_role=v_role,secret_role=v_secret,ready=true where id=v_p.id;
    if v_role='suspect' then v_suspect_ids := array_append(v_suspect_ids,v_p.id); end if;
  end loop;

  if v_room.scenario_id in ('013','014','016','019','020') and array_length(v_suspect_ids,1) > 0 then
    v_spy_pos := 1 + (abs(hashtext(v_room.code)) % array_length(v_suspect_ids,1));
    update public.igr_v2_players set secret_role='espion' where id=v_suspect_ids[v_spy_pos];
  end if;

  update public.igr_v2_rooms set status='playing',phase='role_reading',cycle=0,updated_at=now() where code=v_room.code;
  insert into public.igr_v2_events(room_code,event_type,payload) values(v_room.code,'roles_distributed',jsonb_build_object('players',v_count));
  return jsonb_build_object('ok',true,'players',v_count,'phase','role_reading');
end;
$function$;


-- ============================================================
-- 20260909194240_igr_v3_authoritative_schema.sql
-- ============================================================

create extension if not exists pgcrypto;
create table if not exists public.igr_v3_scenario_packs (scenario_id text primary key,pack jsonb not null,updated_at timestamptz not null default now());
create table if not exists public.igr_v3_rooms (code text primary key,scenario_id text not null,status text not null default 'lobby',cycle integer not null default 0,phase text not null default 'lobby',phase_started_at timestamptz,phase_ends_at timestamptz,host_token uuid not null default gen_random_uuid(),state jsonb not null default '{}'::jsonb,created_at timestamptz not null default now(),updated_at timestamptz not null default now());
create table if not exists public.igr_v3_players (id uuid primary key default gen_random_uuid(),room_code text not null references public.igr_v3_rooms(code) on delete cascade,pseudo text not null,seat_index integer not null,is_host boolean not null default false,public_role text not null default 'en_attente',secret_role text not null default 'en_attente',player_token uuid not null default gen_random_uuid(),private_state jsonb not null default '{}'::jsonb,ready boolean not null default false,joined_at timestamptz not null default now(),unique(room_code,seat_index),unique(room_code,player_token));
create table if not exists public.igr_v3_events (id bigint generated always as identity primary key,room_code text not null references public.igr_v3_rooms(code) on delete cascade,event_type text not null,visibility text not null default 'public',target_player_id uuid,audience_roles text[],payload jsonb not null default '{}'::jsonb,created_at timestamptz not null default now());
create table if not exists public.igr_v3_actions (id bigint generated always as identity primary key,room_code text not null references public.igr_v3_rooms(code) on delete cascade,player_id uuid not null references public.igr_v3_players(id) on delete cascade,cycle integer not null default 0,action_type text not null,payload jsonb not null default '{}'::jsonb,created_at timestamptz not null default now());
create table if not exists public.igr_v3_signals (id bigint generated always as identity primary key,room_code text not null references public.igr_v3_rooms(code) on delete cascade,from_player_id uuid not null references public.igr_v3_players(id) on delete cascade,to_player_id uuid not null references public.igr_v3_players(id) on delete cascade,signal_type text not null,payload jsonb not null,created_at timestamptz not null default now());
create index if not exists igr_v3_events_room_idx on public.igr_v3_events(room_code,id);
create index if not exists igr_v3_actions_room_idx on public.igr_v3_actions(room_code,cycle,action_type);
create index if not exists igr_v3_signals_to_idx on public.igr_v3_signals(room_code,to_player_id,id);
alter table public.igr_v3_scenario_packs enable row level security;
alter table public.igr_v3_rooms enable row level security;
alter table public.igr_v3_players enable row level security;
alter table public.igr_v3_events enable row level security;
alter table public.igr_v3_actions enable row level security;
alter table public.igr_v3_signals enable row level security;
revoke all on public.igr_v3_scenario_packs, public.igr_v3_rooms, public.igr_v3_players, public.igr_v3_events, public.igr_v3_actions, public.igr_v3_signals from anon, authenticated;


-- ============================================================
-- 20260909194419_igr_v3_core_functions_a.sql
-- ============================================================

create or replace function public.igr_v3_min_players(p_scenario text) returns integer language sql immutable set search_path=public as $$
 select case when p_scenario in ('001','003','004','005','006') then 4 when p_scenario='002' then 5 when p_scenario in ('007','008','009','010','011','012','013','014','015','016') then 5 when p_scenario='017' then 7 when p_scenario='018' then 6 when p_scenario='019' then 9 when p_scenario='020' then 13 else 5 end
$$;
create or replace function public.igr_v3_max_players(p_scenario text) returns integer language sql immutable set search_path=public as $$
 select case when p_scenario in ('001','003','004','005','006') then 5 when p_scenario='002' then 6 when p_scenario in ('007','008','009','010','011','012') then 5 when p_scenario in ('013','014') then 6 when p_scenario='015' then 7 when p_scenario='016' then 8 when p_scenario='017' then 8 when p_scenario='018' then 6 when p_scenario='019' then 9 when p_scenario='020' then 16 else 5 end
$$;
create or replace function public.igr_v3_role_for_seat(p_scenario text,p_seat int,p_count int) returns text language plpgsql immutable set search_path=public as $$
begin
 if p_scenario in ('001','003','004','005','006') then
   if p_seat=0 then return 'enqueteur'; elsif p_count=5 and p_seat=1 then return 'analyste'; else return 'suspect'; end if;
 elsif p_scenario='002' then
   if p_seat=0 then return 'enqueteur'; elsif p_count=6 and p_seat=1 then return 'analyste'; else return 'suspect'; end if;
 elsif p_scenario in ('007','008','009','010','011','012') then return (array['enqueteur','analyste','suspect','suspect','suspect'])[p_seat+1];
 elsif p_scenario='013' then return (array['enqueteur','analyste','suspect','suspect','suspect','procureur'])[p_seat+1];
 elsif p_scenario='014' then return (array['enqueteur','analyste','suspect','suspect','suspect','juge'])[p_seat+1];
 elsif p_scenario='015' then return (array['enqueteur','analyste','suspect','suspect','suspect','journaliste','juge'])[p_seat+1];
 elsif p_scenario='016' then return (array['enqueteur','analyste','suspect','suspect','suspect','maitre','journaliste','juge'])[p_seat+1];
 elsif p_scenario='017' then return (array['enqueteur','analyste','procureur','suspect','suspect','suspect','temoin','temoin'])[p_seat+1];
 elsif p_scenario='018' then return (array['enqueteur','analyste','inspecteur','suspect','suspect','suspect'])[p_seat+1];
 elsif p_scenario='019' then return (array['enqueteur','analyste','procureur','juge','journaliste','maitre','suspect','suspect','suspect'])[p_seat+1];
 elsif p_scenario='020' then return (array['enqueteur','analyste','inspecteur','procureur','juge','expert','suspect','suspect','suspect','suspect','maitre','journaliste','temoin','maitre','journaliste','temoin'])[p_seat+1];
 end if;
 return 'suspect';
end $$;
create or replace function public.igr_v3_create_room(p_code text,p_scenario_id text,p_pseudo text) returns jsonb language plpgsql security definer set search_path=public as $$
declare r public.igr_v3_rooms%rowtype; p public.igr_v3_players%rowtype;
begin
 if upper(p_code)!~'^[A-Z2-9]{5}$' then raise exception 'invalid room code'; end if;
 if not exists(select 1 from public.igr_v3_scenario_packs where scenario_id=p_scenario_id) then raise exception 'invalid scenario'; end if;
 insert into public.igr_v3_rooms(code,scenario_id) values(upper(p_code),p_scenario_id) returning * into r;
 insert into public.igr_v3_players(room_code,pseudo,seat_index,is_host,public_role,secret_role) values(r.code,left(trim(p_pseudo),22),0,true,'en_attente','en_attente') returning * into p;
 return jsonb_build_object('room_code',r.code,'player_id',p.id,'player_token',p.player_token,'host_token',r.host_token);
end $$;
create or replace function public.igr_v3_join_room(p_code text,p_pseudo text) returns jsonb language plpgsql security definer set search_path=public as $$
declare r public.igr_v3_rooms%rowtype; p public.igr_v3_players%rowtype; c int; s int;
begin
 select * into r from public.igr_v3_rooms where code=upper(trim(p_code)) for update;
 if not found then raise exception 'room not found'; end if;
 if r.status<>'lobby' then raise exception 'already started'; end if;
 select count(*),coalesce(max(seat_index),-1)+1 into c,s from public.igr_v3_players where room_code=r.code;
 if c>=public.igr_v3_max_players(r.scenario_id) then raise exception 'room full'; end if;
 insert into public.igr_v3_players(room_code,pseudo,seat_index,is_host,public_role,secret_role) values(r.code,left(trim(p_pseudo),22),s,false,'en_attente','en_attente') returning * into p;
 return jsonb_build_object('room_code',r.code,'player_id',p.id,'player_token',p.player_token);
end $$;
create or replace function public.igr_v3_build_private_card(p_scenario text,p_role text,p_suspect_index int,p_secret text) returns jsonb language plpgsql security definer set search_path=public as $$
declare pack jsonb; base jsonb; mission jsonb:='{}'::jsonb;
begin
 select p.pack into pack from public.igr_v3_scenario_packs p where p.scenario_id=p_scenario;
 if p_role='suspect' then base:=coalesce(pack->'suspects'->greatest(0,p_suspect_index-1),'{}'::jsonb);
 elsif p_role='enqueteur' then base:=jsonb_build_object('place','Tu diriges les interrogatoires et portes la reconstruction factuelle finale.','chronology',pack->>'context','hide','Aucun : tu ne dois pas inventer de preuve.','anchors','Croise les horaires, accès, objets et contradictions. Le stress seul ne prouve rien.','position','À la fin, attribue à chaque suspect un niveau de responsabilité de 0 à 3.');
 elsif p_role='analyste' then base:=jsonb_build_object('place','Tu es le profiler silencieux de l’enquête.','chronology',pack->>'context','hide','Aucun. Tes notes restent privées.','anchors','Observe cohérence, changements de récit, charge émotionnelle et stratégies de défense. Une réaction n’est jamais une preuve.','position','Pendant les interrogatoires tu observes. Pendant les débriefs tu réponds au QCM adaptatif et aides l’Enquêteur.');
 elsif p_role='procureur' then base:=jsonb_build_object('place','Tu représentes l’accusation sans être supérieur à l’Enquêteur.','chronology',pack->>'context','hide','Tes choix d’entretien et accords restent stratégiques.','anchors','Un entretien réussi par cycle, sauf dossier 017 : jusqu’à deux avec deux personnes différentes.','position','Poursuis la responsabilité démontrable, pas la personne la plus suspecte.');
 elsif p_role='juge' then base:=jsonb_build_object('place','Tu arbitres les informations protégées et la conséquence finale.','chronology',pack->>'context','hide','Tu disposes de 5 points de confidentialité.','anchors','Refuser une information ne doit jamais rendre le dossier insoluble.','position','Ne donne pas d’opinion orale avant les dernières défenses.');
 elsif p_role='journaliste' then base:=jsonb_build_object('place','Tu es indépendant des camps judiciaires.','chronology',pack->>'context','hide','Tes sources et ton angle éditorial t’appartiennent.','anchors','Une Breaking News maximum par cycle, trois sur une partie normale.','position','Publie un fait ou un angle réellement incriminant sans prétendre résoudre l’affaire.');
 elsif p_role='inspecteur' then base:=jsonb_build_object('place','Tu es l’acteur de terrain.','chronology',pack->>'context','hide','Tes choix de piste sont privés jusqu’au résultat.','anchors','Une action de terrain par cycle. Une mauvaise priorité peut coûter une opportunité.','position','Établis où chercher ; l’Expert établit ce qu’une trace permet de conclure.');
 elsif p_role='expert' then base:=jsonb_build_object('place','Tu es l’Expert / médecin légiste.','chronology',pack->>'context','hide','Tes priorités d’analyse sont privées.','anchors','Une analyse complémentaire par cycle parmi les options matériellement possibles.','position','Établis un fait technique, jamais un coupable.');
 elsif p_role='temoin' then base:=jsonb_build_object('place','Tu es témoin.','chronology',pack->>'context','hide','Tu peux cacher certains éléments personnels tant qu’ils ne modifient pas le canon.','anchors','La fenêtre témoins est commune : quatre minutes par cycle.','position','Réponds à partir de ce que tu sais réellement ; tu peux devenir personne d’intérêt puis suspect.');
 elsif p_role='maitre' then base:=jsonb_build_object('place','Tu es Avocat dans l’interface publique et Maître pendant la partie.','chronology',pack->>'context','hide','Tu ne connais pas automatiquement les secrets de tes clients.','anchors','Tu peux défendre plusieurs suspects compatibles et partages leur temps de défense finale.','position','Protège le degré exact de responsabilité de tes clients.');
 else base:=jsonb_build_object('place',p_role,'chronology',pack->>'context'); end if;
 if p_secret='espion' then mission:=jsonb_build_object('secret_mission','ESPION — Ta couverture publique reste Suspect. Observe, détourne et accomplis ta mission sans inventer de preuve officielle. Être Espion ne signifie pas être le responsable principal.'); end if;
 return base||mission;
end $$;
create or replace function public.igr_v3_start_game(p_code text,p_host_token uuid) returns jsonb language plpgsql security definer set search_path=public as $$
declare r public.igr_v3_rooms%rowtype; c int; p public.igr_v3_players%rowtype; role text; sus_i int:=0; sus_ids uuid[]:=array[]::uuid[]; spy_pos int; secret text;
begin
 select * into r from public.igr_v3_rooms where code=upper(trim(p_code)) and host_token=p_host_token for update;
 if not found then raise exception 'unauthorized'; end if;
 if r.status<>'lobby' then raise exception 'already started'; end if;
 select count(*) into c from public.igr_v3_players where room_code=r.code;
 if c<public.igr_v3_min_players(r.scenario_id) then raise exception 'not enough players'; end if;
 for p in select * from public.igr_v3_players where room_code=r.code order by seat_index loop
   role:=public.igr_v3_role_for_seat(r.scenario_id,p.seat_index,c); secret:=role;
   if role='suspect' then sus_i:=sus_i+1; sus_ids:=array_append(sus_ids,p.id); end if;
   update public.igr_v3_players set public_role=role,secret_role=secret,ready=true,private_state=public.igr_v3_build_private_card(r.scenario_id,role,sus_i,secret) where id=p.id;
 end loop;
 if r.scenario_id in ('013','014','016','019','020') and array_length(sus_ids,1)>0 then
   spy_pos:=1+(abs(hashtext(r.code))%array_length(sus_ids,1));
   update public.igr_v3_players p2 set secret_role='espion',private_state=public.igr_v3_build_private_card(r.scenario_id,'suspect',(select count(*) from public.igr_v3_players s where s.room_code=r.code and s.public_role='suspect' and s.seat_index<=p2.seat_index),'espion') where p2.id=sus_ids[spy_pos];
 end if;
 update public.igr_v3_rooms set status='playing',cycle=0,phase='role_reading',phase_started_at=now(),phase_ends_at=now()+interval '5 minutes',state=jsonb_build_object('used_trames','{}'::jsonb,'previous_target',null,'video_active',false,'video_cut_until',null),updated_at=now() where code=r.code;
 insert into public.igr_v3_events(room_code,event_type,payload) select r.code,'context',jsonb_build_object('title','CONTEXTE','text',x.pack->>'context') from public.igr_v3_scenario_packs x where x.scenario_id=r.scenario_id;
 insert into public.igr_v3_events(room_code,event_type,payload) values(r.code,'roles_distributed',jsonb_build_object('title','OUVERTURE DU DOSSIER','text','Les cartes privées ont été distribuées. Lecture individuelle : 5 minutes.'));
 return jsonb_build_object('ok',true);
end $$;


-- ============================================================
-- 20260909194525_igr_v3_core_functions_b.sql
-- ============================================================

create or replace function public.igr_v3_emit_trame(p_room text) returns void language plpgsql security definer set search_path=public as $$
declare r public.igr_v3_rooms%rowtype; pack jsonb; used jsonb; wanted text:='balanced'; q jsonb; tr jsonb; idx int; n int;
begin
 select * into r from public.igr_v3_rooms where code=p_room for update;
 select p.pack into pack from public.igr_v3_scenario_packs p where p.scenario_id=r.scenario_id;
 used:=coalesce(r.state->'used_trames','{}'::jsonb);
 select payload into q from public.igr_v3_actions where room_code=r.code and cycle=r.cycle and action_type='debrief' order by id desc limit 1;
 if coalesce((q->>'convergence')::int,1)>=2 then wanted:='ambiguity'; elsif coalesce((q->>'confusion')::int,1)>=2 then wanted:='clarity'; end if;
 n:=jsonb_array_length(pack->'trames');
 for idx in 0..n-1 loop tr:=pack->'trames'->idx; if coalesce((tr->>'min_cycle')::int,1)<=r.cycle and not (used ? idx::text) and (tr->>'kind'=wanted) then exit; else tr:=null; end if; end loop;
 if tr is null then for idx in 0..n-1 loop tr:=pack->'trames'->idx; if coalesce((tr->>'min_cycle')::int,1)<=r.cycle and not (used ? idx::text) then exit; else tr:=null; end if; end loop; end if;
 if tr is null then return; end if;
 used:=used||jsonb_build_object(idx::text,true);
 update public.igr_v3_rooms set state=jsonb_set(state,'{used_trames}',used,true) where code=r.code;
 insert into public.igr_v3_events(room_code,event_type,payload) values(r.code,'trame',jsonb_build_object('title',tr->>'title','text',tr->>'text','cycle',r.cycle));
end $$;
create or replace function public.igr_v3_tick(p_room text) returns void language plpgsql security definer set search_path=public as $$
declare r public.igr_v3_rooms%rowtype;
begin
 select * into r from public.igr_v3_rooms where code=p_room for update;
 if not found or r.status<>'playing' then return; end if;
 if r.phase_ends_at is null or now()<r.phase_ends_at then return; end if;
 if r.phase='role_reading' then
   update public.igr_v3_rooms set phase='initial_debrief',phase_started_at=now(),phase_ends_at=now()+interval '3 minutes' where code=r.code;
   insert into public.igr_v3_events(room_code,event_type,payload) values(r.code,'phase',jsonb_build_object('title','DÉBRIEF INITIAL','text','Enquêteur et Analyste : 3 minutes.'));
 elsif r.phase='initial_debrief' then
   update public.igr_v3_rooms set cycle=1,phase='interrogation_select',phase_started_at=now(),phase_ends_at=null where code=r.code;
 elsif r.phase='interrogation' then
   update public.igr_v3_rooms set phase='debrief',phase_started_at=now(),phase_ends_at=now()+interval '3 minutes' where code=r.code;
   insert into public.igr_v3_events(room_code,event_type,payload) values(r.code,'phase',jsonb_build_object('title','DÉBRIEF','text','Enquêteur et Analyste : 3 minutes. Le MJ prépare automatiquement la prochaine trame.'));
 elsif r.phase='debrief' then
   perform public.igr_v3_emit_trame(r.code);
   update public.igr_v3_rooms set phase='trame',phase_started_at=now(),phase_ends_at=now()+interval '20 seconds' where code=r.code;
 elsif r.phase='trame' then
   if r.cycle<3 then update public.igr_v3_rooms set cycle=r.cycle+1,phase='interrogation_select',phase_started_at=now(),phase_ends_at=null where code=r.code;
   else update public.igr_v3_rooms set phase='provisional',phase_started_at=now(),phase_ends_at=null where code=r.code; insert into public.igr_v3_events(room_code,event_type,payload) values(r.code,'phase',jsonb_build_object('title','ENQUÊTE CLOSE','text','Plus aucune trame, expertise ou action n’est disponible. L’Enquêteur doit verrouiller ses accusations provisoires.')); end if;
 elsif r.phase='defense' then
   update public.igr_v3_rooms set phase='final_debrief',phase_started_at=now(),phase_ends_at=now()+interval '3 minutes' where code=r.code;
 elsif r.phase='final_debrief' then
   update public.igr_v3_rooms set phase='locking',phase_started_at=now(),phase_ends_at=null where code=r.code;
   insert into public.igr_v3_events(room_code,event_type,payload) values(r.code,'phase',jsonb_build_object('title','FIN DES ÉCHANGES','text','Chaque rôle concerné verrouille maintenant son choix final sur son propre téléphone.'));
 end if;
end $$;
create or replace function public.igr_v3_visible_events(p_room text,p public.igr_v3_players) returns jsonb language sql security definer set search_path=public as $$
 select coalesce(jsonb_agg(jsonb_build_object('id',e.id,'event_type',e.event_type,'payload',e.payload,'created_at',e.created_at) order by e.id),'[]'::jsonb) from public.igr_v3_events e where e.room_code=p_room and (e.visibility='public' or (e.visibility='private' and e.target_player_id=p.id) or (e.visibility='roles' and p.public_role=any(e.audience_roles)))
$$;
create or replace function public.igr_v3_sync(p_code text,p_player_token uuid) returns jsonb language plpgsql security definer set search_path=public as $$
declare p public.igr_v3_players%rowtype; r public.igr_v3_rooms%rowtype; players jsonb; ev jsonb; suspects jsonb; v_pack jsonb;
begin
 select * into p from public.igr_v3_players where room_code=upper(trim(p_code)) and player_token=p_player_token;
 if not found then raise exception 'unauthorized'; end if;
 perform public.igr_v3_tick(p.room_code);
 select * into r from public.igr_v3_rooms where code=p.room_code;
 select x.pack into v_pack from public.igr_v3_scenario_packs x where x.scenario_id=r.scenario_id;
 select coalesce(jsonb_agg(jsonb_build_object('id',id,'pseudo',pseudo,'seat_index',seat_index,'is_host',is_host,'public_role',public_role) order by seat_index),'[]'::jsonb) into players from public.igr_v3_players where room_code=r.code;
 ev:=public.igr_v3_visible_events(r.code,p);
 select coalesce(jsonb_agg(jsonb_build_object('id',id,'pseudo',pseudo) order by seat_index),'[]'::jsonb) into suspects from public.igr_v3_players where room_code=r.code and public_role='suspect';
 return jsonb_build_object('room',jsonb_build_object('code',r.code,'scenario_id',r.scenario_id,'status',r.status,'cycle',r.cycle,'phase',r.phase,'phase_started_at',r.phase_started_at,'phase_ends_at',r.phase_ends_at,'state',r.state,'min_players',public.igr_v3_min_players(r.scenario_id),'max_players',public.igr_v3_max_players(r.scenario_id)),'player',jsonb_build_object('id',p.id,'pseudo',p.pseudo,'is_host',p.is_host,'public_role',p.public_role,'secret_role',case when r.status in ('playing','finished') then p.secret_role else null end,'private_state',case when r.status in ('playing','finished') then p.private_state else '{}'::jsonb end),'players',players,'suspects',suspects,'events',ev,'scenario',jsonb_build_object('context',v_pack->>'context','truth',case when r.status='finished' then v_pack->'truth' else null end,'protected',case when p.public_role='juge' then v_pack->'protected' else '[]'::jsonb end,'field_actions',case when p.public_role='inspecteur' then v_pack->'field_actions' else '[]'::jsonb end,'expert_actions',case when p.public_role='expert' then v_pack->'expert_actions' else '[]'::jsonb end));
end $$;
create or replace function public.igr_v3_start_interrogation(p_code text,p_player_token uuid,p_target uuid) returns jsonb language plpgsql security definer set search_path=public as $$
declare p public.igr_v3_players%rowtype; r public.igr_v3_rooms%rowtype; t public.igr_v3_players%rowtype; prev uuid;
begin
 select * into p from public.igr_v3_players where room_code=upper(trim(p_code)) and player_token=p_player_token; if not found or p.public_role<>'enqueteur' then raise exception 'forbidden'; end if;
 select * into r from public.igr_v3_rooms where code=p.room_code for update; if r.phase<>'interrogation_select' then raise exception 'wrong phase'; end if;
 select * into t from public.igr_v3_players where id=p_target and room_code=r.code and public_role='suspect'; if not found then raise exception 'invalid target'; end if;
 prev:=nullif(r.state->>'previous_target','')::uuid;
 if prev=t.id and (select count(*) from public.igr_v3_players where room_code=r.code and public_role='suspect')>1 then raise exception 'same suspect twice'; end if;
 update public.igr_v3_rooms set phase='interrogation',phase_started_at=now(),phase_ends_at=now()+interval '8 minutes',state=jsonb_set(jsonb_set(state,'{previous_target}',to_jsonb(t.id::text),true),'{current_target}',to_jsonb(t.id::text),true) where code=r.code;
 insert into public.igr_v3_events(room_code,event_type,payload) values(r.code,'interrogation',jsonb_build_object('title','INTERROGATOIRE','text',t.pseudo||' est interrogé pendant 8 minutes.','target_id',t.id));
 return jsonb_build_object('ok',true);
end $$;
create or replace function public.igr_v3_submit_debrief(p_code text,p_player_token uuid,p_convergence int,p_confusion int,p_axis text) returns jsonb language plpgsql security definer set search_path=public as $$
declare p public.igr_v3_players%rowtype; r public.igr_v3_rooms%rowtype;
begin
 select * into p from public.igr_v3_players where room_code=upper(trim(p_code)) and player_token=p_player_token; if not found or p.public_role not in ('enqueteur','analyste') then raise exception 'forbidden'; end if;
 select * into r from public.igr_v3_rooms where code=p.room_code for update; if r.phase<>'debrief' then raise exception 'wrong phase'; end if;
 if exists(select 1 from public.igr_v3_actions where room_code=r.code and player_id=p.id and cycle=r.cycle and action_type='debrief') then raise exception 'already submitted'; end if;
 insert into public.igr_v3_actions(room_code,player_id,cycle,action_type,payload) values(r.code,p.id,r.cycle,'debrief',jsonb_build_object('convergence',greatest(0,least(2,p_convergence)),'confusion',greatest(0,least(2,p_confusion)),'axis',left(p_axis,32)));
 if not exists(select 1 from public.igr_v3_players x where x.room_code=r.code and x.public_role in ('enqueteur','analyste') and not exists(select 1 from public.igr_v3_actions a where a.room_code=r.code and a.player_id=x.id and a.cycle=r.cycle and a.action_type='debrief')) then perform public.igr_v3_emit_trame(r.code); update public.igr_v3_rooms set phase='trame',phase_started_at=now(),phase_ends_at=now()+interval '20 seconds' where code=r.code; end if;
 return jsonb_build_object('ok',true);
end $$;
create or replace function public.igr_v3_publish_breaking(p_code text,p_player_token uuid,p_title text,p_text text) returns jsonb language plpgsql security definer set search_path=public as $$
declare p public.igr_v3_players%rowtype; r public.igr_v3_rooms%rowtype; c int;
begin
 select * into p from public.igr_v3_players where room_code=upper(trim(p_code)) and player_token=p_player_token; if not found or p.public_role<>'journaliste' then raise exception 'forbidden'; end if;
 select * into r from public.igr_v3_rooms where code=p.room_code; if r.status<>'playing' or r.phase in ('provisional','defense','final_debrief','locking') then raise exception 'closed'; end if;
 select count(*) into c from public.igr_v3_actions where room_code=r.code and player_id=p.id and action_type='breaking_news'; if c>=3 then raise exception 'limit reached'; end if;
 if exists(select 1 from public.igr_v3_actions where room_code=r.code and player_id=p.id and cycle=r.cycle and action_type='breaking_news') then raise exception 'cycle limit'; end if;
 insert into public.igr_v3_actions(room_code,player_id,cycle,action_type,payload) values(r.code,p.id,r.cycle,'breaking_news',jsonb_build_object('title',left(trim(p_title),60),'text',left(trim(p_text),180)));
 insert into public.igr_v3_events(room_code,event_type,payload) values(r.code,'breaking_news',jsonb_build_object('title',left(trim(p_title),60),'text',left(trim(p_text),180),'author',p.pseudo));
 return jsonb_build_object('ok',true);
end $$;


-- ============================================================
-- 20260909194611_igr_v3_core_functions_c.sql
-- ============================================================

create or replace function public.igr_v3_special_action(p_code text,p_player_token uuid,p_kind text,p_choice text,p_target uuid default null) returns jsonb language plpgsql security definer set search_path=public as $$
declare p public.igr_v3_players%rowtype; r public.igr_v3_rooms%rowtype; pack jsonb; item jsonb; idx int; n int; maxn int:=1;
begin
 select * into p from public.igr_v3_players where room_code=upper(trim(p_code)) and player_token=p_player_token; if not found then raise exception 'unauthorized'; end if;
 select * into r from public.igr_v3_rooms where code=p.room_code; if r.status<>'playing' or r.phase in ('provisional','defense','final_debrief','locking') then raise exception 'closed'; end if;
 select x.pack into pack from public.igr_v3_scenario_packs x where x.scenario_id=r.scenario_id;
 if p_kind='field' and p.public_role='inspecteur' then item:=null; n:=jsonb_array_length(pack->'field_actions'); for idx in 0..n-1 loop if pack->'field_actions'->idx->>'id'=p_choice then item:=pack->'field_actions'->idx; exit; end if; end loop;
 elsif p_kind='expert' and p.public_role='expert' then item:=null; n:=jsonb_array_length(pack->'expert_actions'); for idx in 0..n-1 loop if pack->'expert_actions'->idx->>'id'=p_choice then item:=pack->'expert_actions'->idx; exit; end if; end loop;
 elsif p_kind='judge' and p.public_role='juge' then item:=null; n:=jsonb_array_length(pack->'protected'); for idx in 0..n-1 loop if pack->'protected'->idx->>'id'=p_choice then item:=pack->'protected'->idx; exit; end if; end loop;
 elsif p_kind='prosecutor' and p.public_role='procureur' then item:=jsonb_build_object('label','Entretien ciblé','result','Le Procureur mène un entretien ciblé de trois minutes. Aucun fait officiel nouveau n’est créé par l’entretien lui-même.'); if r.scenario_id='017' then maxn:=2; end if;
 else raise exception 'forbidden'; end if;
 if item is null then raise exception 'invalid choice'; end if;
 if (select count(*) from public.igr_v3_actions where room_code=r.code and player_id=p.id and cycle=r.cycle and action_type=p_kind)>=maxn then raise exception 'cycle limit'; end if;
 if p_kind='judge' then
   if coalesce((select sum((a.payload->>'cost')::int) from public.igr_v3_actions a where a.room_code=r.code and a.player_id=p.id and a.action_type='judge'),0)+coalesce((item->>'cost')::int,1)>5 then raise exception 'confidentiality gauge'; end if;
   insert into public.igr_v3_actions(room_code,player_id,cycle,action_type,payload) values(r.code,p.id,r.cycle,p_kind,jsonb_build_object('choice',p_choice,'target',p_target,'cost',coalesce((item->>'cost')::int,1)));
 else
   insert into public.igr_v3_actions(room_code,player_id,cycle,action_type,payload) values(r.code,p.id,r.cycle,p_kind,jsonb_build_object('choice',p_choice,'target',p_target));
 end if;
 insert into public.igr_v3_events(room_code,event_type,visibility,target_player_id,payload) values(r.code,p_kind,'private',p.id,jsonb_build_object('title',upper(p_kind),'text',coalesce(item->>'result',item->>'text',item->>'label')));
 return jsonb_build_object('ok',true,'result',coalesce(item->>'result',item->>'text',item->>'label'));
end $$;
create or replace function public.igr_v3_set_provisional(p_code text,p_player_token uuid,p_levels jsonb) returns jsonb language plpgsql security definer set search_path=public as $$
declare p public.igr_v3_players%rowtype; r public.igr_v3_rooms%rowtype; n int;
begin
 select * into p from public.igr_v3_players where room_code=upper(trim(p_code)) and player_token=p_player_token; if not found or p.public_role<>'enqueteur' then raise exception 'forbidden'; end if;
 select * into r from public.igr_v3_rooms where code=p.room_code for update; if r.phase<>'provisional' then raise exception 'wrong phase'; end if;
 insert into public.igr_v3_actions(room_code,player_id,cycle,action_type,payload) values(r.code,p.id,r.cycle,'provisional',p_levels);
 n:=greatest(1,(select count(*) from jsonb_each_text(p_levels) where value::int>=2));
 update public.igr_v3_rooms set phase='defense',phase_started_at=now(),phase_ends_at=now()+(n*interval '5 minutes'),state=jsonb_set(state,'{provisional}',p_levels,true) where code=r.code;
 insert into public.igr_v3_events(room_code,event_type,payload) values(r.code,'phase',jsonb_build_object('title','DERNIÈRES DÉFENSES','text',n||' accusation(s) formelle(s). Environ 5 minutes par personne accusée.'));
 return jsonb_build_object('ok',true);
end $$;
create or replace function public.igr_v3_lock_final(p_code text,p_player_token uuid,p_payload jsonb) returns jsonb language plpgsql security definer set search_path=public as $$
declare p public.igr_v3_players%rowtype; r public.igr_v3_rooms%rowtype; req int; got int; pack jsonb;
begin
 select * into p from public.igr_v3_players where room_code=upper(trim(p_code)) and player_token=p_player_token; if not found or p.public_role not in ('enqueteur','analyste','procureur','juge','journaliste') then raise exception 'forbidden'; end if;
 select * into r from public.igr_v3_rooms where code=p.room_code for update; if r.phase<>'locking' then raise exception 'wrong phase'; end if;
 if exists(select 1 from public.igr_v3_actions where room_code=r.code and player_id=p.id and action_type='final_lock') then raise exception 'already locked'; end if;
 insert into public.igr_v3_actions(room_code,player_id,cycle,action_type,payload) values(r.code,p.id,r.cycle,'final_lock',p_payload);
 select count(*) into req from public.igr_v3_players where room_code=r.code and public_role in ('enqueteur','analyste','procureur','juge','journaliste');
 select count(*) into got from public.igr_v3_actions where room_code=r.code and action_type='final_lock';
 if got>=req then select x.pack into pack from public.igr_v3_scenario_packs x where x.scenario_id=r.scenario_id; update public.igr_v3_rooms set status='finished',phase='reveal',phase_started_at=now(),phase_ends_at=null where code=r.code; insert into public.igr_v3_events(room_code,event_type,payload) values(r.code,'reveal',jsonb_build_object('title','RÉVÉLATION','text',pack->'truth'->>'summary','levels',pack->'truth'->'levels')); end if;
 return jsonb_build_object('ok',true,'locked',got,'required',req);
end $$;
create or replace function public.igr_v3_send_message(p_code text,p_player_token uuid,p_channel text,p_target uuid,p_text text) returns jsonb language plpgsql security definer set search_path=public as $$
declare p public.igr_v3_players%rowtype; target public.igr_v3_players%rowtype; roles text[]:=array['enqueteur','analyste','procureur','juge','inspecteur','expert'];
begin
 select * into p from public.igr_v3_players where room_code=upper(trim(p_code)) and player_token=p_player_token; if not found then raise exception 'unauthorized'; end if;
 if p_channel='investigation' then
   if not (p.public_role=any(roles)) then raise exception 'forbidden'; end if;
   insert into public.igr_v3_events(room_code,event_type,visibility,audience_roles,payload) values(p.room_code,'message','roles',roles,jsonb_build_object('author',p.pseudo,'text',left(trim(p_text),200)));
 elsif p_channel='private' then
   select * into target from public.igr_v3_players where id=p_target and room_code=p.room_code; if not found then raise exception 'invalid target'; end if;
   if p.public_role<>'journaliste' and target.public_role<>'enqueteur' and p.public_role<>'enqueteur' then raise exception 'private messaging restricted'; end if;
   insert into public.igr_v3_events(room_code,event_type,visibility,target_player_id,payload) values(p.room_code,'message','private',target.id,jsonb_build_object('author',p.pseudo,'text',left(trim(p_text),200)));
   insert into public.igr_v3_events(room_code,event_type,visibility,target_player_id,payload) values(p.room_code,'message','private',p.id,jsonb_build_object('author',p.pseudo,'to',target.pseudo,'text',left(trim(p_text),200)));
 else raise exception 'invalid channel'; end if;
 return jsonb_build_object('ok',true);
end $$;
create or replace function public.igr_v3_video_set(p_code text,p_player_token uuid,p_active boolean,p_confidential_cut boolean default false) returns jsonb language plpgsql security definer set search_path=public as $$
declare p public.igr_v3_players%rowtype; r public.igr_v3_rooms%rowtype; newstate jsonb; cut_until timestamptz;
begin
 select * into p from public.igr_v3_players where room_code=upper(trim(p_code)) and player_token=p_player_token; if not found or p.public_role<>'enqueteur' then raise exception 'forbidden'; end if;
 select * into r from public.igr_v3_rooms where code=p.room_code for update;
 if p_confidential_cut then
   if exists(select 1 from public.igr_v3_actions where room_code=r.code and player_id=p.id and cycle=r.cycle and action_type='video_cut') then raise exception 'cycle limit'; end if;
   cut_until:=now()+interval '60 seconds'; insert into public.igr_v3_actions(room_code,player_id,cycle,action_type,payload) values(r.code,p.id,r.cycle,'video_cut','{}');
   newstate:=jsonb_set(jsonb_set(r.state,'{video_active}','false'::jsonb,true),'{video_cut_until}',to_jsonb(cut_until::text),true);
 else newstate:=jsonb_set(r.state,'{video_active}',to_jsonb(p_active),true); if p_active then newstate:=jsonb_set(newstate,'{video_cut_until}','null'::jsonb,true); end if; end if;
 update public.igr_v3_rooms set state=newstate where code=r.code;
 return jsonb_build_object('ok',true,'cut_until',cut_until);
end $$;
create or replace function public.igr_v3_signal_send(p_code text,p_player_token uuid,p_to uuid,p_type text,p_payload jsonb) returns jsonb language plpgsql security definer set search_path=public as $$
declare p public.igr_v3_players%rowtype; t public.igr_v3_players%rowtype; allowed boolean;
begin
 select * into p from public.igr_v3_players where room_code=upper(trim(p_code)) and player_token=p_player_token; if not found then raise exception 'unauthorized'; end if;
 select * into t from public.igr_v3_players where id=p_to and room_code=p.room_code; if not found then raise exception 'invalid target'; end if;
 allowed:=(p.public_role='enqueteur' and t.public_role in ('analyste','procureur','juge','inspecteur')) or (t.public_role='enqueteur' and p.public_role in ('analyste','procureur','juge','inspecteur'));
 if not allowed then raise exception 'forbidden'; end if;
 insert into public.igr_v3_signals(room_code,from_player_id,to_player_id,signal_type,payload) values(p.room_code,p.id,t.id,left(p_type,20),p_payload);
 return jsonb_build_object('ok',true);
end $$;
create or replace function public.igr_v3_signal_poll(p_code text,p_player_token uuid,p_after bigint default 0) returns jsonb language plpgsql security definer set search_path=public as $$
declare p public.igr_v3_players%rowtype;
begin
 select * into p from public.igr_v3_players where room_code=upper(trim(p_code)) and player_token=p_player_token; if not found then raise exception 'unauthorized'; end if;
 return (select coalesce(jsonb_agg(jsonb_build_object('id',id,'from_player_id',from_player_id,'signal_type',signal_type,'payload',payload) order by id),'[]'::jsonb) from public.igr_v3_signals where room_code=p.room_code and to_player_id=p.id and id>p_after);
end $$;
grant execute on function public.igr_v3_create_room(text,text,text) to anon,authenticated;
grant execute on function public.igr_v3_join_room(text,text) to anon,authenticated;
grant execute on function public.igr_v3_sync(text,uuid) to anon,authenticated;
grant execute on function public.igr_v3_start_game(text,uuid) to anon,authenticated;
grant execute on function public.igr_v3_start_interrogation(text,uuid,uuid) to anon,authenticated;
grant execute on function public.igr_v3_submit_debrief(text,uuid,int,int,text) to anon,authenticated;
grant execute on function public.igr_v3_publish_breaking(text,uuid,text,text) to anon,authenticated;
grant execute on function public.igr_v3_special_action(text,uuid,text,text,uuid) to anon,authenticated;
grant execute on function public.igr_v3_set_provisional(text,uuid,jsonb) to anon,authenticated;
grant execute on function public.igr_v3_lock_final(text,uuid,jsonb) to anon,authenticated;
grant execute on function public.igr_v3_send_message(text,uuid,text,uuid,text) to anon,authenticated;
grant execute on function public.igr_v3_video_set(text,uuid,boolean,boolean) to anon,authenticated;
grant execute on function public.igr_v3_signal_send(text,uuid,uuid,text,jsonb) to anon,authenticated;
grant execute on function public.igr_v3_signal_poll(text,uuid,bigint) to anon,authenticated;
