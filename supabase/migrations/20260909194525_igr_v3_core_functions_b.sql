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
