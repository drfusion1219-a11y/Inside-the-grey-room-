# 🎭 The Grey Room - Jeu de Rôle Multijoueur

Un jeu de rôle multijoueur basé sur des scénarios aléatoires avec intégration Supabase.

## 🚀 Déploiement sur Vercel

### Prérequis
- Un compte [Vercel](https://vercel.com) (gratuit)
- Un compte [GitHub](https://github.com) (gratuit)
- Votre projet Supabase déjà configuré

### Étapes de déploiement

#### 1. Créer un dépôt GitHub
```bash
# Initialiser Git
git init
git add .
git commit -m "Initial commit - The Grey Room"

# Créer un repo sur GitHub et le lier
git remote add origin https://github.com/VOTRE_USERNAME/the-grey-room.git
git branch -M main
git push -u origin main
```

#### 2. Déployer sur Vercel

1. Allez sur [vercel.com](https://vercel.com)
2. Cliquez sur "Add New Project"
3. Importez votre dépôt GitHub
4. Vercel détectera automatiquement Vite
5. **Important** : Ajoutez les variables d'environnement :
   - `VITE_SUPABASE_URL` = `https://jafjzvxhhqdlcjdctgen.supabase.co`
   - `VITE_SUPABASE_ANON_KEY` = `sb_publishable_JQzDc00FBvmJuIVO8WZAhA_CdzsLU_E`
6. Cliquez sur "Deploy"

Votre jeu sera accessible à l'URL : `https://your-project-name.vercel.app`

## 🎮 Développement local

### Installation
```bash
npm install
```

### Lancer le serveur de développement
```bash
npm run dev
```

### Vérifier la connexion Supabase
```bash
npm run check:supabase
```

### Build pour la production
```bash
npm run build
```

## 🗄️ Base de données Supabase

### Tables principales
- `igr_v3_rooms` : Salles de jeu
- `igr_v3_room_players` : Joueurs dans les salles
- `igr_v3_scenario_packs` : Scénarios disponibles

### Fonctions RPC
- `igr_v3_create_room(p_scenario, p_host_name)` : Créer une nouvelle salle
- `igr_v3_join_room(p_room_code, p_player_name)` : Rejoindre une salle
- `igr_v3_toggle_ready(p_player_id)` : Basculer l'état "prêt"

## 📱 Version Mobile (Future)

Pour transformer ce projet en application mobile :

```bash
# Installer Capacitor
npm install @capacitor/core @capacitor/cli
npx cap init

# Ajouter les plateformes
npx cap add android
npx cap add ios

# Build et sync
npm run build
npx cap sync
```

## 🔧 Technologies utilisées

- **Frontend** : Vite + TypeScript
- **Backend** : Supabase (PostgreSQL + Auth + Realtime)
- **Déploiement** : Vercel
- **Mobile** : Capacitor (optionnel)

## 📝 Licence

Projet personnel - 2026
