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
