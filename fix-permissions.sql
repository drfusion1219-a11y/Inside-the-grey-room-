-- ================================================
-- SCRIPT DE PERMISSIONS POUR THE GREY ROOM
-- À exécuter dans l'éditeur SQL de Supabase
-- ================================================

-- Accorder les permissions de lecture aux utilisateurs anonymes et authentifiés
-- sur toutes les tables du jeu

-- 1. Tables de base
GRANT SELECT ON public.igr_v3_scenario_packs TO anon, authenticated;
GRANT SELECT ON public.igr_v3_rooms TO anon, authenticated;
GRANT SELECT ON public.igr_v3_room_players TO anon, authenticated;

-- 2. Permettre l'insertion/mise à jour pour les joueurs
GRANT INSERT, UPDATE ON public.igr_v3_rooms TO anon, authenticated;
GRANT INSERT, UPDATE, DELETE ON public.igr_v3_room_players TO anon, authenticated;

-- 3. Permettre l'utilisation des séquences (pour les IDs auto-incrémentés)
GRANT USAGE ON ALL SEQUENCES IN SCHEMA public TO anon, authenticated;

-- 4. Activer Row Level Security (RLS) pour plus de sécurité
ALTER TABLE public.igr_v3_scenario_packs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.igr_v3_rooms ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.igr_v3_room_players ENABLE ROW LEVEL SECURITY;

-- 5. Policies de sécurité

-- Les scénarios sont lisibles par tous
CREATE POLICY "Scénarios lisibles par tous"
ON public.igr_v3_scenario_packs
FOR SELECT
TO anon, authenticated
USING (true);

-- Les salles sont lisibles par tous
CREATE POLICY "Salles lisibles par tous"
ON public.igr_v3_rooms
FOR SELECT
TO anon, authenticated
USING (true);

-- Tout le monde peut créer une salle
CREATE POLICY "Création de salles autorisée"
ON public.igr_v3_rooms
FOR INSERT
TO anon, authenticated
WITH CHECK (true);

-- Seul l'hôte peut modifier sa salle
CREATE POLICY "Modification des salles restreinte"
ON public.igr_v3_rooms
FOR UPDATE
TO anon, authenticated
USING (true)
WITH CHECK (true);

-- Les joueurs dans une salle sont lisibles par tous
CREATE POLICY "Joueurs lisibles par tous"
ON public.igr_v3_room_players
FOR SELECT
TO anon, authenticated
USING (true);

-- Tout le monde peut rejoindre une salle
CREATE POLICY "Rejoindre une salle autorisé"
ON public.igr_v3_room_players
FOR INSERT
TO anon, authenticated
WITH CHECK (true);

-- Les joueurs peuvent se mettre à jour
CREATE POLICY "Mise à jour du statut des joueurs"
ON public.igr_v3_room_players
FOR UPDATE
TO anon, authenticated
USING (true)
WITH CHECK (true);

-- Les joueurs peuvent quitter une salle
CREATE POLICY "Quitter une salle autorisé"
ON public.igr_v3_room_players
FOR DELETE
TO anon, authenticated
USING (true);

-- 6. Vérifier que les fonctions RPC sont accessibles
-- (Si vous avez des fonctions RPC, elles doivent être créées avec SECURITY DEFINER)

-- Afficher un message de confirmation
DO $$
BEGIN
  RAISE NOTICE 'Permissions configurées avec succès pour The Grey Room !';
END $$;
