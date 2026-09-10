# 🎭 The Grey Room

Jeu de rôle multijoueur avec scénarios aléatoires.

## 🚀 Déploiement sur Vercel

### Étape 1 : Pousser sur GitHub

```bash
git init
git add .
git commit -m "Initial commit"
git remote add origin https://github.com/VOTRE_USERNAME/inside-the-grey-room.git
git branch -M main
git push -u origin main
```

### Étape 2 : Importer dans Vercel

1. Allez sur [vercel.com](https://vercel.com)
2. Cliquez sur **"Add New Project"**
3. Sélectionnez votre repo GitHub `inside-the-grey-room`
4. **Important** : Ajoutez ces 2 variables d'environnement :
   - `VITE_SUPABASE_URL` → `https://jafjzvxhhqdlcjdctgen.supabase.co`
   - `VITE_SUPABASE_ANON_KEY` → `sb_publishable_JQzDc00FBvmJuIVO8WZAhA_CdzsLU_E`
5. Cliquez sur **"Deploy"**

⏱️ Temps de déploiement : ~2 minutes

### Étape 3 : Configurer Supabase

1. Allez sur [supabase.com](https://supabase.com) → Votre projet
2. Ouvrez **SQL Editor**
3. Exécutez le script SQL depuis `inside-grey-room-supabase/inside_grey_room_supabase_ALL_CODE_AND_V3_SCENARIOS.sql`

✅ C'est prêt !

## 🛠️ Développement local

```bash
# Installation
npm install

# Lancer le serveur
npm run dev

# Tester la connexion Supabase
npm run check:supabase
```

## 📦 Technologies

- Vite + TypeScript
- Supabase (PostgreSQL)
- Vercel (Hosting)
