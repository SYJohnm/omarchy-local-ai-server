// Generates the pi coding agent's model catalogue from what this plugin
// already knows about the running server.
//
// pi reads ~/.pi/agent/models.json and exposes each provider's models to
// --model / Ctrl+P. Maintained by hand that file goes stale quickly -- the
// context window in particular is a property of how the server was launched,
// not of the model file, so it drifts every time tuning changes.
//
// Only the providers this plugin owns are touched. Everything else in the
// file, including a hand-written compat block on an owned provider, is
// preserved: the merge fills in what the plugin knows and leaves the rest.
//
// Pure logic: takes state in, returns the object to write. No I/O.

// Provider keys this plugin manages. "local-llama" is the name pi users
// conventionally give a local llama-server, so an existing hand-written entry
// is adopted rather than duplicated.
var PROVIDER_KEYS = {
  llamacpp: "local-llama",
  ollama: "local-ollama"
}

var PROVIDER_NAMES = {
  llamacpp: "Local llama-server",
  ollama: "Local ollama"
}

// Compatibility defaults for a provider the plugin creates from scratch.
//
// chatTemplateKwargs is what turns pi's --thinking off into a real request
// flag. Without it a reasoning model burns the whole token budget thinking
// and returns empty content -- measured on gemma4:e4b: 20s and no answer
// without it, 1.4s and a clean answer with it.
//
// Bound to pi's own thinking.enabled variable rather than hardcoded, so the
// user's --thinking setting stays in control.
var DEFAULT_COMPAT = {
  supportsDeveloperRole: false,
  chatTemplateKwargs: { enable_thinking: { "$var": "thinking.enabled" } }
}

function providerKey(backendId) {
  return PROVIDER_KEYS[backendId] || PROVIDER_KEYS.llamacpp
}

// The context the server will actually honour.
//
// The launch setting wins when it is set, because that is the limit enforced
// at runtime; the model's trained length is the fallback for "0", which both
// backends read as "use the model's own". Advertising the trained maximum
// while the server was started with less is the exact drift that makes a
// hand-written catalogue wrong.
function effectiveContext(launchCtxSize, trainedContext) {
  var launched = parseInt(launchCtxSize, 10)
  if (isFinite(launched) && launched > 0) return launched
  var trained = parseInt(trainedContext, 10)
  if (isFinite(trained) && trained > 0) return trained
  return 4096
}

// Reserve for the response. pi treats maxTokens as an output cap, so it has to
// leave room inside the context window for the prompt.
function defaultMaxTokens(contextWindow) {
  return Math.max(512, Math.min(8192, Math.floor(contextWindow / 4)))
}

function buildModel(spec) {
  spec = spec || {}
  var caps = spec.caps || {}
  var contextWindow = effectiveContext(spec.launchCtxSize, spec.trainedContext)
  var input = ["text"]
  if (caps.vision) input.push("image")

  return {
    id: String(spec.id || ""),
    name: String(spec.name || spec.id || ""),
    reasoning: !!caps.thinking,
    input: input,
    contextWindow: contextWindow,
    maxTokens: spec.maxTokens > 0 ? spec.maxTokens : defaultMaxTokens(contextWindow),
    // A local server bills nothing; pi still expects the shape.
    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }
  }
}

// Builds the provider entry, preserving anything the user hand-tuned.
//
// `existing` is the current entry for this provider, if any. Its `compat`
// block matters most: thinkingFormat and chatTemplateKwargs are model- and
// taste-specific, and the plugin has no way to derive them.
function buildProvider(spec, existing) {
  spec = spec || {}
  var previous = existing || {}
  var provider = {}

  // Carry every unknown key through untouched, so a field pi gains later, or
  // one the user added, is not silently dropped on the next write.
  for (var key in previous) provider[key] = previous[key]

  provider.name = previous.name || PROVIDER_NAMES[spec.backend] || "Local model server"
  provider.baseUrl = "http://" + String(spec.host || "127.0.0.1") + ":" + String(spec.port || "") + "/v1"
  provider.api = previous.api || "openai-completions"
  provider.apiKey = previous.apiKey || "local"
  // A hand-written compat block always wins; otherwise supply the defaults,
  // since a provider with none leaves reasoning models unusable.
  provider.compat = previous.compat || DEFAULT_COMPAT
  provider.models = spec.models || []
  return provider
}

// Merges the provider into the catalogue, leaving every other provider alone.
function mergeCatalogue(existingCatalogue, backendId, provider) {
  var catalogue = {}
  var source = existingCatalogue && typeof existingCatalogue === "object" ? existingCatalogue : {}
  for (var key in source) catalogue[key] = source[key]

  var providers = {}
  var existingProviders = source.providers && typeof source.providers === "object" ? source.providers : {}
  for (var name in existingProviders) providers[name] = existingProviders[name]

  providers[providerKey(backendId)] = provider
  catalogue.providers = providers
  return catalogue
}

// Parses the catalogue, tolerating a missing or corrupt file. A malformed
// file must not cause the plugin to discard the user's other providers, so
// this returns null rather than an empty object -- the caller skips writing.
function parseCatalogue(text) {
  var raw = String(text || "").trim()
  if (raw === "") return { providers: {} }
  try {
    var parsed = JSON.parse(raw)
    if (parsed && typeof parsed === "object") return parsed
  } catch (e) { /* fall through */ }
  return null
}

function existingProvider(catalogue, backendId) {
  if (!catalogue || !catalogue.providers) return null
  return catalogue.providers[providerKey(backendId)] || null
}

function serialize(catalogue) {
  return JSON.stringify(catalogue, null, 2) + "\n"
}

if (typeof module !== "undefined") {
  module.exports = {
    PROVIDER_KEYS: PROVIDER_KEYS,
    DEFAULT_COMPAT: DEFAULT_COMPAT,
    providerKey: providerKey,
    effectiveContext: effectiveContext,
    defaultMaxTokens: defaultMaxTokens,
    buildModel: buildModel,
    buildProvider: buildProvider,
    mergeCatalogue: mergeCatalogue,
    parseCatalogue: parseCatalogue,
    existingProvider: existingProvider,
    serialize: serialize
  }
}
