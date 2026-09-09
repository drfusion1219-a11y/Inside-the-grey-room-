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
