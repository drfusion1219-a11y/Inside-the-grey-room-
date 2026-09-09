# 🔧 Instructions pour déployer "The Grey Room"

Félicitations ! Votre projet est prêt pour le déploiement. Voici les étapes à suivre :

---

## 📋 Étape 1 : Corriger les permissions Supabase (IMPORTANT !)

Votre base de données Supabase nécessite des permissions pour que l'application puisse accéder aux tables.

1. Allez sur [supabase.com](https://supabase.com)
2. Ouvrez votre projet (`jafjzvxhhqdlcjdctgen`)
3. Dans le menu latéral, cliquez sur **"SQL Editor"**
4. Cliquez sur **"New Query"**
5. Copiez-collez le contenu du fichier `inside-grey-room-supabase/fix-permissions.sql`
6. Cliquez sur **"Run"** pour exécuter le script
7. Vous devriez voir : ✅ "Success. No rows returned"

**Ce script permet :**
- Lecture des scénarios pour tous les utilisateurs
- Création/modification de salles de jeu
- Gestion des joueurs dans les salles

---

## 🧪 Étape 2 : Tester localement

Une fois les permissions corrigées, testez votre application :

```bash
# Test de connexion Supabase
npm run check:supabase

# Lancer le serveur de développement
npm run dev
```

Ouvrez votre navigateur sur `http://localhost:5173` et testez :
- ✅ Créer une partie
- ✅ Rejoindre une partie
- ✅ Voir les scénarios disponibles

---

## 🚀 Étape 3 : Déployer sur Vercel

### Option A : Via GitHub (Recommandé)

1. **Créer un dépôt GitHub**
   ```bash
   git init
   git add .
   git commit -m "🎭 Initial commit - The Grey Room"
   ```

2. **Créer un nouveau dépôt sur GitHub**
   - Allez sur [github.com/new](https://github.com/new)
   - Nom : `the-grey-room`
   - Visibilité : Public ou Private
   - Ne cochez rien d'autre
   - Cliquez sur "Create repository"

3. **Pousser votre code**
   ```bash
   git remote add origin https://github.com/VOTRE_USERNAME/the-grey-room.git
   git branch -M main
   git push -u origin main
   ```

4. **Déployer sur Vercel**
   - Allez sur [vercel.com](https://vercel.com)
   - Cliquez sur **"Add New Project"**
   - Importez votre dépôt GitHub
   - Vercel détecte automatiquement Vite
   - **IMPORTANT** : Ajoutez les variables d'environnement :
     - `VITE_SUPABASE_URL` = `https://jafjzvxhhqdlcjdctgen.supabase.co`
     - `VITE_SUPABASE_ANON_KEY` = `sb_publishable_JQzDc00FBvmJuIVO8WZAhA_CdzsLU_E`
   - Cliquez sur **"Deploy"**

5. **Votre jeu sera en ligne en ~2 minutes !**
   - URL : `https://the-grey-room-VOTRE-USERNAME.vercel.app`

### Option B : Via Vercel CLI (Plus rapide)

```bash
# Installer Vercel CLI
npm install -g vercel

# Se connecter
vercel login

# Déployer
vercel

# Suivre les instructions et ajouter les variables d'environnement quand demandé
```

---

## 📱 Étape 4 : Transformer en application mobile (Optionnel)

Si vous voulez créer une vraie application Android/iOS :

```bash
# Installer Capacitor
npm install @capacitor/core @capacitor/cli
npx cap init "The Grey Room" "com.thegreyroom.app"

# Ajouter les plateformes
npx cap add android
npx cap add ios

# Build et synchronisation
npm run build
npx cap sync

# Ouvrir dans Android Studio ou Xcode
npx cap open android
npx cap open ios
```

---

## 🎮 Fonctionnalités actuelles

✅ Connexion à Supabase  
✅ Création de parties  
✅ Code de salle unique  
✅ Rejoindre une partie  
✅ Liste des joueurs en temps réel  
✅ Système de "prêt"  
✅ Sélection de scénarios aléatoires  

---

## 🔥 Alternatives gratuites à Vercel

Si vous préférez un autre hébergeur :

1. **Netlify** ([netlify.com](https://netlify.com))
   - Même concept que Vercel
   - Déploiement via Git
   - Très simple d'utilisation

2. **Render** ([render.com](https://render.com))
   - Gratuit pour les sites statiques
   - Certificats SSL automatiques

3. **GitHub Pages** (pour des projets simples)
   - Gratuit avec GitHub
   - Parfait pour des tests

4. **Cloudflare Pages** ([pages.cloudflare.com](https://pages.cloudflare.com))
   - Très rapide (CDN mondial)
   - Gratuit et illimité

**Note** : Vercel et Netlify sont les plus simples pour les projets Vite + Supabase.

---

## 🆘 Besoin d'aide ?

Si vous rencontrez des problèmes :

1. **Permissions Supabase** : Assurez-vous d'avoir exécuté `fix-permissions.sql`
2. **Variables d'environnement** : Vérifiez qu'elles sont bien configurées sur Vercel
3. **Build** : Testez `npm run build` localement pour voir les erreurs

---

## 📊 Prochaines étapes possibles

- 🔔 Notifications en temps réel avec Supabase Realtime
- 🎨 Améliorer l'interface graphique
- 🏆 Système de points et classement
- 💬 Chat intégré dans les parties
- 📊 Statistiques des joueurs
- 🌍 Support multilingue

Bon jeu ! 🎭
