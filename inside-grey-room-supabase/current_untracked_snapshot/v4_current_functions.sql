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
