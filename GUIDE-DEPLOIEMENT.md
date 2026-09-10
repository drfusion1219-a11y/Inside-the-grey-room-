# 🚀 Guide de Déploiement - The Grey Room

## ✅ Checklist avant déploiement

- [x] Code pushé sur GitHub (`inside-the-grey-room`)
- [ ] Variables Supabase configurées dans Vercel
- [ ] Base de données Supabase initialisée
- [ ] Application déployée et fonctionnelle

---

## 📝 Instructions détaillées

### 1️⃣ Vérifier GitHub

Ton code doit être sur : `https://github.com/dfusion1219/inside-the-grey-room`

Si ce n'est pas encore fait :
```bash
cd "C:\Users\Da\omniroute\Projet The Grey Room"
git init
git add .
git commit -m "🎭 Initial commit - The Grey Room"
git remote add origin https://github.com/dfusion1219/inside-the-grey-room.git
git branch -M main
git push -u origin main
```

---

### 2️⃣ Déployer sur Vercel

#### A. Importer le projet

1. Ouvre [vercel.com/new](https://vercel.com/new)
2. Clique sur **"Import Project"**
3. Sélectionne ton repo GitHub : `inside-the-grey-room`
4. Vercel détecte automatiquement **Vite**

#### B. Ajouter les variables d'environnement

**CRITIQUE** : Avant de cliquer sur "Deploy", ajoute ces 2 variables :

| Variable | Valeur |
|----------|--------|
| `VITE_SUPABASE_URL` | `https://jafjzvxhhqdlcjdctgen.supabase.co` |
| `VITE_SUPABASE_ANON_KEY` | `sb_publishable_JQzDc00FBvmJuIVO8WZAhA_CdzsLU_E` |

**Comment ajouter** :
- Dans la section "Environment Variables"
- Clique sur le champ, entre le nom de la variable
- Entre la valeur
- Coche : Production, Preview, Development
- Clique sur "Add Another" pour la 2ème variable

#### C. Lancer le déploiement

Clique sur **"Deploy"** et attends ~2 minutes.

Tu verras :
```
Building...
✓ npm install
✓ npm run build
✓ Deploying...
🎉 Success! https://inside-the-grey-room.vercel.app
```

---

### 3️⃣ Configurer Supabase

#### A. Accéder au SQL Editor

1. Va sur [supabase.com](https://supabase.com)
2. Ouvre ton projet (`jafjzvxhhqdlcjdctgen`)
3. Clique sur **"SQL Editor"** dans le menu

#### B. Exécuter le script de création

1. Clique sur **"New Query"**
2. Copie le contenu du fichier :
   ```
   inside-grey-room-supabase/inside_grey_room_supabase_ALL_CODE_AND_V3_SCENARIOS.sql
   ```
3. Colle dans l'éditeur SQL
4. Clique sur **"Run"**

Tu verras : `Success. 0 rows returned`

---

### 4️⃣ Tester l'application

1. Ouvre ton URL Vercel : `https://inside-the-grey-room.vercel.app`
2. Tu devrais voir : ✅ **Connexion établie avec succès !**
3. Teste :
   - Créer une partie
   - Voir les scénarios disponibles

---

## 🔧 Résolution de problèmes

### ❌ "Variables d'environnement Supabase manquantes"

**Cause** : Les variables ne sont pas configurées dans Vercel

**Solution** :
1. Va dans Vercel → Ton projet → Settings → Environment Variables
2. Ajoute `VITE_SUPABASE_URL` et `VITE_SUPABASE_ANON_KEY`
3. Redéploie : Deployments → ... → "Redeploy"

### ❌ "permission denied for table igr_v3_scenario_packs"

**Cause** : Le script SQL n'a pas été exécuté

**Solution** :
1. Va dans Supabase → SQL Editor
2. Exécute le script complet `inside_grey_room_supabase_ALL_CODE_AND_V3_SCENARIOS.sql`

### ❌ Build failed

**Cause** : Erreur de syntaxe TypeScript

**Solution** :
1. Teste localement : `npm run build`
2. Corrige les erreurs affichées
3. Push sur GitHub, Vercel redéploiera automatiquement

---

## 📱 Après le déploiement

### Mises à jour automatiques

Chaque fois que tu push sur GitHub :
```bash
git add .
git commit -m "🔧 Amélioration X"
git push
```

Vercel redéploiera automatiquement ! ✨

### URL personnalisée (optionnel)

Dans Vercel → Settings → Domains :
- Ajoute ton propre domaine
- Ou utilise l'URL gratuite `.vercel.app`

---

## 🎉 Résultat final

✅ Application en ligne 24/7  
✅ HTTPS automatique  
✅ Déploiements automatiques  
✅ Gratuit avec Vercel  

**URL finale** : `https://inside-the-grey-room.vercel.app`
