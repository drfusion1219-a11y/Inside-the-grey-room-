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
