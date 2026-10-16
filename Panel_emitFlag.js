    if (root.resolvedBuild && root.backend === "llamacpp") {
      // Parallel, reasoning, threads, MoE, context, batch, cache, temp
      if (!root.propOverridden("parallel") && String(root.parallel).trim() !== "")
        emitFlag(root.resolvedBuild, "--parallel", String(root.parallel).trim(), args)

      if (!root.propOverridden("reasoningPreserve")) {
        if (root.reasoningPreserve === "on") emitFlag(root.resolvedBuild, "--reasoning-preserve", "", args)
        else if (root.reasoningPreserve === "off") emitFlag(root.resolvedBuild, "--no-reasoning-preserve", "", args)
      }

      var threadCount = parseInt(root.threads, 10)
      if (!root.propOverridden("threads") && isFinite(threadCount) && threadCount > 0)
        emitFlag(root.resolvedBuild, "--threads", String(threadCount), args)

      // MoE flags are mutually exclusive in llama.cpp
      if (!root.propOverridden("nCpuMoe") && !root.propOverridden("cpuMoe")) {
        var nCpuMoeTrimmed = String(root.nCpuMoe).trim()
        if (nCpuMoeTrimmed !== "") emitFlag(root.resolvedBuild, "--n-cpu-moe", nCpuMoeTrimmed, args)
        else if (root.cpuMoe) emitFlag(root.resolvedBuild, "--cpu-moe", "", args)
      }

      if (!root.propOverridden("noRepack") && root.noRepack)
        emitFlag(root.resolvedBuild, "--no-repack", "", args)
      if (!root.propOverridden("specType") && root.specType !== "none")
        emitFlag(root.resolvedBuild, "--spec-type", root.specType, args)

      var ctxSize = parseInt(root.contextSize, 10)
      if (!root.propOverridden("contextSize") && isFinite(ctxSize) && ctxSize > 0)
        emitFlag(root.resolvedBuild, "--ctx-size", String(ctxSize), args)
      var batch = parseInt(root.batchSize, 10)
      if (!root.propOverridden("batchSize") && isFinite(batch) && batch > 0)
        emitFlag(root.resolvedBuild, "--batch-size", String(batch), args)
      var ubatch = parseInt(root.ubatchSize, 10)
      if (!root.propOverridden("ubatchSize") && isFinite(ubatch) && ubatch > 0)
        emitFlag(root.resolvedBuild, "--ubatch-size", String(ubatch), args)
      if (!root.propOverridden("cacheRam") && String(root.cacheRam).trim() !== "")
        emitFlag(root.resolvedBuild, "--cache-ram", String(root.cacheRam).trim(), args)
      if (!root.propOverridden("temperature") && String(root.temperature).trim() !== "")
        emitFlag(root.resolvedBuild, "--temp", String(root.temperature).trim(), args)
    }
