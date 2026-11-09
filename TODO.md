# TODO — audit fixes

> **État réel au 2026-11-07.** Deux choses différentes portent le nom « router »
> et la section ci-dessous ne parlait que de la première :
>
> 1. **Le relais Python de ce widget** (`router/relay.py`, `Router.js`,
>    l'unité `*-llamacpp-router.service`) — **retiré**, comme décrit plus bas.
> 2. **Le router natif de llama-server** (`--models-preset` + `models.ini`) —
>    **revenu et actif** : c'est le bouton « Router: ON/OFF » de la page Server
>    (llama.cpp seulement, modifiable serveur arrêté), piloté par `routerMode`
>    et `ModelsIni.js`. Le cache de prompt est désactivé dans ce mode.
>
> Autrement dit, « le relais est retiré » reste vrai, mais « le panneau ne lance
> qu'un llama-server direct » ne l'est plus. README.md décrit les deux modes.

## Retirement du relais Python — étapes 1 à 4 terminées (2026-11-05)

Fait, d'après PLAN.md : le panneau ne lance plus de relais Python intermédiaire.
(Le router *natif* de llama-server, lui, est un mode à part — voir l'encadré.)

- [x] `routerMode`/`directLaunch`/`routerDesired` supprimés ; start/stop/
      switch/restart sans branche relais ; `maybeAutoResume`/autoResumeTimer
      avec lui.
- [x] `Router.js` et tests relais supprimés du chargement ; `settings.json`
      n'écrit/lit plus `routerDesired` (clé ignorée si déjà présente).
- [x] Sweep de migration : Start/Stop retirent aussi l'ancienne unité
      `*-llamacpp-router.service` ; lancement avec
      `--property=Restart=on-failure` (l'unité directe survit à un crash).
- [x] Ancienne unité relais stoppée et supprimée de `~/.config/systemd/user/`.
- [x] Dossiers `router/` et `spike/` supprimés du dépôt.
- [x] Documentation et README mis à jour pour le mode direct persistant.
- [x] Extraction du `slot` dans `parseTimingLine` et `parsePromptProgressLine` (Model.js).
- [x] Indexation par instance supportée dans `Backends.unitName` et `Backends.procMarker`.
- [x] Tests verts (135), `omarchy plugin validate .` passe sans erreur.
- [x] Étape 6 du plan : multi-instances complet dans l'UI (`instanceCount`, défaut 1),
      load/unload par ligne, fork par instance, stats agrégées de l'icône de barre.
      `Instances.js` (pur, testé) + `InstanceRunner` par index > 0 ; l'index 0
      reste le serveur géré par les propriétés du panel (cycle restart, logs,
      hooks, cache KV).
- [x] System One devient un compagnon : tourne en parallèle du serveur de chat,
      sur son propre port (réservé dans l'allocation des instances) et son
      propre build — un fork ancien pour le chat, llama.cpp à jour pour les
      modèles de décision. Plus un choix de backend.
- [ ] Reste de l'étape 6 : la carte de survol (`PopupCard`) montre encore les
      seules métriques de l'index 0 — une ligne par instance (modèle, fork,
      port, t/s, pp%) reste à faire.
- [ ] Un `.tmp` de slot abandonné (instance détruite pendant une sauvegarde)
      n'est balayé par rien : `Model.slotFilePrefix` n'accepte que
      `*.slot<N>.bin`.
- [ ] i18n : le plugin n'a pas de `i18n/` et n'utilise pas `Commons.Translations`
      (Omarchy tourne en 50 langues, cf. le guide des plugins). ~200 chaînes à
      extraire en clés — chantier à part.

Working checklist for the 20 findings in the 3.3.0 audit. Each item is done when
the code is changed and the test suite still passes.

## Must fix

- [x] **1. Finish System One.** Wire settings (`setWidgetSetting`), the model
      scan (reuse the main scan when the directory is blank), the binary
      fallback (`activeSystemoneBinary`), `launchModel`, persistence, and add
      `systemone` to `installedBackends`.
- [x] **2. `systemoneLaunchArgs`.** Append `extraPieces` once, not once per
      piece. Remove `envPrefix` from argv; the caller prepends it as a shell
      prefix like the llama.cpp branch.
- [x] **3. Stop during startup.** Treat `root.starting` as a reason to run
      `finishStop()` so the unit is actually stopped.
- [x] **4. Unsupported-flag feature.** Emit `flags` from `llama_builds.py`;
      delete `Backends_flags.js` and the nonsense triple loop in
      `rowHasIgnoredFlag`. Keep the ⚠ row working.

## Should fix

- [x] **5. KV cache collision.** Add a short hash of the full model path to
      `slotPrefix`; update the test.
- [x] **6. Stop hang.** Put an overall deadline on `slot_kv.py` save/restore
      instead of 120 s/300 s per slot.
- [x] **7. Restart on change.** Support ollama (compare a launch hash) and
      System One; skip the `/slots` drain wait for log-mode backends.
- [x] **8. `OLLAMA_MODELS`.** Do not pass the GGUF `modelsDir` to ollama unless
      it is an ollama store; otherwise use the resolved store.
- [x] **9. ollama extra args.** Name unknown ollama parameter rows in a visible
      warning instead of letting `envPrefix` drop them silently.
- [x] **10. Unbounded scan.** Add a max depth to `refreshModels`, align the
      Settings count, and keep the two consistent.
- [x] **11. GGUF string cap.** Cap `read_str` at 1 MiB and seek past the rest;
      add a test.
- [x] **12. Search results.** Cap the flat search result list (or virtualize)
      so 1,000+ matches do not instantiate 1,000 delegates.
- [x] **13. Log model.** Use a `ListModel` with append/remove instead of
      replacing the 400-line array on every line.
- [x] **14. Untested risky logic.** Add tests for `systemoneLaunchArgs`, the
      model tree, the GGUF cap, and the ollama digest check.
- [x] **15. Autosave I/O.** Raise the debounce so continuous agent use does not
      rewrite the whole KV cache every 25 s.
- [x] **16. Non-systemd adoption.** Detect ownership with the process marker
      when `systemd-run` is unavailable, so Stop stays enabled.

## Nice to have

- [x] **17. Dead code and stale docs.** Delete `Backends_flags.js`,
      `stopCommand`, `systemoneUrl`, the duplicate `script =` line, the unused
      `cmd` build, the always-true `surviveRestart` branch, and `PLAN.md`.
      Rename `SYSTEONE` to `SYSTEMONE`.
- [x] **18. Slot save race.** Wait for an in-flight autosave before the stop
      save (or use a unique temporary suffix).
- [x] **19. Settings flush.** Flush settings in `Component.onDestruction` so a
      quick shell restart does not lose the last edit.
- [x] **20. Ollama digest.** Validate `sha256:<64 hex>` before joining the blob
      path.

## Follow-up audit (fixed)

- [x] **1. Stop on an external server.** `stopServer()` runs even when
      `canStop` is false; guard it and do not fire the `stopped` hook.
- [x] **2. System One overrides.** Pass `propOverridden` to
      `systemoneLaunchArgs` in both call sites.
- [x] **3. Debug logging.** Delete the per-key `console.log` in `NumField`.
- [x] **4. Rescan on open.** Reuse the last model scan instead of walking and
      probing the library on every panel open.
- [x] **5. Stale scan results.** Tag scans and ignore callbacks from an older
      backend/scan.
- [x] **6. Stuck `scanning`.** Clear it on the no-model-folders early return.
- [x] **7. Search cost.** Cache the flat file list; do not rebuild it on every
      keystroke.
- [x] **8. IPv6 loopback.** Do not warn for `[::1]`.
- [x] **9. Tree counts.** Count while labelling instead of one walk per folder.
- [x] **10. System One binary.** Probe it and offer Restart when it changes.
- [x] **11. Build probe.** Shorter timeout, candidates described in parallel.
- [x] **12. Stop logic tests.** Extract the stop decision into a pure helper and
      test it.
- [x] **13. Hook models.** Send every model on every backend, as the README
      promises.
- [x] **14. Flag backstop.** Do not treat an argv value as an emitted flag.
- [x] **15. Dead exports.** Remove exports nothing calls.
- [x] **16. French comments.** Remove the leftover step notes.
- [x] **17. `inferType`.** Compute once per parameter.
- [x] **18. `cacheRamMb`.** Remove the dead plumbing.

## System One in the main UI (done)

- [x] **Model page.** Lists and selects the active backend's model; System One
      uses its own directory when one is configured.
- [x] **Profiles.** Keyed by the model the server launches, not the chat model;
      a profile left under the old key is moved over on load.
- [x] **Scanning.** A separate System One model directory is scanned on open and
      on backend switch, and the page shows its own scanning state.

## Tuning page fixes (done)

- [x] **Row removal.** The added-parameter row's hover area sat above its ✕ and
      swallowed the click; it sits below now, like every built-in row.
- [x] **Flags per model.** Profiles key on the model the backend launches, so
      each model keeps its own values and an untouched model loads the
      defaults; profiles left under the old key are rekeyed on load.

## External MTP drafts (done)

- [x] **Not models.** A GGUF named after its draft (`*mtp*`) is split out of the
      scan and mapped by directory, like an mmproj file.
- [x] **Automatic.** The draft is passed with `--model-draft` and the spec type
      is set to `draft-mtp` when the model has no choice of its own.

## Done when

- `node --test tests/*.test.js` passes.
- `omarchy plugin validate .` passes.
- The server still starts, stops, restarts and restores its cache.
- The README matches the code (System One works; flag dropping works).

## Native router integration — service (in progress)

- [x] **Sleep is out of the design.** No `--sleep-idle-seconds`; the relay owns
      idle unload so it can save prompt-cache slots first.
- [x] **Pure repair planner** (`Service.js`, tested): missing/stale unit →
      write + daemon-reload, failed → reset-failed, unhealthy active → restart,
      start/stop to match the desired state, enable/disable for persistent
      units, and `activating` is left alone.
- [ ] **Wire the planner into the relay lifecycle.** Panel observes
      `LoadState/ActiveState/UnitFileState` + endpoint health, applies the
      plan, and reports the repaired state.

## Native router wiring (in progress)

- [x] `Router.js` builds the relay JSON from the scanned catalogue and the
      selected model's tuned argv (per-build grouping, ports, env, unit).
- [x] `router/relay.py` owns the public port, writes per-build INI presets,
      keeps one router per build and switches builds with drain.
- [x] Panel lifecycle: persistent `*-router.service`, start/stop/restart,
      adoption, journal, health, `repair` IPC, stale unit cleanup.
- [x] Tests: `Router.js` (6), `Service.js` (10), relay end-to-end (4).
- [x] Every model's profile is rendered into its preset; the selected model
      is no longer special.
- [x] Profiles are stored per model × build, with the common model profile as
      the shared fallback (`Profiles.resolveFor`).
- [x] Prompt cache through the relay: save before stop/build switch, restore
      once on the model's first request; `KillMode=mixed` so the relay can
      save before systemd tears the router down.
- [x] Real multi-build switch validated: upstream LFM3 ↔ turboquant Qwen3.5,
      two routers, distinct presets, slot save/restore across the switch.
- [x] Router flags are filtered per build (turboquant 0.6 rejects
      `--models-memory-margin`), and every GET (props/metrics/slots) is
      passive so the panel's polls cannot drag the relay back to a build.
- [ ] Per-build env from profiles — deliberately global for now.
- [x] `Service.plan()` is wired to observed `LoadState/ActiveState/UnitFileState`
      and health; desired running state is persisted as `routerDesired`.

## Passe design / QoL (2026-11-07)

- [x] **Marque de barre.** `BAR_ICON` passe de « AI » à un glyphe Nerd Font
      serveur (U+F233) : `WidgetButton.isIconGlyph` lui donne la fente d'icône
      de la barre, donc la marque s'aligne enfin sur les autres widgets.
- [x] **Point de statut.** Un point sur la marque distingue arrêté / démarrage /
      actif-au-repos, invisible dès qu'un débit s'affiche (le chiffre le dit
      déjà). Règle l'ambiguïté « `AI` = arrêté ou lancé mais inactif ? ».
- [x] **Largeur de barre stable.** `TextMetrics` mesure le plus long relevé
      possible ; le bouton tient cette largeur tant qu'un chiffre s'affiche, donc
      la barre ne respire plus à chaque token.
- [x] **Découvrabilité du clic droit.** La carte de survol rappelle ce que font
      clic et clic droit, au lieu de ne l'écrire que dans le README.
- [x] **Changement de backend à chaud.** Le picker n'est plus désactivé pendant
      l'exécution : `requestBackend` arrête le serveur courant (donc la bonne
      unité, cache sauvegardé), bascule le backend une fois l'arrêt terminé, puis
      démarre dès que le nouveau backend a un modèle (`maybeAutoStartSwitched`).
- [x] **Re-run setup.** Action dans Settings ; l'appel IPC du README n'était pas
      découvrable.
- [x] **Ménage du cache de prompt.** Settings affiche la taille occupée et
      propose de supprimer les slots orphelins. Logique pure et testée
      (`Model.slotOrphans`, 10 tests) ; l'offre n'apparaît qu'avec un catalogue
      non vide, et seuls les fichiers nommés sont supprimés.
- [x] **Docs réconciliées** avec le retour du router natif (README, TODO,
      manifest).
- [x] Sparkline : branche `if/else` identique supprimée.

## Démarrage auto + lisibilité des débits (2026-11-07)

- [x] **Start on login.** Bascule sur la page Server (`startOnLogin`, persistée
      dans `settings.json`). Le widget démarre son propre serveur — pas une
      unité systemd séparée, qui deviendrait obsolète dès que le tuning, le
      modèle ou le build change. En mode router, démarre le router.
- [x] **Déclenchement sans polling.** `autoStartReady` est un binding sur toutes
      les conditions (settings, sondes capacités/builds, binaire résolu, modèle
      si nécessaire) ; `onAutoStartReadyChanged` arme un timer de 3 s.
- [x] **Un seul tir par session** (`autoStartDone`) : un Stop manuel n'est pas
      défait par un changement ultérieur d'une des entrées.
- [x] **Garde anti-écrasement.** `adoptProbed` attend la réponse de la sonde
      d'adoption, puis `systemctl --user is-active` tranche avant de lancer :
      un serveur déjà debout mais encore en chargement ne répond pas à
      `/health`, et démarrer là-dessus balayait l'unité et jetait un
      chargement presque terminé.
- [x] **Carte de survol.** Le débit du prompt et sa progression s'affichent
      désormais **ensemble** (nombre + barre de progression animée) ; avant,
      l'un chassait l'autre. Légende ajoutée au sparkline, qui ne trace que la
      génération.

### Reste de cette passe

- [ ] **Découper `Panel.qml` (≈8 900 lignes).** Les trois pages
      (`currentPage === 0/1/2`) sont les candidats évidents à
      `ServerPage.qml` / `ModelPage.qml` / `TuningPage.qml`. Non fait ici :
      un fichier QML séparé perd l'accès à `root.*` et aux `component` inline,
      ce qui impose de recâbler des milliers de lignes — à faire page par page,
      en rechargeant le shell entre chaque, pas d'un bloc.
- [ ] **`routerMode` est écrit à deux endroits.** `setWidgetSetting("routerMode",…)`
      l'écrit dans `shell.json`, où *rien* ne le relit (la clé est absente du
      schéma du manifest) ; la valeur qui fait foi est celle de
      `settings.json` (lue dans `loadSettings`). Choisir une seule source.
- [ ] **`PLAN.md` existe encore** alors que le point 17 plus bas le déclare
      supprimé.

## Remaining for the release

- [x] Auto-resume a `routerDesired=true` service after a shell restart.
- [x] Router-mode indicator + explicit fallback to the direct launcher.
- [ ] Merge `feat/native-router` into `main`; decide the `origin/main` force-push.
