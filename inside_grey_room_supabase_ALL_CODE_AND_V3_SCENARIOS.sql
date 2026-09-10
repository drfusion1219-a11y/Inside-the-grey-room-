

-- ==============================================================================
-- HISTORIQUE DES MIGRATIONS
-- ==============================================================================

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



-- ==============================================================================
-- SCHÉMA V1 ENCORE PRÉSENT
-- ==============================================================================

-- Current legacy V1 tables found in public schema.
-- These objects are not present in supabase_migrations.schema_migrations.

create table public.igr_games (
  room_code text not null,
  host_player_id uuid not null,
  controller_player_id uuid,
  phase text default 'lobby'::text not null,
  current_suspect text,
  trame_index integer default 0 not null,
  active_suspects text[] default array[]::text[] not null,
  result text,
  created_at timestamptz default now() not null,
  timer_end timestamptz,
  constraint igr_games_pkey primary key (room_code)
);

create table public.igr_players (
  id uuid not null,
  room_code text not null,
  name text not null,
  role text,
  joined_at timestamptz default now() not null,
  constraint igr_players_name_check check (char_length(name) >= 1 and char_length(name) <= 24),
  constraint igr_players_pkey primary key (id),
  constraint igr_players_room_code_fkey foreign key (room_code) references public.igr_games(room_code) on delete cascade
);



-- ==============================================================================
-- SCHÉMA V4 ACTUEL
-- ==============================================================================

-- Reconstructed from the CURRENT PostgreSQL catalog on 2026-09-10.
-- V4 is present in the database but is NOT recorded in supabase_migrations.schema_migrations.
-- No rows currently exist in public.igr_v4_scenario_packs.

create extension if not exists pgcrypto;

create table public.igr_v4_scenario_packs (
  scenario_id text not null,
  pack jsonb not null,
  updated_at timestamptz default now() not null,
  constraint igr_v4_scenario_packs_pkey primary key (scenario_id)
);

create table public.igr_v4_rooms (
  code text not null,
  scenario_id text not null,
  status text default 'lobby'::text not null,
  cycle integer default 0 not null,
  phase text default 'lobby'::text not null,
  phase_started_at timestamptz,
  phase_ends_at timestamptz,
  host_token uuid default gen_random_uuid() not null,
  state jsonb default '{}'::jsonb not null,
  created_at timestamptz default now() not null,
  updated_at timestamptz default now() not null,
  constraint igr_v4_rooms_cycle_check check (cycle >= 0 and cycle <= 3),
  constraint igr_v4_rooms_pkey primary key (code),
  constraint igr_v4_rooms_scenario_id_fkey foreign key (scenario_id) references public.igr_v4_scenario_packs(scenario_id),
  constraint igr_v4_rooms_status_check check (status = any (array['lobby'::text,'playing'::text,'finished'::text]))
);

create table public.igr_v4_players (
  id uuid default gen_random_uuid() not null,
  room_code text not null,
  pseudo text not null,
  seat_index integer not null,
  is_host boolean default false not null,
  public_role text default 'en_attente'::text not null,
  secret_role text default 'en_attente'::text not null,
  internal_slot integer,
  player_token uuid default gen_random_uuid() not null,
  private_state jsonb default '{}'::jsonb not null,
  ready boolean default false not null,
  joined_at timestamptz default now() not null,
  constraint igr_v4_players_pkey primary key (id),
  constraint igr_v4_players_room_code_fkey foreign key (room_code) references public.igr_v4_rooms(code) on delete cascade,
  constraint igr_v4_players_room_code_player_token_key unique (room_code,player_token),
  constraint igr_v4_players_room_code_seat_index_key unique (room_code,seat_index)
);

create sequence if not exists public.igr_v4_events_id_seq as bigint start with 1 increment by 1 minvalue 1 no maxvalue no cycle;
create sequence if not exists public.igr_v4_actions_id_seq as bigint start with 1 increment by 1 minvalue 1 no maxvalue no cycle;
create sequence if not exists public.igr_v4_signals_id_seq as bigint start with 1 increment by 1 minvalue 1 no maxvalue no cycle;

create table public.igr_v4_events (
  id bigint default nextval('public.igr_v4_events_id_seq'::regclass) not null,
  room_code text not null,
  event_type text not null,
  visibility text default 'public'::text not null,
  target_player_id uuid,
  audience_roles text[],
  payload jsonb default '{}'::jsonb not null,
  created_at timestamptz default now() not null,
  constraint igr_v4_events_pkey primary key (id),
  constraint igr_v4_events_room_code_fkey foreign key (room_code) references public.igr_v4_rooms(code) on delete cascade,
  constraint igr_v4_events_target_player_id_fkey foreign key (target_player_id) references public.igr_v4_players(id) on delete cascade,
  constraint igr_v4_events_visibility_check check (visibility = any (array['public'::text,'private'::text,'roles'::text]))
);

create table public.igr_v4_actions (
  id bigint default nextval('public.igr_v4_actions_id_seq'::regclass) not null,
  room_code text not null,
  player_id uuid not null,
  cycle integer default 0 not null,
  action_type text not null,
  payload jsonb default '{}'::jsonb not null,
  created_at timestamptz default now() not null,
  constraint igr_v4_actions_pkey primary key (id),
  constraint igr_v4_actions_player_id_fkey foreign key (player_id) references public.igr_v4_players(id) on delete cascade,
  constraint igr_v4_actions_room_code_fkey foreign key (room_code) references public.igr_v4_rooms(code) on delete cascade
);

create table public.igr_v4_signals (
  id bigint default nextval('public.igr_v4_signals_id_seq'::regclass) not null,
  room_code text not null,
  from_player_id uuid not null,
  to_player_id uuid not null,
  signal_type text not null,
  payload jsonb default '{}'::jsonb not null,
  created_at timestamptz default now() not null,
  constraint igr_v4_signals_from_player_id_fkey foreign key (from_player_id) references public.igr_v4_players(id) on delete cascade,
  constraint igr_v4_signals_pkey primary key (id),
  constraint igr_v4_signals_room_code_fkey foreign key (room_code) references public.igr_v4_rooms(code) on delete cascade,
  constraint igr_v4_signals_to_player_id_fkey foreign key (to_player_id) references public.igr_v4_players(id) on delete cascade
);

create index igr_v4_events_room_id_idx on public.igr_v4_events(room_code,id);
create index igr_v4_actions_room_idx on public.igr_v4_actions(room_code,action_type,cycle,player_id);
create index igr_v4_signals_to_idx on public.igr_v4_signals(room_code,to_player_id,id);

alter table public.igr_v4_scenario_packs enable row level security;
alter table public.igr_v4_rooms enable row level security;
alter table public.igr_v4_players enable row level security;
alter table public.igr_v4_events enable row level security;
alter table public.igr_v4_actions enable row level security;
alter table public.igr_v4_signals enable row level security;

revoke all on public.igr_v4_scenario_packs, public.igr_v4_rooms, public.igr_v4_players,
  public.igr_v4_events, public.igr_v4_actions, public.igr_v4_signals
from anon, authenticated;

-- No user-defined triggers are currently present on igr_* tables.
-- No RLS policies are currently present on V4 tables; access is through SECURITY DEFINER RPC functions.



-- ==============================================================================
-- FONCTIONS V4 ACTUELLES
-- ==============================================================================

-- Exact CURRENT function definitions retrieved with pg_get_functiondef on 2026-09-10.
-- These V4 functions are present in the database but are not in supabase_migrations.schema_migrations.

CREATE OR REPLACE FUNCTION public.igr_v4_ack_role(p_code text, p_player_token uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare p public.igr_v4_players%rowtype; r public.igr_v4_rooms%rowtype;
begin
 select * into p from public.igr_v4_players where room_code=upper(trim(p_code)) and player_token=p_player_token; if not found then raise exception 'unauthorized'; end if;
 select * into r from public.igr_v4_rooms where code=p.room_code for update; if r.phase<>'role_reading' then return jsonb_build_object('ok',true); end if;
 update public.igr_v4_players set ready=true where id=p.id;
 if not exists(select 1 from public.igr_v4_players where room_code=r.code and not ready) then update public.igr_v4_rooms set phase='initial_debrief',phase_started_at=now(),phase_ends_at=now()+interval '3 minutes',updated_at=now() where code=r.code; insert into public.igr_v4_events(room_code,event_type,payload) values(r.code,'phase',jsonb_build_object('title','DÉBRIEF INITIAL','text','Toutes les cartes sont lues. Enquêteur + Analyste : 3 minutes.')); end if;
 return jsonb_build_object('ok',true);
end $function$;


CREATE OR REPLACE FUNCTION public.igr_v4_build_annex_queue(p_room text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r public.igr_v4_rooms%rowtype; q jsonb:='[]'::jsonb;
begin
 select * into r from public.igr_v4_rooms where code=p_room;
 if exists(select 1 from public.igr_v4_players where room_code=r.code and public_role='inspecteur') then q:=q||jsonb_build_array(jsonb_build_object('role','inspecteur','seconds',180,'title','ENTRETIEN INSPECTEUR')); end if;
 if exists(select 1 from public.igr_v4_players where room_code=r.code and public_role='procureur') then q:=q||jsonb_build_array(jsonb_build_object('role','procureur','seconds',case when r.scenario_id='017' then 360 else 180 end,'title','ENTRETIEN PROCUREUR')); end if;
 if exists(select 1 from public.igr_v4_players where room_code=r.code and public_role='juge') then q:=q||jsonb_build_array(jsonb_build_object('role','juge','seconds',180,'title','ENTRETIEN JUGE')); end if;
 if exists(select 1 from public.igr_v4_players where room_code=r.code and public_role='temoin') then q:=q||jsonb_build_array(jsonb_build_object('role','temoin','seconds',240,'title','FENÊTRE TÉMOINS')); end if;
 if exists(select 1 from public.igr_v4_players where room_code=r.code and public_role='journaliste') then q:=q||jsonb_build_array(jsonb_build_object('role','journaliste','seconds',180,'title','ENTRETIEN JOURNALISTE')); end if;
 if exists(select 1 from public.igr_v4_players where room_code=r.code and public_role='expert') then q:=q||jsonb_build_array(jsonb_build_object('role','expert','seconds',180,'title','ENTRETIEN EXPERT')); end if;
 return q;
end $function$;


CREATE OR REPLACE FUNCTION public.igr_v4_build_private_card(p_room text, p_player_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare p public.igr_v4_players%rowtype; r public.igr_v4_rooms%rowtype; pack jsonb; base jsonb; rel jsonb; rels jsonb:='[]'::jsonb; q public.igr_v4_players%rowtype; widx int; role_note jsonb; clients jsonb:='[]'::jsonb; lrank int; lcount int;
begin
 select * into p from public.igr_v4_players where id=p_player_id;
 select * into r from public.igr_v4_rooms where code=p.room_code;
 select x.pack into pack from public.igr_v4_scenario_packs x where x.scenario_id=r.scenario_id;
 if p.public_role='suspect' then
   base:=coalesce(pack->'suspects'->greatest(0,p.internal_slot-1),'{}'::jsonb);
   for rel in select value from jsonb_array_elements(coalesce(pack->'relations'->p.internal_slot::text,'[]'::jsonb)) loop
     select * into q from public.igr_v4_players where room_code=r.code and public_role='suspect' and internal_slot=(rel->>'slot')::int;
     if found then rels:=rels||jsonb_build_array(jsonb_build_object('pseudo',q.pseudo,'text',rel->>'text')); end if;
   end loop;
   base:=jsonb_set(base,'{relations}',rels,true);
 else
   base:=public.igr_v4_generic_role_card(p.public_role,pack->>'context');
   role_note:=coalesce(pack->'role_notes'->p.public_role,'{}'::jsonb);
   base:=base||role_note;
   if p.public_role='temoin' then
     select count(*) into widx from public.igr_v4_players w where w.room_code=r.code and w.public_role='temoin' and w.seat_index<=p.seat_index;
     base:=base||coalesce(pack->'witnesses'->greatest(0,widx-1),'{}'::jsonb);
   elsif p.public_role='maitre' then
     select count(*) into lcount from public.igr_v4_players a where a.room_code=r.code and a.public_role='maitre';
     select count(*) into lrank from public.igr_v4_players a where a.room_code=r.code and a.public_role='maitre' and a.seat_index<=p.seat_index;
     for q in select * from public.igr_v4_players s where s.room_code=r.code and s.public_role='suspect' and (lcount=1 or ((s.internal_slot-1)%lcount)=(lrank-1)) order by s.internal_slot loop clients:=clients||to_jsonb(q.pseudo); end loop;
     base:=base||jsonb_build_object('clients',clients);
   end if;
 end if;
 if p.secret_role='espion' then base:=base||jsonb_build_object('secret_mission',coalesce(pack->>'espion_mission','Observe et détourne sans inventer de preuve.')); end if;
 return base;
end $function$;


CREATE OR REPLACE FUNCTION public.igr_v4_cleanup()
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
 delete from public.igr_v4_rooms where updated_at < now()-interval '12 hours'
$function$;


CREATE OR REPLACE FUNCTION public.igr_v4_create_room(p_code text, p_scenario_id text, p_pseudo text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r public.igr_v4_rooms%rowtype; p public.igr_v4_players%rowtype;
begin
 perform public.igr_v4_cleanup();
 if upper(trim(p_code))!~'^[A-Z2-9]{5}$' then raise exception 'invalid room code'; end if;
 if not exists(select 1 from public.igr_v4_scenario_packs where scenario_id=p_scenario_id) then raise exception 'invalid scenario'; end if;
 if length(trim(p_pseudo))<1 then raise exception 'invalid pseudo'; end if;
 insert into public.igr_v4_rooms(code,scenario_id) values(upper(trim(p_code)),p_scenario_id) returning * into r;
 insert into public.igr_v4_players(room_code,pseudo,seat_index,is_host) values(r.code,left(trim(p_pseudo),22),0,true) returning * into p;
 insert into public.igr_v4_events(room_code,event_type,payload) values(r.code,'room_created',jsonb_build_object('title','CELLULE OUVERTE','text','La cellule est prête.'));
 return jsonb_build_object('room_code',r.code,'player_id',p.id,'player_token',p.player_token,'host_token',r.host_token);
end $function$;


CREATE OR REPLACE FUNCTION public.igr_v4_emit_trame(p_room text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r public.igr_v4_rooms%rowtype; pack jsonb; used jsonb; wanted text:='balanced'; tr jsonb; idx int; n int; conv numeric; conf numeric; strong int;
begin
 select * into r from public.igr_v4_rooms where code=p_room for update;
 select x.pack into pack from public.igr_v4_scenario_packs x where x.scenario_id=r.scenario_id;
 used:=coalesce(r.state->'used_trames','{}'::jsonb);
 select avg(coalesce((payload->>'convergence')::int,1)),avg(coalesce((payload->>'confusion')::int,1)) into conv,conf
 from public.igr_v4_actions where room_code=r.code and cycle=r.cycle and action_type='debrief';
 select count(*) into strong from public.igr_v4_actions where room_code=r.code and cycle=r.cycle and action_type in ('field','expert','judge');
 if coalesce(conf,1)>=1.5 then wanted:='clarity'; elsif coalesce(conv,1)>=1.5 or strong>0 then wanted:='ambiguity'; else wanted:='balanced'; end if;
 n:=jsonb_array_length(coalesce(pack->'trames','[]'::jsonb)); tr:=null;
 for idx in 0..greatest(n-1,0) loop
   if n=0 then exit; end if;
   if coalesce((pack->'trames'->idx->>'min_cycle')::int,1)<=r.cycle and not (used ? idx::text) and pack->'trames'->idx->>'kind'=wanted then tr:=pack->'trames'->idx; exit; end if;
 end loop;
 if tr is null then
  for idx in 0..greatest(n-1,0) loop
   if n=0 then exit; end if;
   if coalesce((pack->'trames'->idx->>'min_cycle')::int,1)<=r.cycle and not (used ? idx::text) then tr:=pack->'trames'->idx; exit; end if;
  end loop;
 end if;
 if tr is null then return; end if;
 used:=used||jsonb_build_object(idx::text,true);
 update public.igr_v4_rooms set state=jsonb_set(state,'{used_trames}',used,true),updated_at=now() where code=r.code;
 insert into public.igr_v4_events(room_code,event_type,payload) values(r.code,'trame',jsonb_build_object('title',tr->>'title','text',tr->>'text','cycle',r.cycle));
end $function$;


CREATE OR REPLACE FUNCTION public.igr_v4_end_interrogation(p_code text, p_player_token uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare p public.igr_v4_players%rowtype; r public.igr_v4_rooms%rowtype;
begin
 select * into p from public.igr_v4_players where room_code=upper(trim(p_code)) and player_token=p_player_token; if not found or p.public_role<>'enqueteur' then raise exception 'forbidden'; end if;
 select * into r from public.igr_v4_rooms where code=p.room_code for update; if r.phase<>'interrogation' then raise exception 'wrong phase'; end if;
 update public.igr_v4_rooms set phase_ends_at=now() where code=r.code; perform public.igr_v4_tick(r.code); return jsonb_build_object('ok',true);
end $function$;


CREATE OR REPLACE FUNCTION public.igr_v4_generic_role_card(p_role text, p_context text)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO 'public'
AS $function$
begin
 case p_role
  when 'enqueteur' then return jsonb_build_object('place','Tu diriges l’enquête et les interrogatoires.','chronology',p_context,'hide','Aucun fait : tu ne dois jamais inventer une preuve.','anchors','Croise chronologie, accès, objets, contradictions et réactions. Le stress seul ne prouve rien.','position','Tu construis les accusations provisoires puis ton verdict final.');
  when 'analyste' then return jsonb_build_object('place','Tu es le profiler silencieux de l’enquête.','chronology',p_context,'hide','Tes notes et hypothèses restent privées jusqu’aux débriefs.','anchors','Observe cohérence, changements de récit, évitements et stratégies de défense. Une réaction n’est jamais une preuve.','position','Pendant les interrogatoires tu observes. Pendant les débriefs tu aides le MJ autonome à calibrer la prochaine trame.');
  when 'procureur' then return jsonb_build_object('place','Tu portes l’accusation sans être supérieur à l’Enquêteur.','chronology',p_context,'hide','Tes priorités d’entretien et accords sont stratégiques.','anchors','Un entretien réussi par cycle ; dossier 017 : jusqu’à deux avec deux personnes différentes.','position','Poursuis la responsabilité démontrable, pas le visage le plus suspect.');
  when 'juge' then return jsonb_build_object('place','Tu arbitres les informations protégées et la conséquence judiciaire finale.','chronology',p_context,'hide','Tu disposes de 5 points de confidentialité.','anchors','Une information protégée coûte 1 point en règle générale, 2 exceptionnellement. Refuser ne rend jamais le dossier insoluble.','position','Tu ne donnes pas d’opinion orale avant les dernières défenses.');
  when 'journaliste' then return jsonb_build_object('place','Tu es indépendant des camps judiciaires.','chronology',p_context,'hide','Tes sources et ton angle éditorial t’appartiennent.','anchors','Une Breaking News maximum par cycle, trois au total. Les contenus officiels proposés par l’application restent canoniques.','position','Tu peux mettre la pression sans transformer une publication en verdict.');
  when 'inspecteur' then return jsonb_build_object('place','Tu es l’acteur de terrain.','chronology',p_context,'hide','Tes priorités de recherche sont privées jusqu’au résultat.','anchors','Une action de terrain par cycle. Une mauvaise priorité peut consommer ton action.','position','Tu établis où chercher ; l’Expert établit ce qu’une trace permet de conclure.');
  when 'expert' then return jsonb_build_object('place','Tu es l’Expert / médecin légiste.','chronology',p_context,'hide','Tes priorités d’analyse sont privées.','anchors','Une analyse complémentaire par cycle parmi les options matériellement possibles.','position','Tu établis un fait technique, jamais un coupable.');
  when 'temoin' then return jsonb_build_object('place','Tu es un témoin du dossier.','chronology',p_context,'hide','Tu peux protéger un élément personnel tant qu’il ne modifie pas le canon.','anchors','La fenêtre témoins est commune : 4 minutes par cycle, partagée s’il y a deux témoins.','position','Réponds uniquement à partir de ce que tu sais réellement.');
  when 'maitre' then return jsonb_build_object('place','Tu es Avocat dans l’interface publique et Maître pendant la partie.','chronology',p_context,'hide','Tu ne connais pas automatiquement les secrets de tes clients.','anchors','Tu peux défendre plusieurs clients compatibles et tu partages leur temps de défense finale.','position','Protège le degré exact de responsabilité de tes clients, pas une innocence fictive.');
  else return jsonb_build_object('place',p_role,'chronology',p_context,'hide','','anchors','','position','');
 end case;
end $function$;


CREATE OR REPLACE FUNCTION public.igr_v4_join_room(p_code text, p_pseudo text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r public.igr_v4_rooms%rowtype; p public.igr_v4_players%rowtype; c int; s int;
begin
 if length(trim(p_pseudo))<1 then raise exception 'invalid pseudo'; end if;
 select * into r from public.igr_v4_rooms where code=upper(trim(p_code)) for update;
 if not found then raise exception 'room not found'; end if;
 if r.status<>'lobby' then raise exception 'already started'; end if;
 select count(*),coalesce(max(seat_index),-1)+1 into c,s from public.igr_v4_players where room_code=r.code;
 if c>=public.igr_v4_max_players(r.scenario_id) then raise exception 'room full'; end if;
 if exists(select 1 from public.igr_v4_players where room_code=r.code and lower(pseudo)=lower(trim(p_pseudo))) then raise exception 'pseudo already used'; end if;
 insert into public.igr_v4_players(room_code,pseudo,seat_index) values(r.code,left(trim(p_pseudo),22),s) returning * into p;
 update public.igr_v4_rooms set updated_at=now() where code=r.code;
 insert into public.igr_v4_events(room_code,event_type,payload) values(r.code,'player_joined',jsonb_build_object('title','ARRIVÉE','text',p.pseudo||' a rejoint la cellule.'));
 return jsonb_build_object('room_code',r.code,'player_id',p.id,'player_token',p.player_token);
end $function$;


CREATE OR REPLACE FUNCTION public.igr_v4_lock_final(p_code text, p_player_token uuid, p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare p public.igr_v4_players%rowtype; r public.igr_v4_rooms%rowtype; req int; got int; reveal jsonb;
begin
 select * into p from public.igr_v4_players where room_code=upper(trim(p_code)) and player_token=p_player_token; if not found or p.public_role not in ('enqueteur','analyste','procureur','juge','journaliste') then raise exception 'forbidden'; end if;
 select * into r from public.igr_v4_rooms where code=p.room_code for update; if r.phase<>'locking' then raise exception 'wrong phase'; end if;
 if exists(select 1 from public.igr_v4_actions where room_code=r.code and player_id=p.id and action_type='final_lock') then raise exception 'already locked'; end if;
 insert into public.igr_v4_actions(room_code,player_id,cycle,action_type,payload) values(r.code,p.id,r.cycle,'final_lock',p_payload);
 select count(*) into req from public.igr_v4_players where room_code=r.code and public_role in ('enqueteur','analyste','procureur','juge','journaliste');
 select count(*) into got from public.igr_v4_actions where room_code=r.code and action_type='final_lock';
 if got>=req then reveal:=public.igr_v4_make_reveal(r.code); update public.igr_v4_rooms set status='finished',phase='reveal',phase_started_at=now(),phase_ends_at=null,updated_at=now() where code=r.code; insert into public.igr_v4_events(room_code,event_type,payload) values(r.code,'reveal',reveal); end if;
 return jsonb_build_object('ok',true,'locked',got,'required',req);
end $function$;


CREATE OR REPLACE FUNCTION public.igr_v4_make_reveal(p_room text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r public.igr_v4_rooms%rowtype; pack jsonb; s public.igr_v4_players%rowtype; truth_levels jsonb; enq public.igr_v4_players%rowtype; enq_payload jsonb:='{}'::jsonb; resp jsonb:='[]'::jsonb; truth int; guess int; exact int:=0; total int:=0; results jsonb:='[]'::jsonb; p public.igr_v4_players%rowtype; pa jsonb;
begin
 select * into r from public.igr_v4_rooms where code=p_room; select x.pack into pack from public.igr_v4_scenario_packs x where x.scenario_id=r.scenario_id; truth_levels:=pack->'truth'->'levels';
 select * into enq from public.igr_v4_players where room_code=r.code and public_role='enqueteur' limit 1;
 select payload into enq_payload from public.igr_v4_actions where room_code=r.code and player_id=enq.id and action_type='final_lock' order by id desc limit 1;
 enq_payload:=coalesce(enq_payload->'levels',enq_payload,'{}'::jsonb);
 for s in select * from public.igr_v4_players where room_code=r.code and public_role='suspect' order by internal_slot loop
   truth:=coalesce((truth_levels->>(s.internal_slot-1))::int,0); guess:=coalesce((enq_payload->>s.id::text)::int,-1); total:=total+1; if guess=truth then exact:=exact+1; end if;
   resp:=resp||jsonb_build_array(jsonb_build_object('player_id',s.id,'pseudo',s.pseudo,'truth_level',truth,'enqueteur_level',guess));
 end loop;
 for p in select * from public.igr_v4_players where room_code=r.code order by seat_index loop
   if p.public_role='suspect' then select coalesce((truth_levels->>(p.internal_slot-1))::int,0) into truth; guess:=coalesce((enq_payload->>p.id::text)::int,-1); results:=results||jsonb_build_array(jsonb_build_object('pseudo',p.pseudo,'role','suspect','success',guess=truth,'text',case when guess=truth then 'Ta responsabilité a été reconstruite exactement.' else 'L’enquête a déformé ou manqué ta responsabilité réelle.' end));
   elsif p.public_role in ('enqueteur','analyste','procureur','juge') then select payload into pa from public.igr_v4_actions where room_code=r.code and player_id=p.id and action_type='final_lock' order by id desc limit 1; results:=results||jsonb_build_array(jsonb_build_object('pseudo',p.pseudo,'role',p.public_role,'success',case when p.public_role='enqueteur' then exact=total else true end,'text',case when p.public_role='enqueteur' then exact||'/'||total||' responsabilités exactes.' else 'Ton verrouillage final est conservé dans le dossier.' end));
   elsif p.public_role='journaliste' then results:=results||jsonb_build_array(jsonb_build_object('pseudo',p.pseudo,'role','journaliste','success',true,'text','Ton choix éditorial final est révélé séparément du verdict judiciaire.'));
   else results:=results||jsonb_build_array(jsonb_build_object('pseudo',p.pseudo,'role',p.public_role,'success',true,'text','Ton rôle a contribué à la reconstruction sans verdict de culpabilité propre.')); end if;
 end loop;
 return jsonb_build_object('title','RÉVÉLATION','summary',pack->'truth'->>'summary','responsibilities',resp,'results',results,'accuracy',jsonb_build_object('exact',exact,'total',total));
end $function$;


CREATE OR REPLACE FUNCTION public.igr_v4_max_players(p_scenario text)
 RETURNS integer
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public'
AS $function$
 select case when p_scenario in ('001','003','004','005','006') then 5
 when p_scenario='002' then 6
 when p_scenario in ('007','008','009','010','011','012') then 5
 when p_scenario in ('013','014') then 6 when p_scenario='015' then 7 when p_scenario='016' then 8
 when p_scenario='017' then 8 when p_scenario='018' then 6 when p_scenario='019' then 9 when p_scenario='020' then 16 else 5 end
$function$;


CREATE OR REPLACE FUNCTION public.igr_v4_min_players(p_scenario text)
 RETURNS integer
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public'
AS $function$
 select case when p_scenario in ('001','003','004','005','006') then 4
 when p_scenario='002' then 5
 when p_scenario in ('007','008','009','010','011','012','013','014','015','016') then 5
 when p_scenario='017' then 7 when p_scenario='018' then 6 when p_scenario='019' then 9 when p_scenario='020' then 13 else 5 end
$function$;


CREATE OR REPLACE FUNCTION public.igr_v4_prosecutor_request(p_code text, p_player_token uuid, p_target uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare p public.igr_v4_players%rowtype; t public.igr_v4_players%rowtype; r public.igr_v4_rooms%rowtype; successes int; maxn int; rid bigint;
begin
 select * into p from public.igr_v4_players where room_code=upper(trim(p_code)) and player_token=p_player_token; if not found or p.public_role<>'procureur' then raise exception 'forbidden'; end if;
 select * into r from public.igr_v4_rooms where code=p.room_code; if r.phase<>'annex_procureur' then raise exception 'wrong phase'; end if;
 select * into t from public.igr_v4_players where room_code=r.code and id=p_target and id<>p.id; if not found then raise exception 'invalid target'; end if;
 maxn:=case when r.scenario_id='017' then 2 else 1 end;
 select count(*) into successes from public.igr_v4_actions where room_code=r.code and player_id=p.id and cycle=r.cycle and action_type='prosecutor_success'; if successes>=maxn then raise exception 'cycle limit'; end if;
 if exists(select 1 from public.igr_v4_actions where room_code=r.code and player_id=p.id and cycle=r.cycle and action_type='prosecutor_request' and coalesce(payload->>'status','pending')='pending') then raise exception 'request pending'; end if;
 insert into public.igr_v4_actions(room_code,player_id,cycle,action_type,payload) values(r.code,p.id,r.cycle,'prosecutor_request',jsonb_build_object('target',t.id,'target_pseudo',t.pseudo,'status','pending')) returning id into rid;
 insert into public.igr_v4_events(room_code,event_type,visibility,target_player_id,payload) values(r.code,'prosecutor_request','private',t.id,jsonb_build_object('title','DEMANDE DU PROCUREUR','text','Le Procureur demande un entretien ciblé de 3 minutes.','request_id',rid));
 insert into public.igr_v4_events(room_code,event_type,visibility,target_player_id,payload) values(r.code,'prosecutor_request','private',p.id,jsonb_build_object('title','DEMANDE ENVOYÉE','text','Demande adressée à '||t.pseudo||'.','request_id',rid));
 return jsonb_build_object('ok',true,'request_id',rid);
end $function$;


CREATE OR REPLACE FUNCTION public.igr_v4_prosecutor_respond(p_code text, p_player_token uuid, p_request_id bigint, p_accept boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare p public.igr_v4_players%rowtype; a public.igr_v4_actions%rowtype; proc public.igr_v4_players%rowtype; r public.igr_v4_rooms%rowtype;
begin
 select * into p from public.igr_v4_players where room_code=upper(trim(p_code)) and player_token=p_player_token; if not found then raise exception 'unauthorized'; end if;
 select * into a from public.igr_v4_actions where id=p_request_id and room_code=p.room_code and action_type='prosecutor_request' for update; if not found or a.payload->>'target'<>p.id::text or coalesce(a.payload->>'status','pending')<>'pending' then raise exception 'invalid request'; end if;
 select * into r from public.igr_v4_rooms where code=p.room_code; select * into proc from public.igr_v4_players where id=a.player_id;
 update public.igr_v4_actions set payload=jsonb_set(payload,'{status}',to_jsonb(case when p_accept then 'accepted' else 'refused' end),true) where id=a.id;
 if p_accept then insert into public.igr_v4_actions(room_code,player_id,cycle,action_type,payload) values(r.code,proc.id,r.cycle,'prosecutor_success',jsonb_build_object('target',p.id,'target_pseudo',p.pseudo)); end if;
 insert into public.igr_v4_events(room_code,event_type,visibility,target_player_id,payload) values(r.code,'prosecutor_response','private',proc.id,jsonb_build_object('title',case when p_accept then 'ENTRETIEN ACCEPTÉ' else 'ENTRETIEN REFUSÉ' end,'text',p.pseudo||case when p_accept then ' accepte l’entretien.' else ' refuse l’entretien. La tentative ne consomme pas le quota réussi.' end));
 return jsonb_build_object('ok',true);
end $function$;


CREATE OR REPLACE FUNCTION public.igr_v4_publish_breaking(p_code text, p_player_token uuid, p_choice text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare p public.igr_v4_players%rowtype; r public.igr_v4_rooms%rowtype; pack jsonb; item jsonb; idx int; n int; used jsonb; total int;
begin
 select * into p from public.igr_v4_players where room_code=upper(trim(p_code)) and player_token=p_player_token; if not found or p.public_role<>'journaliste' then raise exception 'forbidden'; end if;
 select * into r from public.igr_v4_rooms where code=p.room_code for update; if r.status<>'playing' or r.phase in ('role_reading','initial_debrief','trame','closed','provisional_orals','provisional_lock','defense','final_debrief','locking') then raise exception 'closed'; end if;
 if exists(select 1 from public.igr_v4_actions where room_code=r.code and player_id=p.id and cycle=r.cycle and action_type='breaking_news') then raise exception 'cycle limit'; end if;
 select count(*) into total from public.igr_v4_actions where room_code=r.code and player_id=p.id and action_type='breaking_news'; if total>=3 then raise exception 'limit reached'; end if;
 select x.pack into pack from public.igr_v4_scenario_packs x where x.scenario_id=r.scenario_id; n:=jsonb_array_length(coalesce(pack->'news','[]'::jsonb)); item:=null;
 for idx in 0..greatest(n-1,0) loop if n>0 and pack->'news'->idx->>'id'=p_choice then item:=pack->'news'->idx; exit; end if; end loop; if item is null then raise exception 'invalid choice'; end if;
 used:=coalesce(r.state->'used_news','{}'::jsonb); if used ? p_choice then raise exception 'already published'; end if; used:=used||jsonb_build_object(p_choice,true);
 insert into public.igr_v4_actions(room_code,player_id,cycle,action_type,payload) values(r.code,p.id,r.cycle,'breaking_news',jsonb_build_object('choice',p_choice));
 update public.igr_v4_rooms set state=jsonb_set(state,'{used_news}',used,true),updated_at=now() where code=r.code;
 insert into public.igr_v4_events(room_code,event_type,payload) values(r.code,'breaking_news',jsonb_build_object('title','‼️ BREAKING NEWS — '||coalesce(item->>'title','PUBLICATION'),'text',item->>'text','author',p.pseudo));
 return jsonb_build_object('ok',true);
end $function$;


CREATE OR REPLACE FUNCTION public.igr_v4_role_for_seat(p_scenario text, p_seat integer, p_count integer)
 RETURNS text
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO 'public'
AS $function$
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
end $function$;


CREATE OR REPLACE FUNCTION public.igr_v4_send_message(p_code text, p_player_token uuid, p_channel text, p_target uuid, p_text text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare p public.igr_v4_players%rowtype; t public.igr_v4_players%rowtype; roles text[]:=array['enqueteur','analyste','procureur','juge','inspecteur','expert'];
begin
 select * into p from public.igr_v4_players where room_code=upper(trim(p_code)) and player_token=p_player_token; if not found then raise exception 'unauthorized'; end if;
 if length(trim(p_text))<1 then raise exception 'empty'; end if;
 if p_channel='investigation' then
   if not (p.public_role=any(roles)) then raise exception 'forbidden'; end if;
   insert into public.igr_v4_events(room_code,event_type,visibility,audience_roles,payload) values(p.room_code,'message','roles',roles,jsonb_build_object('author',p.pseudo,'text',left(trim(p_text),200),'channel','investigation'));
 elsif p_channel='private' then
   select * into t from public.igr_v4_players where id=p_target and room_code=p.room_code; if not found then raise exception 'invalid target'; end if;
   if p.public_role<>'journaliste' and t.public_role<>'enqueteur' and p.public_role<>'enqueteur' then raise exception 'private messaging restricted'; end if;
   insert into public.igr_v4_events(room_code,event_type,visibility,target_player_id,payload) values(p.room_code,'message','private',t.id,jsonb_build_object('author',p.pseudo,'text',left(trim(p_text),200),'channel','private'));
   insert into public.igr_v4_events(room_code,event_type,visibility,target_player_id,payload) values(p.room_code,'message','private',p.id,jsonb_build_object('author',p.pseudo,'to',t.pseudo,'text',left(trim(p_text),200),'channel','private'));
 else raise exception 'invalid channel'; end if;
 return jsonb_build_object('ok',true);
end $function$;


CREATE OR REPLACE FUNCTION public.igr_v4_set_provisional(p_code text, p_player_token uuid, p_levels jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare p public.igr_v4_players%rowtype; r public.igr_v4_rooms%rowtype; s public.igr_v4_players%rowtype; level int; q jsonb:='[]'::jsonb;
begin
 select * into p from public.igr_v4_players where room_code=upper(trim(p_code)) and player_token=p_player_token; if not found or p.public_role<>'enqueteur' then raise exception 'forbidden'; end if;
 select * into r from public.igr_v4_rooms where code=p.room_code for update; if r.phase<>'provisional_lock' then raise exception 'wrong phase'; end if;
 for s in select * from public.igr_v4_players where room_code=r.code and public_role='suspect' order by seat_index loop
   if not (p_levels ? s.id::text) then raise exception 'missing suspect'; end if; level:=greatest(0,least(3,(p_levels->>s.id::text)::int)); if level>=2 then q:=q||jsonb_build_array(jsonb_build_object('id',s.id,'pseudo',s.pseudo,'level',level)); end if;
 end loop;
 insert into public.igr_v4_actions(room_code,player_id,cycle,action_type,payload) values(r.code,p.id,r.cycle,'provisional',p_levels);
 update public.igr_v4_rooms set state=jsonb_set(jsonb_set(jsonb_set(state,'{provisional}',p_levels,true),'{defense_queue}',q,true),'{defense_index}','0'::jsonb,true),updated_at=now() where code=r.code;
 if jsonb_array_length(q)>0 then update public.igr_v4_rooms set phase='defense',phase_started_at=now(),phase_ends_at=now()+interval '5 minutes' where code=r.code; insert into public.igr_v4_events(room_code,event_type,payload) values(r.code,'phase',jsonb_build_object('title','DERNIÈRES DÉFENSES','text',(q->0->>'pseudo')||' dispose de 5 minutes.'));
 else update public.igr_v4_rooms set phase='final_debrief',phase_started_at=now(),phase_ends_at=now()+interval '3 minutes' where code=r.code; insert into public.igr_v4_events(room_code,event_type,payload) values(r.code,'phase',jsonb_build_object('title','AUCUNE ACCUSATION FORMELLE','text','Passage au dernier débrief : 3 minutes.')); end if;
 return jsonb_build_object('ok',true,'accused',jsonb_array_length(q));
end $function$;


CREATE OR REPLACE FUNCTION public.igr_v4_signal_poll(p_code text, p_player_token uuid, p_after bigint DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare p public.igr_v4_players%rowtype;
begin
 select * into p from public.igr_v4_players where room_code=upper(trim(p_code)) and player_token=p_player_token; if not found then raise exception 'unauthorized'; end if;
 return (select coalesce(jsonb_agg(jsonb_build_object('id',id,'from_player_id',from_player_id,'signal_type',signal_type,'payload',payload) order by id),'[]'::jsonb) from public.igr_v4_signals where room_code=p.room_code and to_player_id=p.id and id>p_after);
end $function$;


CREATE OR REPLACE FUNCTION public.igr_v4_signal_send(p_code text, p_player_token uuid, p_to uuid, p_type text, p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare p public.igr_v4_players%rowtype; t public.igr_v4_players%rowtype; allowed boolean; eligible text[]:=array['analyste','procureur','juge','inspecteur'];
begin
 select * into p from public.igr_v4_players where room_code=upper(trim(p_code)) and player_token=p_player_token; if not found then raise exception 'unauthorized'; end if;
 select * into t from public.igr_v4_players where id=p_to and room_code=p.room_code; if not found then raise exception 'invalid target'; end if;
 allowed:=(p.public_role='enqueteur' and t.public_role=any(eligible)) or (t.public_role='enqueteur' and p.public_role=any(eligible)); if not allowed then raise exception 'forbidden'; end if;
 if p_type not in ('viewer_ready','offer','answer','ice','hangup') then raise exception 'invalid signal'; end if;
 insert into public.igr_v4_signals(room_code,from_player_id,to_player_id,signal_type,payload) values(p.room_code,p.id,t.id,p_type,p_payload);
 return jsonb_build_object('ok',true);
end $function$;


CREATE OR REPLACE FUNCTION public.igr_v4_special_action(p_code text, p_player_token uuid, p_kind text, p_choice text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare p public.igr_v4_players%rowtype; r public.igr_v4_rooms%rowtype; pack jsonb; item jsonb; idx int; n int; expected text;
begin
 select * into p from public.igr_v4_players where room_code=upper(trim(p_code)) and player_token=p_player_token; if not found then raise exception 'unauthorized'; end if;
 select * into r from public.igr_v4_rooms where code=p.room_code for update; if r.status<>'playing' then raise exception 'closed'; end if;
 select x.pack into pack from public.igr_v4_scenario_packs x where x.scenario_id=r.scenario_id;
 if p_kind='field' and p.public_role='inspecteur' then expected:='annex_inspecteur'; n:=jsonb_array_length(coalesce(pack->'field_actions','[]'::jsonb));
 elsif p_kind='expert' and p.public_role='expert' then expected:='annex_expert'; n:=jsonb_array_length(coalesce(pack->'expert_actions','[]'::jsonb));
 elsif p_kind='judge' and p.public_role='juge' then expected:='annex_juge'; n:=jsonb_array_length(coalesce(pack->'protected','[]'::jsonb));
 else raise exception 'forbidden'; end if;
 if r.phase<>expected then raise exception 'wrong phase'; end if;
 item:=null; for idx in 0..greatest(n-1,0) loop if n>0 and coalesce((case p_kind when 'field' then pack->'field_actions' when 'expert' then pack->'expert_actions' else pack->'protected' end)->idx->>'id','')=p_choice then item:=(case p_kind when 'field' then pack->'field_actions' when 'expert' then pack->'expert_actions' else pack->'protected' end)->idx; exit; end if; end loop;
 if item is null then raise exception 'invalid choice'; end if;
 if p_kind in ('field','expert') and exists(select 1 from public.igr_v4_actions where room_code=r.code and player_id=p.id and cycle=r.cycle and action_type=p_kind) then raise exception 'cycle limit'; end if;
 if p_kind='judge' and coalesce((select sum(coalesce((a.payload->>'cost')::int,0)) from public.igr_v4_actions a where a.room_code=r.code and a.player_id=p.id and a.action_type='judge'),0)+coalesce((item->>'cost')::int,1)>5 then raise exception 'confidentiality gauge'; end if;
 insert into public.igr_v4_actions(room_code,player_id,cycle,action_type,payload) values(r.code,p.id,r.cycle,p_kind,jsonb_build_object('choice',p_choice,'cost',coalesce((item->>'cost')::int,0)));
 insert into public.igr_v4_events(room_code,event_type,visibility,target_player_id,payload) values(r.code,p_kind,'private',p.id,jsonb_build_object('title',coalesce(item->>'title',upper(p_kind)),'text',coalesce(item->>'result',item->>'text','Résultat indisponible.')));
 return jsonb_build_object('ok',true,'result',coalesce(item->>'result',item->>'text'));
end $function$;


CREATE OR REPLACE FUNCTION public.igr_v4_start_cycle(p_room text, p_cycle integer)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
 update public.igr_v4_rooms set cycle=p_cycle,phase='interrogation_select',phase_started_at=now(),phase_ends_at=null,
 state=jsonb_set(jsonb_set(jsonb_set(state,'{heard}','[]'::jsonb,true),'{annex_queue}','[]'::jsonb,true),'{annex_index}','0'::jsonb,true),updated_at=now() where code=p_room;
 insert into public.igr_v4_events(room_code,event_type,payload) values(p_room,'cycle',jsonb_build_object('title','CYCLE '||p_cycle,'text','Chaque suspect peut être interrogé une fois pendant ce cycle. Le MJ reste autonome.'));
end $function$;


CREATE OR REPLACE FUNCTION public.igr_v4_start_game(p_code text, p_host_token uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r public.igr_v4_rooms%rowtype; c int; p public.igr_v4_players%rowtype; role text; sus_ids uuid[]:=array[]::uuid[]; spy_pos int; spy_id uuid;
begin
 select * into r from public.igr_v4_rooms where code=upper(trim(p_code)) and host_token=p_host_token for update;
 if not found then raise exception 'unauthorized'; end if; if r.status<>'lobby' then raise exception 'already started'; end if;
 select count(*) into c from public.igr_v4_players where room_code=r.code;
 if c<public.igr_v4_min_players(r.scenario_id) then raise exception 'not enough players'; end if;
 for p in select * from public.igr_v4_players where room_code=r.code order by seat_index loop role:=public.igr_v4_role_for_seat(r.scenario_id,p.seat_index,c); update public.igr_v4_players set public_role=role,secret_role=role,ready=false where id=p.id; end loop;
 with ranked as (select id,row_number() over(order by md5(r.code||id::text))::int slot from public.igr_v4_players where room_code=r.code and public_role='suspect') update public.igr_v4_players x set internal_slot=ranked.slot from ranked where x.id=ranked.id;
 select array_agg(id order by internal_slot) into sus_ids from public.igr_v4_players where room_code=r.code and public_role='suspect';
 if r.scenario_id in ('013','014','016','019','020') and array_length(sus_ids,1)>0 then spy_pos:=1+(abs(hashtext(r.code))%array_length(sus_ids,1)); spy_id:=sus_ids[spy_pos]; update public.igr_v4_players set secret_role='espion' where id=spy_id; end if;
 for p in select * from public.igr_v4_players where room_code=r.code loop update public.igr_v4_players set private_state=public.igr_v4_build_private_card(r.code,p.id) where id=p.id; end loop;
 update public.igr_v4_rooms set status='playing',cycle=0,phase='role_reading',phase_started_at=now(),phase_ends_at=now()+interval '5 minutes',state=jsonb_build_object('heard','[]'::jsonb,'used_trames','{}'::jsonb,'used_news','{}'::jsonb,'annex_queue','[]'::jsonb,'annex_index',0,'video_active',false,'video_cut_until',null),updated_at=now() where code=r.code;
 insert into public.igr_v4_events(room_code,event_type,payload) select r.code,'context',jsonb_build_object('title','CONTEXTE','text',x.pack->>'context') from public.igr_v4_scenario_packs x where x.scenario_id=r.scenario_id;
 insert into public.igr_v4_events(room_code,event_type,payload) values(r.code,'roles_distributed',jsonb_build_object('title','OUVERTURE DU DOSSIER','text','Cartes privées distribuées. Lecture individuelle : 5 minutes.'));
 return jsonb_build_object('ok',true);
end $function$;


CREATE OR REPLACE FUNCTION public.igr_v4_start_interrogation(p_code text, p_player_token uuid, p_target uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare p public.igr_v4_players%rowtype; r public.igr_v4_rooms%rowtype; t public.igr_v4_players%rowtype; heard jsonb;
begin
 select * into p from public.igr_v4_players where room_code=upper(trim(p_code)) and player_token=p_player_token; if not found or p.public_role<>'enqueteur' then raise exception 'forbidden'; end if;
 select * into r from public.igr_v4_rooms where code=p.room_code for update; perform public.igr_v4_tick(r.code); select * into r from public.igr_v4_rooms where code=p.room_code for update;
 if r.phase<>'interrogation_select' then raise exception 'wrong phase'; end if;
 select * into t from public.igr_v4_players where id=p_target and room_code=r.code and public_role='suspect'; if not found then raise exception 'invalid target'; end if;
 heard:=coalesce(r.state->'heard','[]'::jsonb); if heard ? t.id::text then raise exception 'already heard this cycle'; end if;
 update public.igr_v4_rooms set phase='interrogation',phase_started_at=now(),phase_ends_at=now()+interval '8 minutes',state=jsonb_set(state,'{current_target}',to_jsonb(t.id::text),true),updated_at=now() where code=r.code;
 insert into public.igr_v4_events(room_code,event_type,payload) values(r.code,'interrogation',jsonb_build_object('title','INTERROGATOIRE','text',t.pseudo||' entre dans la Grey Room pour 8 minutes.','target_id',t.id,'cycle',r.cycle));
 return jsonb_build_object('ok',true);
end $function$;

CREATE OR REPLACE FUNCTION public.igr_v4_start_next_annex_or_trame(p_room text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r public.igr_v4_rooms%rowtype; q jsonb; idx int; item jsonb; secs int;
begin
 select * into r from public.igr_v4_rooms where code=p_room for update;
 q:=coalesce(r.state->'annex_queue','[]'::jsonb); idx:=coalesce((r.state->>'annex_index')::int,0);
 if jsonb_array_length(q)=0 and idx=0 then q:=public.igr_v4_build_annex_queue(r.code); update public.igr_v4_rooms set state=jsonb_set(state,'{annex_queue}',q,true) where code=r.code; end if;
 if idx<jsonb_array_length(q) then
   item:=q->idx; secs:=coalesce((item->>'seconds')::int,180);
   update public.igr_v4_rooms set phase='annex_'||(item->>'role'),phase_started_at=now(),phase_ends_at=now()+make_interval(secs=>secs),state=jsonb_set(state,'{annex_index}',to_jsonb(idx+1),true),updated_at=now() where code=r.code;
   insert into public.igr_v4_events(room_code,event_type,payload) values(r.code,'phase',jsonb_build_object('title',item->>'title','text',case item->>'role' when 'temoin' then 'Enquêteur et Analyste disposent de 4 minutes au total pour entendre le ou les témoins.' else 'Enquêteur + Analyste + '||initcap(item->>'role')||' : fenêtre dédiée.' end));
 else
   perform public.igr_v4_emit_trame(r.code);
   update public.igr_v4_rooms set phase='trame',phase_started_at=now(),phase_ends_at=now()+interval '22 seconds',updated_at=now() where code=r.code;
 end if;
end $function$;


CREATE OR REPLACE FUNCTION public.igr_v4_start_orals(p_room text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare q jsonb:='[]'::jsonb; p public.igr_v4_players%rowtype; secs int; first jsonb;
begin
 for p in select * from public.igr_v4_players where room_code=p_room and public_role in ('analyste','enqueteur','procureur','inspecteur','journaliste','expert') order by case public_role when 'analyste' then 1 when 'enqueteur' then 2 when 'procureur' then 3 when 'inspecteur' then 4 when 'journaliste' then 5 when 'expert' then 6 else 9 end,seat_index loop
   secs:=case p.public_role when 'analyste' then 45 when 'enqueteur' then 45 when 'procureur' then 60 else 30 end;
   q:=q||jsonb_build_array(jsonb_build_object('player_id',p.id,'pseudo',p.pseudo,'role',p.public_role,'seconds',secs));
 end loop;
 if jsonb_array_length(q)=0 then update public.igr_v4_rooms set phase='provisional_lock',phase_started_at=now(),phase_ends_at=null where code=p_room; return; end if;
 first:=q->0;
 update public.igr_v4_rooms set phase='provisional_orals',phase_started_at=now(),phase_ends_at=now()+make_interval(secs=>(first->>'seconds')::int),state=jsonb_set(jsonb_set(state,'{oral_queue}',q,true),'{oral_index}','0'::jsonb,true),updated_at=now() where code=p_room;
 insert into public.igr_v4_events(room_code,event_type,payload) values(p_room,'phase',jsonb_build_object('title','CONCLUSIONS ORALES PROVISOIRES','text',(first->>'pseudo')||' commence. Les conclusions restent provisoires.'));
end $function$;


CREATE OR REPLACE FUNCTION public.igr_v4_submit_debrief(p_code text, p_player_token uuid, p_convergence integer, p_confusion integer, p_axis text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare p public.igr_v4_players%rowtype; r public.igr_v4_rooms%rowtype;
begin
 select * into p from public.igr_v4_players where room_code=upper(trim(p_code)) and player_token=p_player_token; if not found or p.public_role not in ('enqueteur','analyste') then raise exception 'forbidden'; end if;
 select * into r from public.igr_v4_rooms where code=p.room_code for update; if r.phase<>'cycle_debrief' then raise exception 'wrong phase'; end if;
 if exists(select 1 from public.igr_v4_actions where room_code=r.code and player_id=p.id and cycle=r.cycle and action_type='debrief') then raise exception 'already submitted'; end if;
 insert into public.igr_v4_actions(room_code,player_id,cycle,action_type,payload) values(r.code,p.id,r.cycle,'debrief',jsonb_build_object('convergence',greatest(0,least(2,p_convergence)),'confusion',greatest(0,least(2,p_confusion)),'axis',left(coalesce(p_axis,''),32)));
 if not exists(select 1 from public.igr_v4_players x where x.room_code=r.code and x.public_role in ('enqueteur','analyste') and not exists(select 1 from public.igr_v4_actions a where a.room_code=r.code and a.player_id=x.id and a.cycle=r.cycle and a.action_type='debrief')) then perform public.igr_v4_start_next_annex_or_trame(r.code); end if;
 return jsonb_build_object('ok',true);
end $function$;


CREATE OR REPLACE FUNCTION public.igr_v4_sync(p_code text, p_player_token uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare p public.igr_v4_players%rowtype; r public.igr_v4_rooms%rowtype; players jsonb; ev jsonb; suspects jsonb; pack jsonb; my_actions jsonb;
begin
 select * into p from public.igr_v4_players where room_code=upper(trim(p_code)) and player_token=p_player_token;
 if not found then raise exception 'unauthorized'; end if;
 perform public.igr_v4_tick(p.room_code);
 select * into r from public.igr_v4_rooms where code=p.room_code;
 select x.pack into pack from public.igr_v4_scenario_packs x where x.scenario_id=r.scenario_id;
 select coalesce(jsonb_agg(jsonb_build_object('id',id,'pseudo',pseudo,'seat_index',seat_index,'is_host',is_host,'public_role',public_role,'ready',ready) order by seat_index),'[]'::jsonb) into players from public.igr_v4_players where room_code=r.code;
 ev:=public.igr_v4_visible_events(r.code,p);
 select coalesce(jsonb_agg(jsonb_build_object('id',id,'pseudo',pseudo) order by seat_index),'[]'::jsonb) into suspects from public.igr_v4_players where room_code=r.code and public_role='suspect';
 select coalesce(jsonb_agg(jsonb_build_object('id',id,'cycle',cycle,'action_type',action_type,'payload',payload,'created_at',created_at) order by id),'[]'::jsonb) into my_actions from public.igr_v4_actions where room_code=r.code and player_id=p.id;
 return jsonb_build_object(
  'room',jsonb_build_object('code',r.code,'scenario_id',r.scenario_id,'status',r.status,'cycle',r.cycle,'phase',r.phase,'phase_started_at',r.phase_started_at,'phase_ends_at',r.phase_ends_at,'state',r.state,'min_players',public.igr_v4_min_players(r.scenario_id),'max_players',public.igr_v4_max_players(r.scenario_id)),
  'player',jsonb_build_object('id',p.id,'pseudo',p.pseudo,'is_host',p.is_host,'public_role',p.public_role,'secret_role',case when r.status in ('playing','finished') then p.secret_role else null end,'private_state',case when r.status in ('playing','finished') then p.private_state else '{}'::jsonb end),
  'players',players,'suspects',suspects,'events',ev,'my_actions',my_actions,
  'scenario',jsonb_build_object('context',pack->>'context','news',case when p.public_role='journaliste' then pack->'news' else '[]'::jsonb end,'protected',case when p.public_role='juge' then pack->'protected' else '[]'::jsonb end,'field_actions',case when p.public_role='inspecteur' then pack->'field_actions' else '[]'::jsonb end,'expert_actions',case when p.public_role='expert' then pack->'expert_actions' else '[]'::jsonb end,'truth',case when r.status='finished' then pack->'truth' else null end)
 );
end $function$;


CREATE OR REPLACE FUNCTION public.igr_v4_tick(p_room text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r public.igr_v4_rooms%rowtype; heard jsonb; target text; suspect_count int; q jsonb; idx int; item jsonb; next_idx int; defq jsonb;
begin
 select * into r from public.igr_v4_rooms where code=p_room for update;
 if not found or r.status<>'playing' then return; end if;
 if r.phase_ends_at is null or now()<r.phase_ends_at then return; end if;
 if r.phase='role_reading' then
   update public.igr_v4_rooms set phase='initial_debrief',phase_started_at=now(),phase_ends_at=now()+interval '3 minutes',updated_at=now() where code=r.code;
   insert into public.igr_v4_events(room_code,event_type,payload) values(r.code,'phase',jsonb_build_object('title','DÉBRIEF INITIAL','text','Enquêteur + Analyste : 3 minutes. Si aucun Analyste n’est présent, l’Enquêteur travaille seul.'));
 elsif r.phase='initial_debrief' then perform public.igr_v4_start_cycle(r.code,1);
 elsif r.phase='interrogation' then
   heard:=coalesce(r.state->'heard','[]'::jsonb); target:=r.state->>'current_target';
   if target is not null and not (heard ? target) then heard:=heard||to_jsonb(target); end if;
   select count(*) into suspect_count from public.igr_v4_players where room_code=r.code and public_role='suspect';
   if jsonb_array_length(heard)>=suspect_count then
     update public.igr_v4_rooms set phase='cycle_debrief',phase_started_at=now(),phase_ends_at=now()+interval '3 minutes',state=jsonb_set(state,'{heard}',heard,true),updated_at=now() where code=r.code;
     insert into public.igr_v4_events(room_code,event_type,payload) values(r.code,'phase',jsonb_build_object('title','DÉBRIEF','text','Enquêteur et Analyste répondent à trois questions très courtes. Le MJ choisira seul la trame.'));
   else update public.igr_v4_rooms set phase='interrogation_select',phase_started_at=now(),phase_ends_at=null,state=jsonb_set(state,'{heard}',heard,true),updated_at=now() where code=r.code; end if;
 elsif r.phase='cycle_debrief' then perform public.igr_v4_start_next_annex_or_trame(r.code);
 elsif r.phase like 'annex_%' then perform public.igr_v4_start_next_annex_or_trame(r.code);
 elsif r.phase='trame' then
   if r.cycle<3 then perform public.igr_v4_start_cycle(r.code,r.cycle+1);
   else
     update public.igr_v4_rooms set phase='closed',phase_started_at=now(),phase_ends_at=now()+interval '5 seconds',updated_at=now() where code=r.code;
     insert into public.igr_v4_events(room_code,event_type,payload) values(r.code,'phase',jsonb_build_object('title','ENQUÊTE CLOSE','text','Plus aucune trame, expertise, Breaking News ou action de terrain ne peut être déclenchée.'));
   end if;
 elsif r.phase='closed' then perform public.igr_v4_start_orals(r.code);
 elsif r.phase='provisional_orals' then
   q:=coalesce(r.state->'oral_queue','[]'::jsonb); idx:=coalesce((r.state->>'oral_index')::int,0); next_idx:=idx+1;
   if next_idx<jsonb_array_length(q) then item:=q->next_idx; update public.igr_v4_rooms set phase_started_at=now(),phase_ends_at=now()+make_interval(secs=>(item->>'seconds')::int),state=jsonb_set(state,'{oral_index}',to_jsonb(next_idx),true),updated_at=now() where code=r.code; insert into public.igr_v4_events(room_code,event_type,payload) values(r.code,'phase',jsonb_build_object('title','CONCLUSION PROVISOIRE','text',(item->>'pseudo')||' prend la parole.'));
   else update public.igr_v4_rooms set phase='provisional_lock',phase_started_at=now(),phase_ends_at=null,updated_at=now() where code=r.code; insert into public.igr_v4_events(room_code,event_type,payload) values(r.code,'phase',jsonb_build_object('title','ACCUSATIONS PROVISOIRES','text','L’Enquêteur verrouille maintenant le degré provisoire de responsabilité de chaque suspect.')); end if;
 elsif r.phase='defense' then
   defq:=coalesce(r.state->'defense_queue','[]'::jsonb); idx:=coalesce((r.state->>'defense_index')::int,0); next_idx:=idx+1;
   if next_idx<jsonb_array_length(defq) then item:=defq->next_idx; update public.igr_v4_rooms set phase_started_at=now(),phase_ends_at=now()+interval '5 minutes',state=jsonb_set(state,'{defense_index}',to_jsonb(next_idx),true),updated_at=now() where code=r.code; insert into public.igr_v4_events(room_code,event_type,payload) values(r.code,'phase',jsonb_build_object('title','DERNIÈRE DÉFENSE','text',(item->>'pseudo')||' dispose de 5 minutes. L’Avocat éventuel partage ce temps.'));
   else update public.igr_v4_rooms set phase='final_debrief',phase_started_at=now(),phase_ends_at=now()+interval '3 minutes',updated_at=now() where code=r.code; insert into public.igr_v4_events(room_code,event_type,payload) values(r.code,'phase',jsonb_build_object('title','DERNIER DÉBRIEF','text','Enquêteur + Analyste, avec Procureur si présent : 3 minutes. Le Juge reste à l’extérieur.')); end if;
 elsif r.phase='final_debrief' then
   update public.igr_v4_rooms set phase='locking',phase_started_at=now(),phase_ends_at=null,updated_at=now() where code=r.code;
   insert into public.igr_v4_events(room_code,event_type,payload) values(r.code,'phase',jsonb_build_object('title','FIN DES ÉCHANGES','text','Chaque rôle concerné verrouille son choix final sur son propre téléphone.'));
 end if;
end $function$;


CREATE OR REPLACE FUNCTION public.igr_v4_video_set(p_code text, p_player_token uuid, p_active boolean, p_confidential_cut boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare p public.igr_v4_players%rowtype; r public.igr_v4_rooms%rowtype; cut_until timestamptz; newstate jsonb;
begin
 select * into p from public.igr_v4_players where room_code=upper(trim(p_code)) and player_token=p_player_token; if not found or p.public_role<>'enqueteur' then raise exception 'forbidden'; end if;
 select * into r from public.igr_v4_rooms where code=p.room_code for update; if r.status<>'playing' then raise exception 'closed'; end if;
 if p_confidential_cut then
   if exists(select 1 from public.igr_v4_actions where room_code=r.code and player_id=p.id and cycle=r.cycle and action_type='video_cut') then raise exception 'cycle limit'; end if;
   cut_until:=now()+interval '60 seconds'; insert into public.igr_v4_actions(room_code,player_id,cycle,action_type,payload) values(r.code,p.id,r.cycle,'video_cut','{}'); newstate:=jsonb_set(jsonb_set(r.state,'{video_active}','false'::jsonb,true),'{video_cut_until}',to_jsonb(cut_until::text),true);
 else newstate:=jsonb_set(r.state,'{video_active}',to_jsonb(p_active),true); if p_active then newstate:=jsonb_set(newstate,'{video_cut_until}','null'::jsonb,true); end if; end if;
 update public.igr_v4_rooms set state=newstate,updated_at=now() where code=r.code;
 insert into public.igr_v4_events(room_code,event_type,visibility,audience_roles,payload) values(r.code,'video','roles',array['enqueteur','analyste','procureur','juge','inspecteur'],jsonb_build_object('title','FLUX VIDÉO','text',case when p_confidential_cut then 'Coupure confidentielle : vidéo et audio suspendus jusqu’à 60 secondes.' when p_active then 'Flux vidéo direct activé. Aucun enregistrement ni replay.' else 'Flux vidéo arrêté.' end));
 return jsonb_build_object('ok',true,'cut_until',cut_until);
end $function$;


CREATE OR REPLACE FUNCTION public.igr_v4_visible_events(p_room text, p_player igr_v4_players)
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
 select coalesce(jsonb_agg(jsonb_build_object('id',e.id,'event_type',e.event_type,'payload',e.payload,'created_at',e.created_at) order by e.id),'[]'::jsonb)
 from public.igr_v4_events e
 where e.room_code=p_room and (
   e.visibility='public' or
   (e.visibility='private' and e.target_player_id=p_player.id) or
   (e.visibility='roles' and p_player.public_role=any(e.audience_roles))
 )
$function$;


CREATE OR REPLACE FUNCTION public.igr_v4_witness_status(p_code text, p_player_token uuid, p_target uuid, p_status text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare p public.igr_v4_players%rowtype; t public.igr_v4_players%rowtype; r public.igr_v4_rooms%rowtype;
begin
 select * into p from public.igr_v4_players where room_code=upper(trim(p_code)) and player_token=p_player_token; if not found or p.public_role<>'enqueteur' then raise exception 'forbidden'; end if;
 select * into r from public.igr_v4_rooms where code=p.room_code; if r.phase<>'annex_temoin' then raise exception 'wrong phase'; end if;
 select * into t from public.igr_v4_players where room_code=r.code and id=p_target and public_role='temoin'; if not found then raise exception 'invalid target'; end if;
 if p_status not in ('interest','suspect') then raise exception 'invalid status'; end if;
 insert into public.igr_v4_actions(room_code,player_id,cycle,action_type,payload) values(r.code,p.id,r.cycle,'witness_status',jsonb_build_object('target',t.id,'status',p_status));
 insert into public.igr_v4_events(room_code,event_type,payload) values(r.code,'witness_status',jsonb_build_object('title',case when p_status='interest' then 'PERSONNE D’INTÉRÊT' else 'TÉMOIN PLACÉ COMME SUSPECT' end,'text',t.pseudo||case when p_status='interest' then ' est désormais traité comme personne d’intérêt.' else ' devient formellement suspect dans la conduite de l’enquête. Le canon ne change pas.' end));
 return jsonb_build_object('ok',true);
end $function$;


-- Explicit RPC grants currently exposed to anon/authenticated:
grant execute on function public.igr_v4_ack_role(text,uuid) to anon,authenticated;
grant execute on function public.igr_v4_create_room(text,text,text) to anon,authenticated;
grant execute on function public.igr_v4_end_interrogation(text,uuid) to anon,authenticated;
grant execute on function public.igr_v4_join_room(text,text) to anon,authenticated;
grant execute on function public.igr_v4_lock_final(text,uuid,jsonb) to anon,authenticated;
grant execute on function public.igr_v4_prosecutor_request(text,uuid,uuid) to anon,authenticated;
grant execute on function public.igr_v4_prosecutor_respond(text,uuid,bigint,boolean) to anon,authenticated;
grant execute on function public.igr_v4_publish_breaking(text,uuid,text) to anon,authenticated;
grant execute on function public.igr_v4_send_message(text,uuid,text,uuid,text) to anon,authenticated;
grant execute on function public.igr_v4_set_provisional(text,uuid,jsonb) to anon,authenticated;
grant execute on function public.igr_v4_signal_poll(text,uuid,bigint) to anon,authenticated;
grant execute on function public.igr_v4_signal_send(text,uuid,uuid,text,jsonb) to anon,authenticated;
grant execute on function public.igr_v4_special_action(text,uuid,text,text) to anon,authenticated;
grant execute on function public.igr_v4_start_game(text,uuid) to anon,authenticated;
grant execute on function public.igr_v4_start_interrogation(text,uuid,uuid) to anon,authenticated;
grant execute on function public.igr_v4_submit_debrief(text,uuid,integer,integer,text) to anon,authenticated;
grant execute on function public.igr_v4_sync(text,uuid) to anon,authenticated;
grant execute on function public.igr_v4_video_set(text,uuid,boolean,boolean) to anon,authenticated;
grant execute on function public.igr_v4_witness_status(text,uuid,uuid,text) to anon,authenticated;



-- ==============================================================================
-- PACKS DE SCÉNARIOS V3 001–011
-- ==============================================================================

-- Inside Grey Room — V3 scenario pack data exported 2026-09-10
-- Configuration/content data only; no transient rooms, players, tokens or game sessions.

insert into public.igr_v3_scenario_packs(scenario_id,pack,updated_at)
values ('001', $igr${"truth":{"levels":[2,3,0],"summary":"A a participé à l'escalade en organisant une intimidation criminelle, mais quitte Maël vivant vers 02h32. B est l'intervenant rémunéré qui entre ensuite, lutte avec Maël et porte volontairement le coup fatal. C est un client de l'hôtel, présent près de la porte, qui cache sa proximité par peur."},"trames":[{"kind":"ambiguity","text":"Les registres confirment que plusieurs clients légitimes occupaient le deuxième étage, dont un client utilisant régulièrement une moto.","title":"LISTE DES RÉSERVATIONS","min_cycle":1},{"kind":"clarity","text":"Un appel bref est émis depuis le téléphone de Maël après 02h32. Son contenu n'est pas récupérable.","title":"APPEL APRÈS LA DISPUTE","min_cycle":1},{"kind":"ambiguity","text":"Une microtrace de sang de Maël est relevée dans le couloir, sans permettre d'identifier qui l'a transportée.","title":"TRACE DE SANG HORS CHAMBRE","min_cycle":1},{"kind":"clarity","text":"Une silhouette compatible avec A quitte l'étage vers 02h32. L'image ne montre pas l'intérieur de 222.","title":"CAMÉRA PARTIELLE","min_cycle":1},{"kind":"balanced","text":"Vers 02h48, une silhouette encapuchonnée entre dans l'hôtel. L'identification formelle reste impossible.","title":"ENTRÉE TROP FLOUE","min_cycle":1},{"kind":"clarity","text":"Un brouillon de Maël évoque une dette et la peur de « gens qui doivent venir ».","title":"BROUILLON NON ENVOYÉ","min_cycle":2},{"kind":"clarity","text":"L'Opinel n°12 a été nettoyé rapidement mais conserve des microtraces de sang dans le mécanisme.","title":"ARME PARTIELLEMENT NETTOYÉE","min_cycle":2},{"kind":"ambiguity","text":"Les empreintes humides dans 222 sont compatibles avec au moins deux tailles différentes.","title":"DEUX TAILLES DE PAS","min_cycle":2},{"kind":"clarity","text":"Une cliente entend une dispute avant 02h30 puis, plus tard, un bruit sourd plus violent autour de 03h05.","title":"CHAMBRE VOISINE","min_cycle":3},{"kind":"balanced","text":"Une odeur de produit nettoyant est détectée sur un chiffon retrouvé près de la sortie de service.","title":"ODEUR DE NETTOYANT","min_cycle":3}],"context":"Dans un ancien hôtel de montagne isolé par la pluie, Maël Sénéchal est retrouvé mort dans la chambre 222 à 03h47. La scène porte les traces d'une lutte et aucun signe d'effraction n'est relevé.","suspects":[{"hide":"Tu as contacté des intermédiaires criminels pour intimider Maël et récupérer de l'argent. Tu n'as jamais demandé explicitement sa mort.","place":"Ancien ami de Maël, lié à lui par des dettes et une relation devenue instable.","anchors":"Tu sais que la dispute a déplacé des objets. Tu sais aussi que quelqu'un devait faire peur à Maël après ton départ, sans connaître exactement la personne envoyée.","position":"Reconnais la dispute si nécessaire, mais sépare ta responsabilité d'intimidation du meurtre.","chronology":"02h11 : Maël t'écrit « Monte maintenant ». Tu montes, vous vous disputez et vous vous bousculez. Tu quittes l'étage vers 02h32. Maël est vivant quand tu pars."},{"hide":"Ta présence réelle, le meurtre, le nettoyage de l'arme et le lien avec l'intervention rémunérée.","place":"Intervenant rémunéré sans lien personnel connu avec Maël.","anchors":"Tu sais que la scène était déjà désordonnée avant ton arrivée. Tu ne sais pas tout ce qu'A a dit à Maël.","position":"Dissocie les traces de la première dispute de celles du meurtre et exploite les angles morts des caméras.","chronology":"Tu arrives après le départ d'A. Tu entres vers 02h55. Une lutte violente éclate. Le coup fatal est volontaire. Tu nettoies partiellement l'Opinel puis le jettes dans une benne extérieure."},{"hide":"Ta proximité exacte avec la scène et le fait d'avoir vu la porte entrouverte.","place":"Client régulier de l'hôtel, présent pour des raisons professionnelles et sans lien personnel avec Maël.","anchors":"Tu utilises régulièrement une moto et possèdes un permis. Tu n'es pas entré dans la chambre.","position":"Ton objectif est de faire comprendre que ta peur t'a rendu suspect sans transformer ton silence en meurtre.","chronology":"Tu reviens vers 02h45, passes près de 222 vers 02h50, entends du bruit et vois la porte légèrement entrouverte. Tu retournes dans ta chambre sans prévenir le personnel."}],"protected":[{"id":"p1","cost":1,"text":"Un numéro jetable lié à l’intimidation d’A communique avec un autre numéro peu avant 02h50.","title":"Identité d’un intermédiaire"}],"field_actions":[],"expert_actions":[]}$igr$::jsonb, now())
on conflict (scenario_id) do update set pack=excluded.pack, updated_at=excluded.updated_at;

insert into public.igr_v3_scenario_packs(scenario_id,pack,updated_at)
values ('002', $igr${"truth":{"levels":[2,2,0,1],"summary":"Le suicide est réel. A a humilié Léon et utilisé des confidences contre lui. B entretenait une relation affective devenue violente et épuisante mais n'a jamais voulu sa mort. C est un témoin anxieux qui n'intervient pas. D, proche de Léon, a essayé de l'aider mais minimise une dernière erreur de jugement."},"trames":[{"kind":"ambiguity","text":"Un brouillon de Léon contient : « J'en peux plus de lui. » Impossible de savoir de qui il parle.","title":"MESSAGE NON ENVOYÉ","min_cycle":1},{"kind":"ambiguity","text":"Une conversation récupérée contient : « Tu détruis tout autour de toi. » Le contexte reste incomplet.","title":"CONVERSATION GLACIALE","min_cycle":1},{"kind":"clarity","text":"Plusieurs appels de Léon restent sans réponse le soir de sa mort, dont certains destinés à B.","title":"APPELS IGNORÉS","min_cycle":1},{"kind":"balanced","text":"Un psychologue décrit une souffrance ancienne, complexe, aggravée par des événements récents mais non réductible à eux.","title":"CONSULTATION PSYCHOLOGIQUE","min_cycle":2},{"kind":"balanced","text":"Un fragment indique : « Je ne sais plus qui est sincère avec moi. »","title":"LETTRE DÉCHIRÉE","min_cycle":1},{"kind":"ambiguity","text":"Des messages montrent que Léon considérait encore B comme l'une des seules personnes capables de le comprendre.","title":"DERNIER REFUGE","min_cycle":2},{"kind":"clarity","text":"Une résidente entend Léon pleurer et répéter qu'« ils vont continuer jusqu'à ce que je craque ».","title":"PLEURS ENTENDUS","min_cycle":2},{"kind":"ambiguity","text":"Des prescriptions et recherches montrent des épisodes de détresse antérieurs aux conflits récents.","title":"MÉDICAMENTS ANTÉRIEURS","min_cycle":3},{"kind":"balanced","text":"Quelques heures avant sa mort, Léon envoie un message étonnamment calme, sans que cela permette d'inférer son intention.","title":"FAUSSE ACCALMIE","min_cycle":3},{"kind":"clarity","text":"La chronologie montre plusieurs contacts blessants distincts : aucun acteur n'est seul dans la séquence relationnelle qui précède le suicide.","title":"RESPONSABILITÉ FRAGMENTÉE","min_cycle":3}],"context":"Léon meurt par suicide dans une résidence étudiante. L'enquête cherche à reconstruire les responsabilités morales et relationnelles autour de son effondrement, sans inventer une causalité unique.","suspects":[{"hide":"L'ampleur des humiliations et l'utilisation de confidences intimes.","place":"Ancien proche de Léon devenu une figure de domination sociale.","anchors":"Tu sais que Léon souffrait avant les événements récents, mais tu as aggravé son isolement.","position":"Évite qu'on transforme ta cruauté en causalité mécanique unique.","chronology":"Tu as participé à des humiliations publiques et diffusé des éléments privés. Le soir de sa mort, tu le confrontes encore."},{"hide":"Des messages extrêmement violents et ta fatigue émotionnelle.","place":"Proche affectif de Léon, relation devenue épuisante et conflictuelle.","anchors":"Tu aimais réellement Léon mais tu te sentais prisonnier de sa détresse.","position":"Reconnais la violence de tes mots sans accepter une intention suicidaire inexistante.","chronology":"Tu ignores plusieurs appels, échanges ensuite des messages très durs et t'éloignes. Tu n'ordonnes ni n'encourages explicitement un suicide."},{"hide":"Ta présence réelle et ta peur d'être impliqué.","place":"Résident discret et anxieux, connaissance lointaine de Léon.","anchors":"Tu connais peu le conflit central.","position":"Reste précis : ton omission est humaine mais tu n'es pas au cœur des humiliations.","chronology":"Tu passes près de la salle, entends Léon pleurer mais n'interviens pas."},{"hide":"Tu minimises à quel point tu étais inquiet et une phrase où tu lui demandes de dormir et d'arrêter de dramatiser.","place":"Meilleur ami de Léon et principal soutien réel.","anchors":"Tu as essayé de l'aider depuis longtemps.","position":"Fais distinguer erreur de jugement, culpabilité affective et volonté de nuire.","chronology":"Tu parles avec lui tardivement. Tu penses qu'il ne passera pas à l'acte et quittes les lieux malgré son état."}],"protected":[],"field_actions":[],"expert_actions":[]}$igr$::jsonb, now())
on conflict (scenario_id) do update set pack=excluded.pack, updated_at=excluded.updated_at;

insert into public.igr_v3_scenario_packs(scenario_id,pack,updated_at)
values ('003', $igr${"truth":{"levels":[2,2,2],"summary":"A a voulu provoquer un choc politique en facilitant une fuite contrôlée mais n'a pas anticipé l'attaque. B a exécuté des transferts dangereux et ignoré des alertes. C a dissimulé des failles et accepté un risque pour protéger le programme. La catastrophe résulte d'une chaîne de décisions."},"trames":[{"kind":"ambiguity","text":"Un message supprimé évoque la nécessité de provoquer « un électrochoc » autour du programme.","title":"MESSAGE EFFACÉ","min_cycle":1},{"kind":"clarity","text":"Un véhicule quitte Helios hors créneau de transfert autorisé.","title":"TRANSPORT ANORMAL","min_cycle":1},{"kind":"clarity","text":"Une alerte de chaîne du froid est fermée sans contre-expertise.","title":"ALERTE IGNORÉE","min_cycle":1},{"kind":"ambiguity","text":"Deux cadres se rencontrent hors agenda la veille de l'attaque.","title":"DISCUSSION PRIVÉE","min_cycle":1},{"kind":"clarity","text":"Une série d'incidents antérieurs a été retirée du dossier remis à l'autorité sanitaire.","title":"DOSSIER DISSIMULÉ","min_cycle":2},{"kind":"ambiguity","text":"Un appel et un message montrent qu'une personne tente d'arrêter quelque chose quelques heures avant l'attaque.","title":"TENTATIVE D'ANNULATION","min_cycle":2},{"kind":"balanced","text":"Un appel urgent reste sans réponse pendant la fenêtre critique.","title":"APPEL NON ABOUTI","min_cycle":2},{"kind":"clarity","text":"Un contrôle externe est repoussé sur intervention administrative.","title":"INSPECTION NEUTRALISÉE","min_cycle":3},{"kind":"ambiguity","text":"Après l'attentat, plusieurs employés cherchent d'abord à identifier la fuite documentaire avant de sécuriser les dossiers techniques.","title":"PANique INTERNE","min_cycle":3},{"kind":"clarity","text":"Aucune action isolée ne suffit à expliquer l'accès, le transport et l'opacité institutionnelle ayant rendu l'attaque possible.","title":"RESPONSABILITÉ FRAGMENTÉE","min_cycle":3}],"context":"Une attaque biologique frappe une gare et fait plus de cent morts. L'agent est relié au programme expérimental du Centre Helios.","suspects":[{"hide":"L'accès facilité et ton idée d'un « électrochoc » politique.","place":"Cadre d'Helios convaincu qu'un scandale maîtrisé pouvait forcer une réforme.","anchors":"Tu n'as pas conçu l'attaque de masse et tu ne contrôles pas l'intermédiaire final.","position":"Fais reconnaître ta responsabilité sans accepter qu'on t'attribue seul les morts.","chronology":"Tu autorises un accès anormal et communiques avec un intermédiaire. Tu essaies trop tard d'annuler l'opération."},{"hide":"Un transport anormal et une alerte ignorée.","place":"Responsable logistique ayant exécuté des transferts sensibles.","anchors":"Tu as tenté de joindre A après avoir compris le risque.","position":"Mets l'accent sur l'obéissance, mais ne nie pas les signaux que tu as vus.","chronology":"Tu déplaces du matériel hors procédure et ignores une alerte car tu crois suivre une urgence supérieure."},{"hide":"Des dossiers dissimulés et une inspection neutralisée.","place":"Responsable conformité et communication du programme.","anchors":"Tu ne participes pas au transfert final, mais tu as rendu le système opaque.","position":"Défends la différence entre couvrir un programme et vouloir une attaque.","chronology":"Tu fais classer plusieurs incidents et empêches une inspection complète pour protéger Helios."}],"protected":[],"field_actions":[],"expert_actions":[]}$igr$::jsonb, now())
on conflict (scenario_id) do update set pack=excluded.pack, updated_at=excluded.updated_at;

insert into public.igr_v3_scenario_packs(scenario_id,pack,updated_at)
values ('004', $igr${"truth":{"levels":[1,2,2],"summary":"A est l'ex-partenaire épuisé qui refuse de revenir malgré un appel clair. B, proche affectif, veut aider mais retarde par jalousie et calcul. C attend volontairement avant d'appeler les secours pour forcer Sofia à « comprendre ». Aucun ne l'empoisonne ; la responsabilité porte sur l'inaction et le temps perdu."},"trames":[{"kind":"clarity","text":"Sofia envoie quasiment le même appel à l'aide aux trois personnes.","title":"MESSAGE IDENTIQUE","min_cycle":1},{"kind":"clarity","text":"Les relevés montrent plusieurs appels successifs et des délais différents avant réponse.","title":"APPELS MANQUÉS","min_cycle":1},{"kind":"clarity","text":"Une caméra de rue montre un véhicule compatible avec celui de C passant devant l'immeuble.","title":"PASSAGE DEVANT L'IMMEUBLE","min_cycle":1},{"kind":"ambiguity","text":"Un message effacé évoque : « Cette fois je ne vais pas courir. »","title":"MESSAGE SUPPRIMÉ","min_cycle":1},{"kind":"balanced","text":"Un appel de moins de vingt secondes a lieu pendant une fenêtre où Sofia est encore consciente.","title":"APPEL COUPÉ","min_cycle":2},{"kind":"ambiguity","text":"Un dernier message de Sofia paraît calme et cohérent alors que l'intoxication est déjà avancée.","title":"FAUSSE ACCALMIE","min_cycle":2},{"kind":"clarity","text":"L'analyse indique une intoxication progressive : une intervention plus précoce aurait matériellement changé les options médicales.","title":"DOSAGE TOXICOLOGIQUE","min_cycle":2},{"kind":"clarity","text":"Aucune trace ne montre qu'un tiers ait administré les substances.","title":"AUCUN TIERS DANS L'APPARTEMENT","min_cycle":3},{"kind":"clarity","text":"La reconstitution révèle plusieurs fenêtres indépendantes où l'appel aux secours aurait pu être lancé.","title":"TEMPS PERDU","min_cycle":3},{"kind":"balanced","text":"Les omissions n'ont pas la même motivation, mais elles s'additionnent dans une même nuit.","title":"RESPONSABILITÉ FRAGMENTÉE","min_cycle":3}],"context":"Sofia demande de l'aide à trois personnes au cours de la même nuit. Chacune hésite, refuse ou tarde. Sofia meurt seule d'une overdose alcool-médicaments.","suspects":[{"hide":"La dureté exacte de ton refus et le fait que tu savais qu'elle mélangeait alcool et médicaments.","place":"Ex-partenaire de Sofia, relation devenue toxique et épuisante.","anchors":"Tu étais réellement épuisé et tu n'as pas préparé l'overdose.","position":"Refuse l'idée d'un meurtre tout en assumant le choix de ne pas intervenir.","chronology":"Tu reçois un appel et refuses de revenir après une dispute. Tu crois qu'elle exagère comme d'autres fois."},{"hide":"Tes sentiments, ton attente volontaire et un message supprimé.","place":"Ami très proche, amoureux sans l'avoir dit.","anchors":"Tu pensais encore avoir le temps.","position":"Montre que ton calcul émotionnel est grave sans être une volonté de mort.","chronology":"Tu lis les messages, hésites à venir, attends qu'elle rappelle et perds du temps par jalousie envers A."},{"hide":"Ton passage réel et l'attente volontaire.","place":"Proche possessif persuadé qu'il faut laisser Sofia toucher le fond.","anchors":"Tu n'as pas fourni les médicaments.","position":"Ta stratégie est de minimiser la durée et de présenter ton attente comme une erreur éducative.","chronology":"Tu passes près de l'immeuble mais n'entres pas. Tu attends avant d'appeler, voulant qu'elle comprenne qu'elle ne peut pas toujours être secourue."}],"protected":[],"field_actions":[],"expert_actions":[]}$igr$::jsonb, now())
on conflict (scenario_id) do update set pack=excluded.pack, updated_at=excluded.updated_at;

insert into public.igr_v3_scenario_packs(scenario_id,pack,updated_at)
values ('005', $igr${"truth":{"levels":[1,0,3],"summary":"Le meurtre de Keller est un crime personnel commis sous l’identité du Masque Blanc par le troisième suspect. Les autres liens au symbole expliquent de vrais soupçons mais pas ce meurtre."},"trames":[{"kind":"clarity","text":"Le masque et certains placements reproduisent des éléments connus des anciens dossiers, mais pas avec une exactitude parfaite.","title":"MISE EN SCÈNE","min_cycle":1},{"kind":"clarity","text":"La mort de Keller se situe après une confrontation prolongée dans son studio.","title":"STUDIO PRIVÉ","min_cycle":1},{"kind":"clarity","text":"La violence est plus impulsive et moins méthodique que dans plusieurs crimes antérieurs attribués au Masque Blanc.","title":"ÉCART DE MÉTHODE","min_cycle":2},{"kind":"ambiguity","text":"Des éléments non publics des anciens dossiers étaient accessibles à plus d’une personne liée à l’affaire.","title":"DOSSIERS CONFIDENTIELS","min_cycle":2},{"kind":"ambiguity","text":"Des documents établissent les conséquences psychologiques durables du monde professionnel créé par Keller sur une proche de l’un des joueurs.","title":"DOSSIER DE LA FEMME","min_cycle":3},{"kind":"clarity","text":"La scène montre qu’une partie de la mise en scène a été réalisée après la mort, comme pour rattacher le meurtre à une identité préexistante.","title":"TRACE DE REPRISE","min_cycle":3}],"context":"Adrian Keller est retrouvé mort dans une mise en scène associée au Masque Blanc. Plusieurs crimes antérieurs compliquent l’identité du responsable.","suspects":[{"hide":"Une fascination réelle pour le symbole et des recherches que tu n’as jamais expliquées.","place":"Tu es lié à l’histoire du Masque Blanc et tes connaissances peuvent te faire paraître responsable de tout.","anchors":"Connaître le rituel ne signifie pas avoir commis ce meurtre.","position":"Évite l’amalgame entre obsession, imitation et passage à l’acte.","chronology":"Tu suis les anciens crimes et tu étais proche de l’univers professionnel de Keller."},{"hide":"Ta connaissance privilégiée et un contact ancien avec une victime.","place":"Tu as une relation ancienne avec les crimes attribués au Masque Blanc mais tu n’as pas tué Keller.","anchors":"Le meurtre de Keller comporte des écarts par rapport aux crimes antérieurs.","position":"Force l’enquête à regarder les différences matérielles, pas seulement le symbole.","chronology":"Tu caches un épisode antérieur qui te donne accès à des détails non publics."},{"hide":"Ta haine, le masque apporté avec toi et la transformation de la scène après le meurtre.","place":"Tu as tué Keller en reprenant le masque, mais tu n’es pas l’auteur des autres meurtres.","anchors":"Ton crime est personnel et beaucoup moins méthodique que les crimes antérieurs.","position":"Fais croire à la continuité du Masque Blanc sans te faire piéger par les divergences matérielles.","chronology":"Tu viens confronter Keller au sujet des dommages infligés à ta femme. Il minimise. Tu le frappes jusqu’à le tuer puis mets en scène le masque."}],"protected":[],"field_actions":[],"expert_actions":[]}$igr$::jsonb, now())
on conflict (scenario_id) do update set pack=excluded.pack, updated_at=excluded.updated_at;

insert into public.igr_v3_scenario_packs(scenario_id,pack,updated_at)
values ('006', $igr${"truth":{"levels":[2,3,1],"summary":"Le deuxième suspect frappe Noé pendant une dispute. Le groupe croit Noé mort et participe ensuite à la dissimulation. Le premier suspect soutient et rationalise le choix ; le troisième participe au silence sans porter le coup initial."},"trames":[{"kind":"clarity","text":"La blessure compatible avec la chute ne permet pas, à elle seule, de déterminer si Noé était déjà mort au moment où le groupe a agi.","title":"ANCIENNE CHUTE","min_cycle":1},{"kind":"ambiguity","text":"Les trois amis ont maintenu un récit remarquablement stable pendant cinq ans malgré des relations devenues plus silencieuses.","title":"TRIO FUSIONNEL","min_cycle":1},{"kind":"clarity","text":"Un objet ancien rattache matériellement le groupe à une action postérieure à la chute.","title":"TRACE CONSERVÉE","min_cycle":2},{"kind":"clarity","text":"Plusieurs éléments confirment une dispute et un coup avant la chute.","title":"DISPUTE ALCOOLISÉE","min_cycle":2},{"kind":"balanced","text":"Les indices établissent que la décision de cacher les faits n’est pas l’acte d’une seule personne.","title":"DISSIMULATION COLLECTIVE","min_cycle":3},{"kind":"clarity","text":"L’expertise tardive fragilise l’idée que les trois pouvaient être certains de la mort de Noé au moment décisif.","title":"RÉOUVERTURE MÉDICO-LÉGALE","min_cycle":3}],"context":"Cinq ans après la chute de Noé dans un chalet isolé, le dossier est rouvert. Trois amis se contredisent tout en protégeant un secret commun.","suspects":[{"hide":"Ton rôle dans la dissimulation et la rationalisation du groupe.","place":"Tu étais le plus rationnel du trio et tu as soutenu la dissimulation après la chute.","anchors":"Tu n’as pas porté le coup initial et tu pensais Noé déjà mort.","position":"Protéger la frontière entre dissimulation, panique collective et violence initiale.","chronology":"Une dispute éclate. Ton ami frappe Noé. Noé chute. Vous le croyez mort et tu soutiens la décision de faire disparaître le corps."},{"hide":"Le coup initial, ta colère et ton influence sur la décision collective.","place":"Tu as frappé Noé pendant une dispute alcoolisée.","anchors":"Tu n’avais pas planifié sa mort.","position":"Éviter qu’un coup impulsif soit automatiquement reconstruit comme un meurtre prémédité.","chronology":"Après le coup, Noé chute. Le groupe pense qu’il est mort et décide de cacher ce qui s’est passé."},{"hide":"Un détail matériel que tu as conservé et ton rôle concret dans la dissimulation.","place":"Tu étais le plus fragile du trio et tu as participé au silence collectif.","anchors":"Tu n’as frappé personne.","position":"Survivre à la pression sans devenir le faux auteur du coup initial.","chronology":"Tu assistes à la dispute, à la chute puis à la dissimulation. Depuis cinq ans, tu es celui qui risque le plus de craquer."}],"protected":[],"field_actions":[],"expert_actions":[]}$igr$::jsonb, now())
on conflict (scenario_id) do update set pack=excluded.pack, updated_at=excluded.updated_at;

insert into public.igr_v3_scenario_packs(scenario_id,pack,updated_at)
values ('007', $igr${"truth":{"levels":[2,1,2],"summary":"La mort et l’héritage résultent d’intérêts croisés : pression patrimoniale, dissimulation documentaire et secret familial. La responsabilité ne se réduit pas au bénéficiaire apparent."},"trames":[{"kind":"clarity","text":"Un brouillon testamentaire porte une modification non enregistrée.","title":"TRAME 1","min_cycle":1},{"kind":"clarity","text":"Un retrait ou transfert patrimonial précède la mort.","title":"TRAME 2","min_cycle":1},{"kind":"ambiguity","text":"Un témoin situe une dispute familiale plus tôt que déclaré.","title":"TRAME 3","min_cycle":2},{"kind":"balanced","text":"Une signature est authentique mais obtenue dans un contexte contesté.","title":"TRAME 4","min_cycle":2},{"kind":"balanced","text":"Le décès inattendu avant le cycle final recontextualise l’héritage.","title":"TRAME 5","min_cycle":3},{"kind":"clarity","text":"Une dette privée explique un mensonge sans expliquer la mort.","title":"TRAME 6","min_cycle":3}],"context":"Une affaire familiale se transforme lorsqu’un décès inattendu recontextualise les intérêts, les mensonges et le véritable enjeu de l’héritage.","suspects":[{"hide":"Le détail précis qui ferait immédiatement comprendre ta part réelle de responsabilité.","place":"Tu bénéficies directement d’un changement testamentaire et caches une pression exercée sur le défunt.","anchors":"Tu connais au moins un fait qui fragilise une lecture trop simple de l’affaire.","position":"Défends exactement ta responsabilité : ni moins, ni plus.","chronology":"Ta chronologie comporte une décision avant le point de rupture, puis une réaction après."},{"hide":"Le détail précis qui ferait immédiatement comprendre ta part réelle de responsabilité.","place":"Tu as déplacé ou retenu un document familial pour protéger quelqu’un, sans provoquer la mort.","anchors":"Tu connais au moins un fait qui fragilise une lecture trop simple de l’affaire.","position":"Défends exactement ta responsabilité : ni moins, ni plus.","chronology":"Tu es présent dans une fenêtre critique mais tes actes ne couvrent pas toute la chaîne."},{"hide":"Le détail précis qui ferait immédiatement comprendre ta part réelle de responsabilité.","place":"Tu connais un secret de filiation ou de dette qui change le mobile apparent.","anchors":"Tu connais au moins un fait qui fragilise une lecture trop simple de l’affaire.","position":"Défends exactement ta responsabilité : ni moins, ni plus.","chronology":"Tu modifies ensuite une partie de ton récit pour protéger une responsabilité secondaire."}],"protected":[],"field_actions":[],"expert_actions":[]}$igr$::jsonb, now())
on conflict (scenario_id) do update set pack=excluded.pack, updated_at=excluded.updated_at;

insert into public.igr_v3_scenario_packs(scenario_id,pack,updated_at)
values ('008', $igr${"truth":{"levels":[2,1,0],"summary":"Les faux témoignages ne recouvrent pas tous la responsabilité principale. Un mensonge protège une faute secondaire, un autre résulte d'une influence extérieure et le troisième cache surtout une relation privée."},"trames":[{"kind":"clarity","text":"Deux dépositions sont matériellement incompatibles sur le même horaire.","title":"TRAME 1","min_cycle":1},{"kind":"clarity","text":"Un document de procédure prouve qu’une pièce était connue avant une déclaration.","title":"TRAME 2","min_cycle":1},{"kind":"ambiguity","text":"Une contradiction porte sur un fait secondaire mais volontairement dissimulé.","title":"TRAME 3","min_cycle":2},{"kind":"balanced","text":"Un témoin a subi une pression documentée avant sa déposition.","title":"TRAME 4","min_cycle":2},{"kind":"balanced","text":"Une preuve indépendante confirme une partie d’une version pourtant mensongère ailleurs.","title":"TRAME 5","min_cycle":3},{"kind":"clarity","text":"Le faux témoignage et la responsabilité principale ne se superposent pas entièrement.","title":"TRAME 6","min_cycle":3}],"context":"Des déclarations sous serment sont incompatibles. Il faut distinguer mensonge défensif, faux témoignage et responsabilité dans le fait principal.","suspects":[{"hide":"Le détail précis qui ferait immédiatement comprendre ta part réelle de responsabilité.","place":"Tu as menti sous serment pour protéger une faute secondaire.","anchors":"Tu connais au moins un fait qui fragilise une lecture trop simple de l’affaire.","position":"Défends exactement ta responsabilité : ni moins, ni plus.","chronology":"Ta chronologie comporte une décision avant le point de rupture, puis une réaction après."},{"hide":"Le détail précis qui ferait immédiatement comprendre ta part réelle de responsabilité.","place":"Tu as influencé une déposition sans être responsable du fait principal.","anchors":"Tu connais au moins un fait qui fragilise une lecture trop simple de l’affaire.","position":"Défends exactement ta responsabilité : ni moins, ni plus.","chronology":"Tu es présent dans une fenêtre critique mais tes actes ne couvrent pas toute la chaîne."},{"hide":"Le détail précis qui ferait immédiatement comprendre ta part réelle de responsabilité.","place":"Ta version paraît incohérente parce que tu caches une relation privée, pas un crime.","anchors":"Tu connais au moins un fait qui fragilise une lecture trop simple de l’affaire.","position":"Défends exactement ta responsabilité : ni moins, ni plus.","chronology":"Tu modifies ensuite une partie de ton récit pour protéger une responsabilité secondaire."}],"protected":[],"field_actions":[],"expert_actions":[]}$igr$::jsonb, now())
on conflict (scenario_id) do update set pack=excluded.pack, updated_at=excluded.updated_at;

insert into public.igr_v3_scenario_packs(scenario_id,pack,updated_at)
values ('009', $igr${"truth":{"levels":[3,2,0],"summary":"Le retrait du consentement était réel et antérieur à la poursuite d'ORPHÉE. L'amnésie de Varenne est authentique mais ne supprime pas sa responsabilité pour les actes précédant la chute."},"trames":[{"kind":"clarity","text":"Le retrait du consentement est horodaté avant la poursuite d’une procédure.","title":"TRAME 1","min_cycle":1},{"kind":"clarity","text":"L’amnésie du médecin est compatible avec une atteinte péri-traumatique réelle.","title":"TRAME 2","min_cycle":1},{"kind":"ambiguity","text":"Un protocole interne autorisait moins que ce qui a réellement été fait.","title":"TRAME 3","min_cycle":2},{"kind":"balanced","text":"Une note clinique a été modifiée après l’incident.","title":"TRAME 4","min_cycle":2},{"kind":"balanced","text":"Un enregistrement prouve une opposition explicite du sujet.","title":"TRAME 5","min_cycle":3},{"kind":"clarity","text":"L’amnésie explique l’absence de souvenir, pas la responsabilité antérieure.","title":"TRAME 6","min_cycle":3}],"context":"Le Dr Gabriel Varenne a poursuivi une expérience coercitive après retrait du consentement. Une chute provoque ensuite une véritable amnésie rétrograde péri-traumatique.","suspects":[{"hide":"Le détail précis qui ferait immédiatement comprendre ta part réelle de responsabilité.","place":"Tu as poursuivi une procédure alors que le retrait du consentement était devenu explicite.","anchors":"Tu connais au moins un fait qui fragilise une lecture trop simple de l’affaire.","position":"Défends exactement ta responsabilité : ni moins, ni plus.","chronology":"Ta chronologie comporte une décision avant le point de rupture, puis une réaction après."},{"hide":"Le détail précis qui ferait immédiatement comprendre ta part réelle de responsabilité.","place":"Tu as couvert institutionnellement l’expérience pour protéger le programme ORPHÉE.","anchors":"Tu connais au moins un fait qui fragilise une lecture trop simple de l’affaire.","position":"Défends exactement ta responsabilité : ni moins, ni plus.","chronology":"Tu es présent dans une fenêtre critique mais tes actes ne couvrent pas toute la chaîne."},{"hide":"Le détail précis qui ferait immédiatement comprendre ta part réelle de responsabilité.","place":"Tu as aidé le Sujet 17 à tenter de sortir mais caches un geste qui t’expose professionnellement.","anchors":"Tu connais au moins un fait qui fragilise une lecture trop simple de l’affaire.","position":"Défends exactement ta responsabilité : ni moins, ni plus.","chronology":"Tu modifies ensuite une partie de ton récit pour protéger une responsabilité secondaire."}],"protected":[],"field_actions":[],"expert_actions":[]}$igr$::jsonb, now())
on conflict (scenario_id) do update set pack=excluded.pack, updated_at=excluded.updated_at;

insert into public.igr_v3_scenario_packs(scenario_id,pack,updated_at)
values ('010', $igr${"truth":{"levels":[2,3,1],"summary":"L'enfermement initial et l'abandon tardif sont distincts. La responsabilité la plus lourde revient à la personne qui ouvre la porte à 13:54, comprend que Nora est vivante et la referme."},"trames":[{"kind":"clarity","text":"Le capteur de porte enregistre une ouverture à 13:54.","title":"TRAME 1","min_cycle":1},{"kind":"clarity","text":"La porte est ensuite refermée volontairement.","title":"TRAME 2","min_cycle":1},{"kind":"ambiguity","text":"Des traces montrent que Nora était encore vivante au moment de cette ouverture.","title":"TRAME 3","min_cycle":2},{"kind":"balanced","text":"Un accès secondaire existait mais n’a pas été utilisé.","title":"TRAME 4","min_cycle":2},{"kind":"balanced","text":"Un voisin signale des bruits bien avant l’ouverture.","title":"TRAME 5","min_cycle":3},{"kind":"clarity","text":"La séquestration initiale et l’abandon tardif ne sont pas nécessairement le fait de la même personne.","title":"TRAME 6","min_cycle":3}],"context":"Nora Weiss est enfermée derrière un mur technique. Quelqu’un ouvre la porte bien plus tard, comprend qu’elle est vivante, puis la referme.","suspects":[{"hide":"Le détail précis qui ferait immédiatement comprendre ta part réelle de responsabilité.","place":"Tu as contribué à l’enfermement initial sans prévoir sa durée.","anchors":"Tu connais au moins un fait qui fragilise une lecture trop simple de l’affaire.","position":"Défends exactement ta responsabilité : ni moins, ni plus.","chronology":"Ta chronologie comporte une décision avant le point de rupture, puis une réaction après."},{"hide":"Le détail précis qui ferait immédiatement comprendre ta part réelle de responsabilité.","place":"Tu as ouvert la porte à 13:54 et l’as refermée en sachant Nora vivante.","anchors":"Tu connais au moins un fait qui fragilise une lecture trop simple de l’affaire.","position":"Défends exactement ta responsabilité : ni moins, ni plus.","chronology":"Tu es présent dans une fenêtre critique mais tes actes ne couvrent pas toute la chaîne."},{"hide":"Le détail précis qui ferait immédiatement comprendre ta part réelle de responsabilité.","place":"Tu as entendu des signes de présence mais n’as pas compris la situation avant bien plus tard.","anchors":"Tu connais au moins un fait qui fragilise une lecture trop simple de l’affaire.","position":"Défends exactement ta responsabilité : ni moins, ni plus.","chronology":"Tu modifies ensuite une partie de ton récit pour protéger une responsabilité secondaire."}],"protected":[],"field_actions":[],"expert_actions":[]}$igr$::jsonb, now())
on conflict (scenario_id) do update set pack=excluded.pack, updated_at=excluded.updated_at;

insert into public.igr_v3_scenario_packs(scenario_id,pack,updated_at)
values ('011', $igr${"truth":{"levels":[2,2,2],"summary":"Les trente-six heures révèlent une chaîne de commandement fragmentée : ordre risqué, exécution excessive, information incomplète et dissimulation ultérieure se combinent sans coupable unique."},"trames":[{"kind":"clarity","text":"Un ordre écrit autorise une opération sans mentionner certaines contraintes connues localement.","title":"TRAME 1","min_cycle":1},{"kind":"clarity","text":"Un rapport de terrain a été réécrit après les faits.","title":"TRAME 2","min_cycle":1},{"kind":"ambiguity","text":"Des communications prouvent que plusieurs niveaux hiérarchiques avaient des informations différentes.","title":"TRAME 3","min_cycle":2},{"kind":"balanced","text":"Un délai de trente-six heures sépare le premier signalement et l’arrêt effectif.","title":"TRAME 4","min_cycle":2},{"kind":"balanced","text":"Une unité locale a dépassé une instruction initiale.","title":"TRAME 5","min_cycle":3},{"kind":"clarity","text":"La responsabilité se répartit entre ordre, exécution, omission et dissimulation.","title":"TRAME 6","min_cycle":3}],"context":"Une opération militaire fictive laisse des villages détruits et des disparus. Le verdict doit distinguer autorité, connaissance, participation, omission et dissimulation.","suspects":[{"hide":"Le détail précis qui ferait immédiatement comprendre ta part réelle de responsabilité.","place":"Tu as transmis un ordre dont tu connaissais le risque mais pas l’étendue finale.","anchors":"Tu connais au moins un fait qui fragilise une lecture trop simple de l’affaire.","position":"Défends exactement ta responsabilité : ni moins, ni plus.","chronology":"Ta chronologie comporte une décision avant le point de rupture, puis une réaction après."},{"hide":"Le détail précis qui ferait immédiatement comprendre ta part réelle de responsabilité.","place":"Tu as participé matériellement à une opération puis falsifié un rapport.","anchors":"Tu connais au moins un fait qui fragilise une lecture trop simple de l’affaire.","position":"Défends exactement ta responsabilité : ni moins, ni plus.","chronology":"Tu es présent dans une fenêtre critique mais tes actes ne couvrent pas toute la chaîne."},{"hide":"Le détail précis qui ferait immédiatement comprendre ta part réelle de responsabilité.","place":"Tu avais l’autorité d’interrompre une étape mais les informations reçues étaient incomplètes.","anchors":"Tu connais au moins un fait qui fragilise une lecture trop simple de l’affaire.","position":"Défends exactement ta responsabilité : ni moins, ni plus.","chronology":"Tu modifies ensuite une partie de ton récit pour protéger une responsabilité secondaire."}],"protected":[],"field_actions":[],"expert_actions":[]}$igr$::jsonb, now())
on conflict (scenario_id) do update set pack=excluded.pack, updated_at=excluded.updated_at;


