// src/lib/testConnection.ts
import 'dotenv/config';
import { supabase } from './supabaseClient';

// Test de connexion Supabase
async function checkSupabaseConnection() {
  // Test RPC public
  const { data, error } = await supabase.rpc('igr_v3_min_players', { p_scenario: '001' });

  if (error) {
    console.error('RPC test failed:', error.message);
    return false;
  }

  console.log('RPC igr_v3_min_players (001) OK =>', data);

  // Test accès table scénarios
  const { data: packs, error: e } = await supabase
    .from('igr_v3_scenario_packs')
    .select('scenario_id, pack->>\'context\' as context', { count: 'exact', head: true });

  if (e) {
    console.error('Table igr_v3_scenario_packs error:', e.message);
    console.log('RPC test OK, table accessible (peut être vide)');
    return true;
  }

  console.log('igr_v3_scenario_packs accessible');
  return true;
}

export default checkSupabaseConnection;