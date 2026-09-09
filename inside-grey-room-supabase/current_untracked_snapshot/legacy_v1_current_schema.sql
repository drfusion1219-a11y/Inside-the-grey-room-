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
