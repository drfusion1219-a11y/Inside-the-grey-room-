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
