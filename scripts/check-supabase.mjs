import { createClient } from '@supabase/supabase-js';
import dotenv from 'dotenv';

// Charger les variables d'environnement
dotenv.config();

const supabaseUrl = process.env.VITE_SUPABASE_URL ?? '';
const supabaseAnonKey = process.env.VITE_SUPABASE_ANON_KEY ?? '';

if (!supabaseUrl || !supabaseAnonKey) {
  console.error('❌ Variables d\'environnement manquantes dans .env');
  process.exit(1);
}

console.log('🔍 Test de connexion à Supabase...\n');
console.log(`URL: ${supabaseUrl}`);
console.log(`Clé (début): ${supabaseAnonKey.substring(0, 30)}...\n`);

const supabase = createClient(supabaseUrl, supabaseAnonKey);

async function checkConnection() {
  try {
    // Test 1: Vérifier l'accès à la table des scénarios
    console.log('📋 Test 1: Accès à la table igr_v3_scenario_packs...');
    const { data: scenarios, error: scenarioError, count } = await supabase
      .from('igr_v3_scenario_packs')
      .select('scenario_id', { count: 'exact', head: false });

    if (scenarioError) {
      console.error('❌ Erreur table:', scenarioError);
      console.error('   Code:', scenarioError.code);
      console.error('   Message:', scenarioError.message);
      console.error('   Détails:', scenarioError.details);
      console.error('   Hint:', scenarioError.hint);
      
      if (scenarioError.code === 'PGRST116') {
        console.log('⚠️  Table vide ou non trouvée (cela peut être normal)');
      } else {
        return false;
      }
    } else {
      console.log('✅ Connexion à la base de données réussie');
      console.log(`✅ Table igr_v3_scenario_packs accessible (${count || 0} scénarios)`);
      if (scenarios && scenarios.length > 0) {
        console.log('   Scénarios trouvés:', scenarios.map(s => s.scenario_id).join(', '));
      }
    }

    // Test 2: Vérifier une fonction RPC
    console.log('\n📋 Test 2: Fonction RPC igr_v3_min_players...');
    try {
      const { data, error } = await supabase.rpc('igr_v3_min_players', { 
        p_scenario: '001' 
      });

      if (error) {
        console.log('⚠️  RPC igr_v3_min_players:', error.message);
        console.log('   (Peut être normal si la fonction n\'existe pas encore)');
      } else {
        console.log('✅ Fonction RPC OK, résultat:', data);
      }
    } catch (e) {
      console.log('⚠️  Erreur RPC (non bloquant):', e.message);
    }

    console.log('\n🎉 Connexion Supabase opérationnelle !');
    return true;
  } catch (error) {
    console.error('\n❌ Erreur fatale:', error);
    return false;
  }
}

checkConnection()
  .then(result => {
    process.exit(result ? 0 : 1);
  })
  .catch(err => {
    console.error('❌ Erreur fatale:', err);
    process.exit(1);
  });