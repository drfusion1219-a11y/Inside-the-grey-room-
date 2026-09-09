// src/main.ts
import { supabase } from './lib/supabaseClient';
import './styles.css';

// Variables globales
let currentRoomCode: string | null = null;
let currentPlayerId: string | null = null;

// Vérifier la connexion au démarrage
async function checkConnection() {
  const statusEl = document.getElementById('connection-status')!;
  
  try {
    // Test simple de connexion
    const { data, error } = await supabase
      .from('igr_v3_scenario_packs')
      .select('scenario_id', { count: 'exact', head: true });
    
    if (error && error.code !== 'PGRST116') {
      throw error;
    }
    
    statusEl.className = 'status success';
    statusEl.innerHTML = '<p>✅ Connexion établie avec succès !</p>';
    
    setTimeout(() => {
      statusEl.classList.add('hidden');
      document.getElementById('game-menu')!.classList.remove('hidden');
    }, 1500);
    
  } catch (error: any) {
    statusEl.className = 'status error';
    statusEl.innerHTML = `<p>❌ Erreur de connexion: ${error.message}</p>`;
  }
}

// Afficher le formulaire de création de salle
(window as any).showCreateRoom = async function() {
  document.getElementById('game-menu')!.classList.add('hidden');
  document.getElementById('create-room')!.classList.remove('hidden');
  
  // Charger les scénarios disponibles
  const select = document.getElementById('scenario-select') as HTMLSelectElement;
  const { data: scenarios, error } = await supabase
    .from('igr_v3_scenario_packs')
    .select('scenario_id, pack')
    .order('scenario_id');
  
  if (error) {
    select.innerHTML = '<option value="">Erreur de chargement</option>';
    return;
  }
  
  if (!scenarios || scenarios.length === 0) {
    select.innerHTML = '<option value="">Aucun scénario disponible</option>';
    return;
  }
  
  select.innerHTML = scenarios.map(s => {
    const pack = s.pack as any;
    const context = pack?.context || 'Contexte non disponible';
    return `<option value="${s.scenario_id}">${s.scenario_id} - ${context.substring(0, 50)}...</option>`;
  }).join('');
}

// Afficher le formulaire de connexion
(window as any).showJoinRoom = function() {
  document.getElementById('game-menu')!.classList.add('hidden');
  document.getElementById('join-room')!.classList.remove('hidden');
}

// Afficher la liste des scénarios
(window as any).showScenarios = async function() {
  document.getElementById('game-menu')!.classList.add('hidden');
  document.getElementById('scenarios-list')!.classList.remove('hidden');
  
  const content = document.getElementById('scenarios-content')!;
  content.innerHTML = '<div class="loader"></div>';
  
  const { data: scenarios, error } = await supabase
    .from('igr_v3_scenario_packs')
    .select('scenario_id, pack')
    .order('scenario_id');
  
  if (error || !scenarios) {
    content.innerHTML = '<p>❌ Erreur lors du chargement des scénarios</p>';
    return;
  }
  
  content.innerHTML = scenarios.map(s => {
    const pack = s.pack as any;
    return `
      <div class="mode-card" style="margin-bottom: 15px; cursor: default;">
        <h3>Scénario ${s.scenario_id}</h3>
        <p><strong>Contexte:</strong> ${pack?.context || 'Non disponible'}</p>
        <p><strong>Joueurs:</strong> ${pack?.min_players || '?'} - ${pack?.max_players || '?'}</p>
      </div>
    `;
  }).join('');
}


// Créer une nouvelle salle
(window as any).createRoom = async function() {
  const playerName = (document.getElementById('player-name') as HTMLInputElement).value.trim();
  const scenarioId = (document.getElementById('scenario-select') as HTMLSelectElement).value;
  
  if (!playerName) {
    alert('Veuillez entrer votre pseudo');
    return;
  }
  
  if (!scenarioId) {
    alert('Veuillez sélectionner un scénario');
    return;
  }
  
  try {
    const { data, error } = await supabase.rpc('igr_v3_create_room', {
      p_scenario: scenarioId,
      p_host_name: playerName
    });
    
    if (error) throw error;
    
    if (data && data.room_code) {
      currentRoomCode = data.room_code;
      currentPlayerId = data.player_id;
      showGameRoom();
    } else {
      alert('Erreur lors de la création de la salle');
    }
  } catch (error: any) {
    alert(`Erreur: ${error.message}`);
  }
}

// Rejoindre une salle existante
(window as any).joinRoom = async function() {
  const playerName = (document.getElementById('join-player-name') as HTMLInputElement).value.trim();
  const roomCode = (document.getElementById('room-code') as HTMLInputElement).value.trim().toUpperCase();
  
  if (!playerName) {
    alert('Veuillez entrer votre pseudo');
    return;
  }
  
  if (!roomCode) {
    alert('Veuillez entrer le code de la salle');
    return;
  }
  
  try {
    const { data, error } = await supabase.rpc('igr_v3_join_room', {
      p_room_code: roomCode,
      p_player_name: playerName
    });
    
    if (error) throw error;
    
    if (data && data.player_id) {
      currentRoomCode = roomCode;
      currentPlayerId = data.player_id;
      showGameRoom();
    } else {
      alert('Impossible de rejoindre la salle');
    }
  } catch (error: any) {
    alert(`Erreur: ${error.message}`);
  }
}

// Afficher la salle de jeu
function showGameRoom() {
  document.getElementById('create-room')!.classList.add('hidden');
  document.getElementById('join-room')!.classList.add('hidden');
  document.getElementById('game-room')!.classList.remove('hidden');
  
  const codeDisplay = document.getElementById('room-code-display')!;
  codeDisplay.textContent = currentRoomCode || '';
  
  loadGameState();
}

// Charger l'état du jeu
async function loadGameState() {
  if (!currentRoomCode) return;
  
  const content = document.getElementById('game-content')!;
  content.innerHTML = '<div class="loader"></div>';
  
  try {
    const { data: room, error } = await supabase
      .from('igr_v3_rooms')
      .select('*, igr_v3_room_players(*)')
      .eq('room_code', currentRoomCode)
      .single();
    
    if (error) throw error;
    
    const players = (room as any).igr_v3_room_players || [];
    
    content.innerHTML = `
      <div class="status">
        <h3>🎮 Statut de la partie</h3>
        <p><strong>Scénario:</strong> ${(room as any).scenario_id}</p>
        <p><strong>Statut:</strong> ${(room as any).status}</p>
        <p><strong>Joueurs:</strong> ${players.length}</p>
      </div>
      <div class="mode-card" style="margin-top: 20px;">
        <h3>👥 Liste des joueurs</h3>
        ${players.map((p: any) => `
          <p>${p.player_name} ${p.is_host ? '👑' : ''} ${p.is_ready ? '✅' : '⏳'}</p>
        `).join('')}
      </div>
    `;
  } catch (error: any) {
    content.innerHTML = `<p class="status error">❌ Erreur: ${error.message}</p>`;
  }
}

// Basculer l'état "prêt"
(window as any).toggleReady = async function() {
  if (!currentPlayerId) return;
  
  try {
    const { error } = await supabase.rpc('igr_v3_toggle_ready', {
      p_player_id: currentPlayerId
    });
    
    if (error) throw error;
    loadGameState();
  } catch (error: any) {
    alert(`Erreur: ${error.message}`);
  }
}

// Quitter la salle
(window as any).leaveRoom = function() {
  currentRoomCode = null;
  currentPlayerId = null;
  
  document.getElementById('game-room')!.classList.add('hidden');
  document.getElementById('game-menu')!.classList.remove('hidden');
}

// Retour au menu
(window as any).backToMenu = function() {
  document.getElementById('create-room')!.classList.add('hidden');
  document.getElementById('join-room')!.classList.add('hidden');
  document.getElementById('scenarios-list')!.classList.add('hidden');
  document.getElementById('game-menu')!.classList.remove('hidden');
}

// Démarrer l'application
checkConnection();
