# PLAN — abandon du relais, llama-server direct permanent

Date : 2026-11-05. Rédigé comme contexte de reprise : relire ce fichier en entier
avant de toucher au code (tous les chemins renvoient aux lignes observées ce
jour-là ; vérifier avant d'éditer).

## Pourquoi

Le mode "router" (défaut du backend llamacpp : `routerMode = !directLaunch`,
Panel.qml `~942`) fait passer chaque requête par `router/relay.py`. En pratique :

- latence ajoutée par le relais sur les requêtes adressées directement au port,
- gestion boiteuse des requêtes longues au moment des switchs de build,
- deux couches (relais + llama-server) à débugger, un journal à deux mains,
- un INI de preset par build à maintenir (`router/relay.py`), là où le path
  direct lance déjà exactement le flag set du profil.

Décision : le relais disparaît. À la place :

- **Le dernier llama-server lancé reste en place** (service user persistant,
  comme le relais aujourd'hui) : il sert sur `host:port` jusqu'à ce qu'on le
  remplace. Pas de proxy, pas de détournement de requête.
- **Chaque modèle garde son profil par fork** (déjà en place :
  `Profiles.keyFor` = `backend::model::build::<exe>`, settings.json
  `profiles`). Un modèle sans profil tourne sur les defaults du backend.
- Un **changement de modèle/test de build** = le chemin direct existant :
  drain des slots (attendre que plus aucune requête tourne, ou bouton
  "Force"), save du KV cache (`slot_kv.py save`), stop de l'unité, start avec
  le nouvel argv, restore du cache dès `/health` 200. La mémoire du prompt
  passe donc toujours le changement, sans relais d'aucune sorte.

Ce qui est déjà là et sert tel quel :

- `startServer/stopServer/switchServer` (Panel.qml `3369+`, `3917+`) : drain,
  save, unité, restart, restore. C'est le nouveau chemin unique.
- `configChanged` (`1023`) + bouton Restart : compare l'argv affiché à l'argv
  lu dans /proc. En router-mode c'était trivial (source unique) ; direct,
  ça marche déjà (le serveur EST l'argv).
- Migration legacy, profils par model×build, GGUF probes, MTP/mmproj.
- `readRunningArgs` (`3860`) : relire `/proc/<pid>/cmdline` après un restart
  shell → l'argv réel redevient la source de vérité de "ce qui est chargé".

## Ce qui change

### 1. Supprimer le relais

- `Router.js`, `router/relay.py`, `slot_kv.py` reste, les tests `router.test.js`
  et les fixtures relais partent ; `service.test.js` reste (utilitaire de plan
  génération `Service.plan`, conservé pour l'unité llama-server).
- `routerMode` (`942`) meurt : `startServer` ne ramifie plus sur
  `startRouter/restartRouter/stopRouter` (`3141-3313`, `3918`).
- Les blocs `routerCtlProc`, `routerServiceProbe`, `applyRouterRepair`,
  `maybeAutoResume` (partie `routerDesired`), `writeRouterFiles`,
  `routerConfigFile`, `routerUnitFile` (`2054-2068`) : à retirer.
- Settings supprimés/obsolètes : `routerDesired` (settings.json), le fichier
  `router.json`, `router/` dans `~/.local/state/omarchy/<plugin>/`
  (config.yaml, presets, slots gérés par le relais). Ne pas supprimer
  `slots/` : c'est là que `slot_kv.py` écrit les caches (placeholder
  `slotPrefix`), réutilisé tel quel par le chemin direct.
- L'unité `*-llamacpp-router.service` : laisser tournante sur les machines
  qui en ont un, mais à l'adoption, si elle est active et que le mode direct
  démarre → la stopper puis `reset-failed` (sinon deux processus convoitent le
  port et le health check采纳 le mauvais).
- `manifest.json` : retirer le setting `directLaunch` (il devient la seule
  façon de tourner). Garder la clé dans les settings existants (ignorée)
  afin de ne pas cracher au reload.

### 2. Une llama-server persistant par lancement

- Le path direct actuel lance via systemd *transient* (`ownsUnit`, `unitName`,
  `Backends.unitName`, `systemd-run` ou `setsid` en fallback). Le garder mais
  passer l'unité en **régulière, persistante, `Restart=on-failure`** — c'est ce
  que le relais garantissait (auto-resume après reboot shell). `Service.plan`
  si besoin pour l'opérateur ; sinon juste un `unit file` stable écrit une fois
  par fork (comme les presets INI du relais le faisaient pour les builds :
  un `[Unit]`/`[Service]` par binaire llama-server, exécutable + ExecStart
  template en longueur, où les flags de modèle viennent de l'argv de start).
  Minimal : rester en transient + `Restart=on-failure` via properties sur le
  transient (systemd-run `--property=Restart=on-failure`), suivis par le
  `unitWatchTimer` déjà en place.
- `toggleLaunchMode` (`3215`) meurt, de même que l'indicateur "· router" du
  hero (`4517`) et la phrase "router mode does not save slots" (`savesSlots`
  `3915` : la condition `!root.routerMode` tombe, les slots redeviennent
  sauvés pour tout le monde) — vérifier que `slot_kv.py` est bien appelé là où
  le relais le faisait, via `slotKvCommand` déjà utilisé dans le path direct.
- README et `docs/` : réécrire la section "Native router integration".

### 3. Le \"dernier fork lancé est gardé\" 

- Rien d'autre à ajouter pour « le dernier lancé reste en place » : un
  serveur tournant
  reste en place jusqu'à ce que l'utilisateur change de modèle ou de build au
  panneau, changement qui traverse `switchServer` (drain → save → restart →
  restore). Le fork d'un modèle non sélectionné n'est jamais pré-lancé : un
  llama-server s'exécute sur un modèle et un build précis, alors le faire
  tourner \"d'avance\" coûterait VRAM pour rien.
- Le changement **build** avec le même modèle fait partie du même chemin :
  `resolvedBuild.real` vs `runningExe` déjà comparés dans `configChanged`
  (`1030-1035`).
- Conséquence : quand deux modèles (forks différents) alternent souvent, un
  cache KV par modèle×fork est déjà prévu par `slotPrefix` (model + court hash
  du chemin). Rien à ajouter.

## Multi-instances : la main sur le serveur (décidé le 05/11)

Le relais part, et **le nombre de llama-servers simultanés devient un
paramètre utilisateur** (`instanceCount`, défaut `1`, manifest + settings).
Chaque instance est un llama-server persistant autonome :

- **Identité d'une instance** : index `n` (0..instanceCount-1), unité
  `io-github-syjohnm.local-ai-server-llamacpp-<n>.service` (transient, comme
  aujourd'hui ; `Backends.unitName` est paramétré par suffixe), port alloué
  `portBase + n` (`backendPorts` existe déjà dans les settings — l'instance
  0 garde le port actuel), argv = celui du modèle qu'on lui a donné :
  llama-server lancé avec son profil model×build résolu par
  `Profiles.resolveFor`.
- **Le "fork du router" devient le fork de l'instance** : changer de build =
  restart de l'unité avec l'argv du fork choisi (save/restore cache si le
  modèle est le même ; sinon cache par modèle×fork géré par `slotPrefix`).
- **Load / unload** :
  - *Load* un modèle (depuis la liste du Model page, bouton par ligne) :
    charge sur l'instance choisie (défaut : la première libre, sinon
    remplacer l'instance sélectionnée), avec drain avant remplacement.
  - *Unload* : stop de l'unité après drain, save du KV avant (bouton
    "Force" pour couper tout de suite).
- **UI** (Server tab, sous le hero) : liste des instances tournantes —
  modèle, fork, port, état (starting/running/t/s), actions par ligne :
  arrêter (unload), changer de fork (menu des builds), redémarrer ; et une
  ligne "libre" prête à charger à la demande. Le Model page garde le choix
  du modèle/du build, mais son bouton Start charge sur l'instance
  sélectionnée (défaut 0) plutôt que "le" serveur.
- **Bar icon / stats** : `handleServerLine` et le poll `/slots` passent par
  instance — le cas « 2 requêtes simultanées » frappé plus haut devient le
  cas nominal : chaque instance a son `activeUnitName`, son journal, son
  host:port. Icône = somme des t/s actifs (détail au hover : une ligne par
  instance). L'état passe de props singleton à une ListModel `instances` ;
  le code du panel existant est traité comme « instance 0 » en premier
  temps, puis généralisé.
- **Adoption après restart du plugin** : ajouter n au balayage — pour chaque
  index, health check `host:portBase+n` + lecture `/proc/<pid>/cmdline` via
  `procMarker` ; l'argv réel réhydrate l'instance (modèle, fork, flags).
  Point clé : ce réhydrate EST la réponse au bug « tunings invisibles après
  restart du plugin » — un serveur qui tourne au moment du load rend les
  valeurs de la page depuis son argv réel, sans attendre le profil.
- **Settings** : `instanceCount` persiste ; réduire le nombre arrête les
  instances de trop.

## Ordre des étapes (chaque étape laisse le dépôt en état de passer les tests)

1. **Brancher "direct" comme défaut unique sans toucher au reste** : basculer
   `directLaunch` à `true` par défaut dans `manifest.json`, `routerMode`
   devient toujours false. Les fonctions routeur restent mais sont inactives.
   Confirmer : start/stop/switch/slot-save avec les deux backends de test.
2. **Adoption migrée** : `adoptRunningServer`/`unitOwnerProc` traitent l'unité
   relais active comme \"à stopper en douceur\" si on passe en direct, et
   lisent l'argv du llama-server sous-jacent plutôt que celui du relais (au
   jour le jour : le PIDs sont les llama-server的孩子 du relais, déjà ce que
   `runningArgsProc` chasse via `procMarker`, pas l'unité MainPID — vérifier
   le cas stepper unit !).
3. **Nettoyage** : retirer Relay/Router + UI rémanente (indicateur, toggle),
   manifest, docs ; supprimer `routerDesired` des settings à la volée (le
   lecteur ignore les clés inconnues).
4. **Unité persistante** : ajouter `Restart=on-failure` au transient et
   réutiliser `unitWatchTimer` pour resurer `running` sur un crash.
5. **Test suite** : `node --test tests/*.test.js` (router.test.js détruit),
   `omarchy plugin validate .`, smoke manuel : start → 2 requêtes concurrentes
   → switch → cache restauré → prompt rechargé en secondes.
6. **Multi-instances** : `instanceCount` (défaut 1) — unité/port/état par
   index, ListModel d'instances, santé + /proc par index, UI de liste
   (unload/switch fork/restart par ligne), stats agrégées, adoption
   multi-index. La suite log threadée par instance arrive du même chantier
   (un Process tail par unité, plafonné par `logLinesMax`).
7. Bump version (3.7.0), screenshot nouveau README optionnel.

## Points de friction connus (à trancher en écrivant le code)

- **adoption du transient direct vs fallback setsid** : `hasSystemdRun=false`
  n'a pas d'unité, `restart on failure` ne peut pas venir. Accepté : ce chemin
  est résiduel (machine sans systemd user).
- **Slot drain** : le relais gérait le drain complet avant les switchs de
  build ; en direct, `switchServer` attend déjà `slotsBusy` à false via
  slotsPollTimer. Vérifier que ce timer est lancé pour le backend direct
  également (il l'est via `startMetrics` ? à confirmer au codage).
- **Port** : en relais, le relais tenait le port public et les llama-servers
  prenaient des ports privés. En direct, `port` devient le port du llama-server
  lui-même ; les anciens presets config.yaml mentionnaient un autre port —
  ne pas les relire, tout vient des settings/argv.
- **Adoption d'un serveur démarré porté par un ancien relais toujours actif**
  après migration : `adoptRunningServer` doit choisir le llama-server qui tient
  `host:port`, pas le relais qui écoute sur le même port. `procMarker` +
  `/proc` font le tri (le relais est python, pas touché par le marker
  llama-server).

## Hors périmètre ici (mais dans la liste ouverte)

Les trois demandes en attente se règlent à l'intérieur du chantier
multi-instances (étape 6) — les lignes ci-dessous donnent où :

- Stats/logs pour du stream concurrent : `parseTimingLine` /
  `parsePromptProgressLine` (Model.js `37/57`) gagnent un id de slot, et
  `handleServerLine` (Panel.qml `4287`) agrège le t/s par slot ; chaque
  instance a son Process tail → l'agrégation multi-instances est la somme.
- Tunings invisibles après restart : réhydratation par l'argv réel
  (`readRunningArgs` → `Params.fromTokens`, même mécanique que
  `splitPastedArgs` Panel.qml `488`), par instance.
- Tooltip détaillé au survol de l'icône : une ligne par instance (modèle,
  fork, port, t/s, pp%).
