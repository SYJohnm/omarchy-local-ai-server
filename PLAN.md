# PLAN.md — Plugin Local AI Server : Support System One

## Architecture Actuelle

### Backend
- **llamacpp** : llama-server avec endpoint `/v1/chat/completions` (chat)
- **ollama** : ollama serve avec `/api/chat`
- Chaque backend a son propre port, son propre binary, son propre modèle

### Pages du Panel (4 onglets)
1. **Server** : backend selector (Dropdown), host, port, surviveRestart toggle, kvPersistence toggle
2. **Model** : modèle picker (SearchableDropdown), build selector (llamacpp only), directory scan (setup only)
3. **Tuning** : contrôles par modèle (cacheType, flashAttn, ngl, threads, ctxSize, etc.), "Apply detected defaults" button, "Set default" button
4. **Stats** : pp/t/s, tg/t/s, endpoint, hardware info

### Logs
- Overlay qui remplace les pages, non paginé, un seul flux journal

### Configuration (manifest.json)
- `backend` : enum (llamacpp / ollama)
- `binary` : path (llama.cpp preferred)
- `ollamaBinary` : path
- `altBinary` : path (extra llama.cpp)
- `modelsDir` : path

### Survive Restart
- Toggle dans Server page, activable/désactivable

---

## Architecture Cible

### Backend
- **llamacpp** : chat llama.cpp (port 8080 par défaut)
- **ollama** : chat ollama (port 11434 par défaut)
- **systemone** : decision models (port 8081 par défaut)
- Chaque backend a son **propre** llama.cpp binary, port, modèle, tuning

### Pages du Panel (3 onglets)
1. **Server** : accordion backend, model selector, host/port, dir scan, System One section
2. **Tuning** : contrôles adaptés au backend actuel (chat vs decision)
3. **Logs** : paginé (normal / systemone), overlay scrollable

### Stats
- Inline sur la status bar en haut (pp/t/s, tg/t/s déjà affichés)
- Stats page supprimée

### Configuration (manifest.json)
- `backend` : enum (llamacpp / ollama / systemone)
- `binary` : path (llama.cpp preferred for chat)
- `ollamaBinary` : path
- `systemoneBinary` : path (llama.cpp for systemone, peut être différent)
- `altBinary` : path (extra llama.cpp for chat)
- `modelsDir` : path (chat models)
- `systemoneModelsDir` : path (systemone models)
- `surviveRestart` : toujours on, retiré du manifest

---

## Étapes d'Implémentation

### 1. Backends.js — Ajouter SYSTEONE backend
- Ajouter `SYSTEONE` constant avec `id: "systemone"`, `defaultPort: 8081`, `healthPath: "/v1/systemone"`, `modelKind: "file"`
- Features : ngl, threads, cacheType, cpuMoe, loadMode, slotKv, extraArgs, parallel, envVars
- (pas ctxSize, pas speculative, pas vision, pas thinking — decision models)
- Ajouter `systemoneUrl()`, `systemoneLaunchArgs()`, `isSystemOne()`
- Mettre à jour exports
- Modifier `unitName()` pour `"systemone" → "sys1"`

### 2. manifest.json — Nouvelles settings
- Ajouter `"systemone"` dans les options de `backend`
- Ajouter `systemoneBinary` (path)
- Ajouter `systemoneModelsDir` (path)
- Retirer `surviveRestart` du schema (toujours on)
- Bump version à 3.1.0

### 3. Panel.qml — Backends.js imports
- Importer `isSystemOne`, `systemoneUrl`, `systemoneLaunchArgs` depuis Backends.js

### 4. Panel.qml — Backend selector accordion (Server page)
- Remplacer le Dropdown "Backend" par un accordion accordéon :
  - Cliquer sur le nom du backend (texte) ouvre/ferme le détail
  - Le détail contient : dropdown backend, host, port, model selector
  - L'accordion est toujours ouvert en mode Server
- Le backend name dans le header devient cliquable pour switch backend

### 5. Panel.qml — Model selector sur Server page
- Déplacer le SearchableDropdown Model dans la section Server
- Ajouter un bouton "⟳ Rescan" à côté
- Ajouter un sélecteur de directory (comme en setup) pour les chat models
- Stocker le directory scan dans `configuredModelsDir` (chat) ou `systemoneModelsDir`

### 6. Panel.qml — System One section (Server page)
- Toggle "System One" qui montre/cache la section System One
- Quand System One est actif :
  - Modèle picker pour systemone models (sélectionne `systemoneModel` property)
  - Directory picker pour `systemoneModelsDir`
  - Host/port (déjà séparés via backendPorts)
  - Binary selector (ou use systemoneBinary setting)
- Quand un model systemone est sélectionné, les tuning controls changent
  - Moins de contrôles (pas ctxSize, pas speculative, pas vision)
  - Garder : ngl, threads, cacheType, cpuMoe, loadMode

### 7. Panel.qml — Tuning page adaptative
- Garder la pagination tuning actuelle
- Retirer "Apply detected defaults" button
- Retirer "Set default" button (ou le garder ? — le user dit "on peut remettre une pagination générale", donc garder le "Set default")
- Adapter les contrôles visibles selon `isSystemOne(backend)` :
  - Hidden pour systemone : cacheType (f16 only), flashAttn, ctxSize, batchSize, specType, vision, reasoning
  - Visible pour systemone : ngl, threads, cacheTypeK/V, cpuMoe, loadMode

### 8. Panel.qml — Stats inline + suppression Stats page
- Les métriques (pp%, tg/t/s) sont déjà affichées dans le header status
- Retirer l'onglet "Stats" de `pageNames`
- Retirer tout le bloc `// Stats` de QML
- Mettre à jour `onTabRequested` pour le nouveau count de pages

### 9. Panel.qml — Logs paginés
- Remplacer l'overlay de logs par un système paginé :
  - Ajouter un ButtonGroup pour switcher entre "Normal" et "System One"
  - Chaque page a son propre logLines array
  - Le switch change `logsSource` entre les deux backends
  - Garder le scroll behavior actuel (stickToBottom, missedLines, etc.)
- Le bouton "Show log" ouvre cette vue paginée

### 10. Panel.qml — Survive Restart toujours on
- Retirer le Toggle "Survive restart" de Server page
- Garder `surviveRestart: true` comme valeur par défaut, retiré des settings
- Retirer `onSurviveRestartChanged` et la persistance

### 11. Panel.qml — Système de log par backend
- Ajouter `normalLogLines` et `systemoneLogLines` (ou un mapping backend → lines)
- Adapter `handleServerLine` pour router vers le bon flux selon `backend`
- Adapter `followJournal` pour le bon backend
- Adapter le health polling pour le bon endpoint

### 12. Panel.qml — Settings migration
- Adapter `loadSettings()` pour les nouvelles keys : `systemoneBinary`, `systemoneModelsDir`
- Adapter `flushSettings()` pour les sauvegarder
- Gérer la migration depuis les anciennes settings

### 13. Panel.qml — Launch systemone server
- Ajouter un handler pour start/stop systemone server
- `buildBackendScript()` doit gérer systemone avec `systemoneLaunchArgs()`
- Health polling pour systemone endpoint
- Adopt running server pour systemone

### 14. Test et vérification
- Vérifier que les deux serveurs peuvent tourner simultanément
- Vérifier le switch entre backends
- Vérifier la persistence des settings
- Vérifier les logs séparés

---

## Détails techniques importants

### État par backend
Actuellement, tout l'état est centralisé (un seul modèle, un seul tuning).
Nouvel état :
- `selectedModel` : modèle chat actif
- `systemoneModel` : modèle systemone actif
- Chaque backend a son propre set de tuning (déjà le cas via `profiles[backend]`)
- Chaque backend a son propre log lines array

### Architecture des logs
```
normalLogLines: []     → logs du chat backend (llamacpp/ollama)
systemoneLogLines: []  → logs du systemone backend
```
Le bouton "Show logs" ouvre une vue avec :
- Tabs : "Normal" / "System One"
- Chaque tab a son propre logLines, son propre scroll
- Le bouton "Show log" dans le footer devient "Show logs" (pluriel)

### Accordion backend
L'accordion est un composant QML dans la Server page :
```
RowLayout (clickable header)
  Text (backend name, onClicked: switch backend)
  Status indicator
Collapsible content (always visible in Server page)
  Dropdown (backend selector)
  TextField (host)
  NumField (port)
  SearchableDropdown (model picker)
  RowLayout (directory picker)
  Button (⟳ rescan)
```

### Tuning adaptatif
Les contrôles tuning sont filtrés par `isSystemOne(backend)` :
- Pour systemone : seulement ngl, threads, cacheTypeK/V, cpuMoe, loadMode, extraArgs, envVars
- Pour chat : tout le controle actuel

### Binary pour systemone
- `systemoneBinary` setting : chemin vers le llama.cpp pour systemone
- Peut être le même que `binary` (chat) si un seul build suffit
- Peut être différent si un fork spécifique est nécessaire (ex: IFM pour lev)
