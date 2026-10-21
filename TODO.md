# TODO — audit fixes

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

## Done when

- `node --test tests/*.test.js` passes.
- `omarchy plugin validate .` passes.
- The server still starts, stops, restarts and restores its cache.
- The README matches the code (System One works; flag dropping works).
