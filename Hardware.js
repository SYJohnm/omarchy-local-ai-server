// Turns hw_probe.sh output into suggested launch parameters.
//
// This replaces the constants the plugin used to ship, which were bisected
// against one 4GB GTX 1650 and were wrong everywhere else. Suggestions are
// advisory: the UI prefills them and shows what they were derived from, and
// the user can always override.
//
// Pure logic, no I/O, so the arithmetic is unit-testable.

// VRAM the plugin refuses to allocate to weights, reserved for the KV cache,
// compute buffers and whatever the desktop is already displaying. Small cards
// need a proportionally larger cushion -- on a 4GB card the desktop alone can
// hold several hundred MB -- so this is a floor plus a fraction rather than
// a flat number.
function reservedVramMb(vramMb) {
  var v = Number(vramMb) || 0
  if (v <= 0) return 0
  return Math.max(512, Math.round(v * 0.18))
}

function parseProbe(jsonText) {
  var data
  try { data = JSON.parse(String(jsonText || "{}")) } catch (e) { data = {} }
  return {
    vendor: String(data.vendor || "cpu"),
    gpuName: String(data.gpuName || ""),
    vramMb: Number(data.vramMb) || 0,
    ramMb: Number(data.ramMb) || 0,
    cores: Number(data.cores) || 0,
    threads: Number(data.threads) || 0
  }
}

// Whether the CUDA-specific workaround env vars are worth setting. They are
// meaningless -- and potentially confusing -- on ROCm, Metal or CPU builds,
// so the original unconditional injection is now gated on this.
function isCuda(hw) {
  return (hw && hw.vendor) === "nvidia"
}

function hasGpu(hw) {
  return !!hw && hw.vendor !== "cpu" && hw.vramMb > 0
}

// Suggested -ngl.
//
// Returning -1 (llama.cpp's "fit as many layers as will fit" sentinel) is
// deliberately preferred over guessing a layer count: llama.cpp knows the
// model's per-layer size and this code does not. A concrete number is only
// suggested when there is so little usable VRAM that offloading is pointless.
//
// Unified-memory machines (Metal) have no separate VRAM budget to overflow,
// so they always get the auto sentinel.
function suggestGpuLayers(hw) {
  if (!hasGpu(hw)) return 0
  if (hw.vendor === "metal") return -1
  var usable = hw.vramMb - reservedVramMb(hw.vramMb)
  // Below ~1GB usable, offloading costs more in transfer overhead than it
  // saves, and partial offload on a card this small tends to OOM mid-run.
  if (usable < 1024) return 0
  return -1
}

// Suggested thread count. llama.cpp scales with physical cores and then
// regresses once hyperthreads contend for the same execution units, so
// threads are capped at the physical core count. One core is left for the
// desktop on larger machines.
function suggestThreads(hw) {
  var cores = (hw && hw.cores) || 0
  if (cores <= 0) return 0
  if (cores <= 4) return cores
  return cores - 1
}

// Bytes per KV element for a given --cache-type, relative to the f16 baseline
// of 2 bytes. Quantized tiers carry per-block scale metadata, so the effective
// cost is somewhat above the raw bit width; these are the effective figures.
//
// The turboN tiers come from the optional alternate binary and follow its
// quality ladder (turbo8 ~8-bit down to turbo1 ~1.5-bit). "vbr" adapts per
// layer as context fills, so it gets a deliberately conservative average
// rather than its best case.
var CACHE_TYPE_BYTES = {
  f32: 4.0,
  f16: 2.0,
  bf16: 2.0,
  q8_0: 1.06,
  q5_0: 0.69,
  q5_1: 0.73,
  q4_0: 0.56,
  q4_1: 0.60,
  iq4_nl: 0.56,
  turbo8: 1.06,
  turbo4: 0.56,
  turbo3: 0.42,
  turbo2: 0.28,
  turbo3_tcq: 0.42,
  turbo2_tcq: 0.28,
  turbo1_tcq: 0.19,
  vbr: 0.75
}

function cacheTypeBytes(type) {
  var key = String(type || "f16").toLowerCase().trim()
  var value = CACHE_TYPE_BYTES[key]
  return typeof value === "number" ? value : 2.0
}

// KV cache cost of a single token, in bytes, from the model's real attention
// geometry as read out of the GGUF header by gguf_probe.py.
//
//   per token = layers x kv_heads x (key_dim + value_dim) x bytes_per_element
//
// Returns 0 when the geometry is unknown, which the caller treats as "fall
// back to the coarse estimate" rather than as zero cost.
function kvBytesPerToken(geometry, cacheTypeK, cacheTypeV) {
  if (!geometry) return 0
  var layers = Number(geometry.block_count) || 0
  var kvHeads = Number(geometry.head_count_kv) || 0
  if (layers <= 0 || kvHeads <= 0) return 0

  var keyDim = Number(geometry.key_length) || 0
  var valueDim = Number(geometry.value_length) || 0
  if (keyDim <= 0 || valueDim <= 0) {
    // Older GGUFs omit the explicit lengths; derive the head dimension the
    // way llama.cpp does, from embedding width over the full head count.
    var embed = Number(geometry.embedding_length) || 0
    var heads = Number(geometry.head_count) || 0
    if (embed <= 0 || heads <= 0) return 0
    var headDim = embed / heads
    if (keyDim <= 0) keyDim = headDim
    if (valueDim <= 0) valueDim = headDim
  }

  return layers * kvHeads * (keyDim * cacheTypeBytes(cacheTypeK) +
                             valueDim * cacheTypeBytes(cacheTypeV))
}

// Memory available to hold the KV cache, in MB.
//
// Model weights and the KV cache compete for the same VRAM, so the split
// depends on where the weights actually live. Moving MoE expert tensors to
// system RAM (--cpu-moe / --n-cpu-moe) removes the bulk of the weights from
// VRAM on a sparse model, which frees most of the card for KV -- this is why
// a heuristic based on VRAM alone badly underestimates context on hybrid
// offload setups.
//
// The fractions are empirical rather than derived: predicting the weights'
// exact VRAM footprint would need per-tensor inspection of which layers were
// actually placed on the GPU, which is only knowable after llama.cpp has
// loaded the model. They are deliberately set so the suggestion lands at or
// below what a comparable measured configuration is known to sustain.
//
// Note --cache-ram is NOT counted here: it sizes llama.cpp's prompt cache
// (saved prompts for reuse), not live KV storage, so it buys no context.
function kvBudgetMb(hw, cfg) {
  cfg = cfg || {}
  var budget = 0

  if (hasGpu(hw) && hw.vendor !== "metal") {
    var usable = hw.vramMb - reservedVramMb(hw.vramMb)
    // Offloading MoE experts to CPU removes the bulk of a sparse model's
    // weights from VRAM, but the attention and dense layers still live there.
    if (usable > 0) budget += usable * (cfg.cpuMoeActive ? 0.55 : 0.30)
  } else if (hw && hw.ramMb) {
    // Unified memory or CPU-only: weights and cache share one pool.
    budget += hw.ramMb * 0.35
  }

  return budget
}

// Context sizes worth suggesting. Snapping to these keeps the number
// recognizable rather than reporting an arbitrary token count.
var CONTEXT_STEPS = [2048, 4096, 8192, 16384, 32768, 65536, 131072, 262144]

function snapContext(tokens) {
  var best = CONTEXT_STEPS[0]
  for (var i = 0; i < CONTEXT_STEPS.length; i++)
    if (CONTEXT_STEPS[i] <= tokens) best = CONTEXT_STEPS[i]
  return best
}

// Suggested context size, in tokens.
//
// With the model's geometry available this is a real calculation: divide the
// memory that can hold KV by what one token of KV actually costs at the
// configured cache type. Without it, fall back to a coarse VRAM tiering.
function suggestContextSize(hw, cfg) {
  cfg = cfg || {}
  var budgetMb = kvBudgetMb(hw, cfg)
  if (budgetMb <= 0) return 4096

  var perToken = kvBytesPerToken(cfg.geometry, cfg.cacheTypeK, cfg.cacheTypeV)
  if (perToken > 0) {
    var tokens = (budgetMb * 1048576) / perToken
    // Never suggest more context than the model was trained for -- beyond it
    // quality degrades regardless of how much memory is free.
    var trained = cfg.geometry ? Number(cfg.geometry.context_length) || 0 : 0
    if (trained > 0) tokens = Math.min(tokens, trained)
    return Math.max(2048, snapContext(tokens))
  }

  // No geometry (no model selected, or an unreadable header).
  if (budgetMb < 2048) return 4096
  if (budgetMb < 6144) return 8192
  if (budgetMb < 12288) return 16384
  if (budgetMb < 24576) return 32768
  return 65536
}

// Suggested batch / ubatch. Larger batches raise prompt-processing
// throughput but cost VRAM proportionally, so small cards get llama.cpp's
// conservative defaults rather than the 1024 that was tuned for this
// author's rig.
function suggestBatchSize(hw) {
  if (!hasGpu(hw)) return 512
  var usable = hw.vramMb - reservedVramMb(hw.vramMb)
  if (usable < 4096) return 512
  if (usable < 12288) return 1024
  return 2048
}

function suggestUbatchSize(hw) {
  var batch = suggestBatchSize(hw)
  // ubatch above 512 rarely helps and raises peak compute-buffer size.
  return Math.min(512, batch)
}

// Everything the Tuning page prefills, in one call.
// cfg carries the launch settings that change what fits: the selected model's
// geometry, the KV cache types, whether MoE experts are offloaded to CPU, and
// any --cache-ram allowance.
function suggestAll(hw, cfg) {
  return {
    gpuLayers: suggestGpuLayers(hw),
    threads: suggestThreads(hw),
    contextSize: suggestContextSize(hw, cfg),
    batchSize: suggestBatchSize(hw),
    ubatchSize: suggestUbatchSize(hw),
    cuda: isCuda(hw)
  }
}

// One-line description of what the suggestions were derived from, shown
// under the Tuning controls so the numbers are not unexplained magic.
function summary(hw) {
  if (!hw) return ""
  var parts = []
  if (hw.gpuName) parts.push(hw.gpuName)
  if (hw.vramMb > 0) parts.push((hw.vramMb / 1024).toFixed(hw.vramMb >= 10240 ? 0 : 1) + "GB VRAM")
  if (hw.ramMb > 0) parts.push(Math.round(hw.ramMb / 1024) + "GB RAM")
  if (hw.cores > 0) parts.push(hw.cores + " cores")
  return parts.join(" · ")
}

if (typeof module !== "undefined") {
  module.exports = {
    reservedVramMb: reservedVramMb,
    parseProbe: parseProbe,
    isCuda: isCuda,
    hasGpu: hasGpu,
    suggestGpuLayers: suggestGpuLayers,
    suggestThreads: suggestThreads,
    cacheTypeBytes: cacheTypeBytes,
    kvBytesPerToken: kvBytesPerToken,
    kvBudgetMb: kvBudgetMb,
    snapContext: snapContext,
    suggestContextSize: suggestContextSize,
    suggestBatchSize: suggestBatchSize,
    suggestUbatchSize: suggestUbatchSize,
    suggestAll: suggestAll,
    summary: summary
  }
}
