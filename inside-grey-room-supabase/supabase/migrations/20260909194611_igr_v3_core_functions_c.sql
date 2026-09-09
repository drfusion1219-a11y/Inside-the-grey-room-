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
