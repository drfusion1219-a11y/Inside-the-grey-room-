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
