// switchState is "draining" while a restart waits for running requests to
// finish before the server is stopped; anything else reads as a plain run state.
function statusLabel(running, starting, startingElapsed, switchState, inflight) {
  if (starting) return "Starting… " + (startingElapsed || 0) + "s"
  if (running && switchState === "draining")
    return "Restarting · waiting for " + (inflight || 0) + " request" + (inflight === 1 ? "" : "s")
  return running ? "Running" : "Stopped"
}

// Parses a llama.cpp timing line into {kind: "pp"|"tg", tps}.
//
// Both backends emit this identical format, because ollama embeds llama.cpp
// and re-exports its server logs verbatim:
//   "slot print_timing: id  0 | task 0 | prompt eval time = 521.34 ms / 11 tokens (  47.39 ms per token,  21.10 tokens per second)"
//   "slot print_timing: id  0 | task 0 |        eval time = 941.26 ms /  8 tokens ( 134.47 ms per token,   7.44 tokens per second)"
// so one parser serves llama.cpp and ollama alike.
//
// The "prompt " prefix is what distinguishes prompt-processing throughput
// from generation throughput. It is matched inline rather than anchored to
// the line start: llama.cpp prefixes these lines with "slot print_timing:
// id N | task N |", so an anchored test would miss the prompt marker and
// silently report pp numbers as tg. Leftmost-match semantics guarantee the
// optional group binds when the word is present.
//
// "total time = ... ms / N tokens" carries no "tokens per second" clause and
// therefore never matches.
function parseTimingLine(line) {
  var text = String(line || "")
  var match = text.match(/(prompt\s+)?eval time\s*=\s*[\d.]+ ms\s*\/\s*\d+ tokens\s*\(\s*[\d.]+ ms per token,\s*([\d.]+) tokens per second\)/i)
  if (!match) return null
  var value = parseFloat(match[2])
  if (!isFinite(value)) return null
  return { kind: match[1] ? "pp" : "tg", tps: value }
}

// Live prompt-processing progress, logged per batch while the prompt is still
// being ingested:
//   "slot print_timing: id  0 | task 118 | prompt processing, n_tokens = 14336, progress = 0.46, t = 280.52 s / 51.11 tokens per second"
//
// This is the only reliable pp rate on a long prompt. Deriving it from /slots
// means diffing n_prompt_tokens_processed between two polls, and that field
// does not advance on every build -- it stays flat between batches, the diff
// is zero, and the widget shows a percentage with no rate beside it. The line
// carries both numbers already measured, so it is preferred when present.
//
// Returns {kind: "pp_progress", tps, percent} or null.
function parsePromptProgressLine(line) {
  var text = String(line || "")
  var match = text.match(/prompt processing,\s*n_tokens\s*=\s*\d+,\s*progress\s*=\s*([\d.]+),\s*t\s*=\s*[\d.]+ s\s*\/\s*([\d.]+) tokens per second/i)
  if (!match) return null
  var percent = parseFloat(match[1]) * 100
  var tps = parseFloat(match[2])
  if (!isFinite(percent) || !isFinite(tps)) return null
  return { kind: "pp_progress", tps: tps, percent: Math.max(0, Math.min(100, percent)) }
}

// Generation-speed-only view of parseTimingLine, for callers that only care
// about tg and want the previous number-or-null shape.
function parseTokensPerSecond(line) {
  var parsed = parseTimingLine(line)
  return parsed && parsed.kind === "tg" ? parsed.tps : null
}

// Live-progress text for the current slot state: a pp% (plus the prompt's
// own processing speed) while the prompt is still being ingested, tok/s
// once generation is actually producing tokens.
function metricText(showMetric, ppActive, ppPercent, tokensPerSec, ppTokensPerSec) {
  if (!showMetric) return ""
  if (ppActive) {
    // Percent first: during ingestion the question is how far along it is,
    // and its rate is the second half of the same answer. The "pp" label is
    // gone -- a percentage next to a rate is only ever the prompt, and the
    // two words cost bar width on the one state that already shows the most
    // text.
    var pct = ppPercent.toFixed(0) + "%"
    return ppTokensPerSec > 0 ? pct + " - " + ppTokensPerSec.toFixed(0) + " t/s" : pct
  }
  if (tokensPerSec > 0) return tokensPerSec.toFixed(1) + " t/s"
  return ""
}

// The mark is the word itself. It replaced a colour llama emoji -- ollama's
// logo, shown for both backends, so it was wrong for llama.cpp and was the
// one colour glyph in a monochrome bar -- and then a server glyph carrying a
// tiny "AI" badge, which needed the badge positioned off the label's own
// metrics and still read as two marks. Two letters need none of that: they
// take the bar's font, its colour rules and its baseline for free.
var BAR_ICON = "AI"

// The mark identifies the widget; a live number identifies it just as well
// and says more, so the two never share the slot. AI shows while the server
// is idle, stopped, or has its metrics hidden; pp and tg replace it outright.
function barText(icon, running, showMetric, ppActive, ppPercent, tokensPerSec, ppTokensPerSec) {
  if (!running) return icon
  var m = metricText(showMetric, ppActive, ppPercent, tokensPerSec, ppTokensPerSec)
  return m ? m : icon
}

// Marks the bar text with the restart state, so a pending or waiting restart
// is visible without opening the panel:
//   draining -- "⇄" plus the still-running request's live number, if any
//   pending  -- the usual text plus " •": the page differs from what runs
function barSwitchText(base, switchState, pending) {
  if (switchState === "draining") return base && /\d/.test(base) ? "⇄ " + base : "⇄"
  return pending ? base + " •" : base
}

function barSwitchTooltip(switchState, inflight) {
  if (switchState === "draining")
    return "Restarting: waiting for " + (inflight || 0) + " running request" + (inflight === 1 ? "" : "s")
  return ""
}

// Parses the Environment row: "NAME=value NAME2='with spaces'" into
// [{name, value}], plus the tokens that are not assignments. Names follow the
// shell's rule, so nothing reaching the launch line can be anything but an
// assignment; values are shell-quoted by the caller.
function parseEnvAssignments(text) {
  var env = [], invalid = []
  var re = /\s*([^\s=]*)=("([^"]*)"|'([^']*)'|(\S*))|\s*(\S+)/g
  var src = String(text || ""), m
  while ((m = re.exec(src)) !== null) {
    if (m[0].trim() === "") break
    if (m[6] !== undefined) { invalid.push(m[6]); continue }
    var name = m[1]
    var value = m[3] !== undefined ? m[3] : (m[4] !== undefined ? m[4] : m[5])
    if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(name)) { invalid.push(m[0].trim()); continue }
    var replaced = false
    for (var i = 0; i < env.length; i++)
      if (env[i].name === name) { env[i].value = value; replaced = true }
    if (!replaced) env.push({ name: name, value: value })
  }
  return { env: env, invalid: invalid }
}

// ---- Log triage ----

// systemd's own unit chatter. It reports *that* a unit failed, never why.
function isSystemdNoise(line) {
  var text = String(line || "")
  return /Failed with result|Main process exited|Consumed .* CPU time|Scheduled restart|^Started |^Stopping |^Stopped |Deactivated successfully/i.test(text) ||
         /^[A-Za-z0-9_.-]+\.service:/.test(text)
}

// systemd-coredump's backtrace, written into the same journal when a server
// aborts. Its frames contain words like "abort" and "assert" and arrive last,
// so without excluding them they shadow the diagnostic that actually explains
// the crash -- which is logged well before the dump.
function isCoredumpNoise(line) {
  var text = String(line || "")
  return /^#\d+\s/.test(text) ||
         /^(Stack trace of|ELF object|Module |Found module|Metadata for|Storing coredump|Coredump|Process \d+ \(|Refusing to process|GNU gdb)/i.test(text) ||
         /^\s*0x[0-9a-f]+/i.test(text)
}

// Picks the line worth showing when a server dies.
//
// Scans newest-first for the application's own error, skipping coredump
// frames and systemd's summary. Falls back to the last real output, and only
// then to systemd's message, so something useful is always reported.
function pickErrorLine(lines, lastLine) {
  var list = lines || []
  var fallback = ""
  for (var i = list.length - 1; i >= 0; i--) {
    var line = String(list[i]).trim()
    if (line === "") continue
    if (isCoredumpNoise(line)) continue
    if (isSystemdNoise(line)) {
      if (fallback === "") fallback = line
      continue
    }
    if (/error|failed|assert|abort|cannot|unable|unsupported|no such/i.test(line)) return line
    if (fallback === "" || isSystemdNoise(fallback)) fallback = line
  }
  return fallback !== "" ? fallback : String(lastLine || "")
}

// ---- Model tree / detection ----

function dirName(path) {
  var idx = String(path).lastIndexOf("/")
  return idx >= 0 ? path.slice(0, idx) : ""
}

// Directory paths from rootDir down to (but not including) `path` itself
// -- i.e. every ancestor directory that must stay expanded for `path` to
// be reachable in the flattened tree.
function ancestorDirs(path, rootDir) {
  var chain = []
  var p = dirName(path)
  while (p && p !== rootDir && p.length > rootDir.length) {
    chain.unshift(p)
    p = dirName(p)
  }
  return chain
}

function baseName(path) {
  var idx = String(path).lastIndexOf("/")
  return idx >= 0 ? path.slice(idx + 1) : path
}

function isMmprojName(name) {
  return /mmproj/i.test(name)
}

// Parses `find DIR \( -type d -printf "D\t%p\n" \) -o \( -type f
// -iname '*.gguf' -printf "F\t%p\n" \)` output into directory and file
// path lists. Files include mmproj siblings -- those are filtered out of
// the model list by the caller but still used to mark vision support.
function parseFindOutput(raw) {
  var dirs = []
  var files = []
  var lines = String(raw || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    var tab = line.indexOf("\t")
    if (tab < 0) continue
    var kind = line.slice(0, tab)
    var path = line.slice(tab + 1).trim()
    if (!path) continue
    if (kind === "D") dirs.push(path)
    else if (kind === "F") files.push(path)
  }
  return { dirs: dirs, files: files }
}

// Best-effort quantization label pulled from the filename, e.g.
// "Qwen3.6-35B-A3B-UD-IQ4_XS.gguf" -> "UD-IQ4_XS".
function quantLabel(filename) {
  var base = String(filename || "").replace(/\.gguf$/i, "")
  var match = base.match(/(?:^|[-_.])((?:UD-)?(?:IQ|Q)\d(?:_[A-Z0-9]+)*|BF16|F16|F32)(?:[-_.]|$)/i)
  return match ? match[1].toUpperCase() : ""
}

// Reads gguf_probe.py's batched JSON output and derives tool-calling /
// thinking support from each model's embedded chat template -- the best
// signal available without actually running the model.
function parseProbeCapabilities(jsonText) {
  var caps = {}
  var data
  try { data = JSON.parse(jsonText || "{}") } catch (e) { return caps }
  for (var path in data) {
    var entry = data[path] || {}
    var template = String(entry["tokenizer.chat_template"] || "").toLowerCase()
    caps[path] = {
      tools: template.indexOf("tool_calls") !== -1 || template.indexOf("<tools>") !== -1,
      thinking: template.indexOf("<think") !== -1 || template.indexOf("reasoning_content") !== -1,
      mtp: !!entry.has_nextn
    }
  }
  return caps
}

// Reads the attention geometry gguf_probe.py extracts from each model's GGUF
// header, keyed by path. Used to size the KV cache: what one token costs is a
// property of the model, not the machine.
//
// Entries missing the geometry keys (an unreadable header, or a probe failure)
// are simply absent, which callers treat as "unknown" rather than zero.
function parseProbeGeometry(jsonText) {
  var out = {}
  var data
  try { data = JSON.parse(jsonText || "{}") } catch (e) { return out }
  for (var path in data) {
    var entry = data[path] || {}
    if (typeof entry.block_count !== "number") continue
    out[path] = {
      block_count: entry.block_count,
      head_count_kv: entry.head_count_kv,
      head_count: entry.head_count,
      key_length: entry.key_length,
      value_length: entry.value_length,
      embedding_length: entry.embedding_length,
      context_length: entry.context_length
    }
  }
  return out
}

// Builds a nested {type:"dir"|"file", path, name, children} tree from a
// flat model-file list, pruning to only the branches that actually lead
// to a model (no empty folders). `visionDirs` is a Set-like object of
// directory paths that contain an mmproj sibling.
function buildModelTree(rootDir, files, capsByPath, visionDirs) {
  var root = { children: [] }

  // Directory nodes are created lazily, keyed by full path, walking from
  // each file up to `rootDir` so intermediate folders exist even if
  // `find` listed them out of order. `rootDir` itself maps to the root
  // node rather than becoming a visible top-level row.
  var byPath = {}
  byPath[rootDir] = root

  function nodeFor(path) {
    if (byPath[path]) return byPath[path]
    var parent = nodeFor(dirName(path))
    var node = {
      type: "dir", path: path, name: baseName(path), children: [],
      quant: "", vision: false, tools: false, thinking: false, mtp: false
    }
    parent.children.push(node)
    byPath[path] = node
    return node
  }

  var sorted = files.slice().sort()
  for (var i = 0; i < sorted.length; i++) {
    var path = sorted[i]
    var parentDir = dirName(path)
    var parent = nodeFor(parentDir)
    var caps = (capsByPath && capsByPath[path]) || {}
    parent.children.push({
      type: "file",
      path: path,
      name: baseName(path),
      quant: quantLabel(baseName(path)),
      vision: !!(visionDirs && visionDirs[parentDir]),
      tools: !!caps.tools,
      thinking: !!caps.thinking,
      mtp: !!caps.mtp
    })
  }

  function sortNode(node) {
    node.children.sort(function(a, b) {
      if (a.type !== b.type) return a.type === "dir" ? -1 : 1
      return a.name.localeCompare(b.name)
    })
    for (var j = 0; j < node.children.length; j++)
      if (node.children[j].type === "dir") sortNode(node.children[j])
  }
  sortNode(root)
  return root.children
}

// Flattens the tree into visible rows only, skipping children of
// collapsed directories. Accordion semantics: `expanded[path] === true`
// is the only thing that counts as expanded (default collapsed), so at
// most one directory chain is ever open at a time -- the caller is
// responsible for clearing any previously expanded path before setting
// a new one.
function flattenTree(nodes, expanded, depth, out) {
  depth = depth || 0
  out = out || []
  for (var i = 0; i < nodes.length; i++) {
    var node = nodes[i]
    out.push({ node: node, depth: depth })
    if (node.type === "dir" && expanded[node.path] === true) {
      flattenTree(node.children, expanded, depth + 1, out)
    }
  }
  return out
}

// Every file node in the tree, regardless of which directories are
// currently expanded -- for logic that needs to know what models exist
// (validating/defaulting selectedModel), as opposed to what's on screen.
function collectFiles(nodes, out) {
  out = out || []
  for (var i = 0; i < nodes.length; i++) {
    var node = nodes[i]
    if (node.type === "file") out.push(node)
    else if (node.type === "dir") collectFiles(node.children, out)
  }
  return out
}

// Splits a free-form "additional arguments" string into argv tokens,
// respecting single/double quotes (e.g. --alias "my model" -x -> ["--alias",
// "my model", "-x"]) so users can pass values containing spaces.
function parseArgs(str) {
  var out = []
  var s = String(str || "")
  var i = 0
  while (i < s.length) {
    while (i < s.length && /\s/.test(s[i])) i++
    if (i >= s.length) break
    var quote = null
    var tok = ""
    while (i < s.length) {
      var c = s[i]
      if (quote) {
        if (c === quote) { quote = null; i++; continue }
        tok += c; i++; continue
      }
      if (c === '"' || c === "'") { quote = c; i++; continue }
      if (/\s/.test(c)) break
      tok += c; i++
    }
    out.push(tok)
  }
  return out
}

// Recommended cache-type-v for a given cache-type-k, when k is a TurboQuant
// tier. V one tier more aggressive than K is the one real-world-validated
// pairing -- turbo4 K / turbo3 V (both bare, non-tcq) on Qwen3.6-35B-A3B --
// extended by degrading one step within the same family (bare vs _tcq)
// since no further data point exists yet. vbr and turbo8 pair with
// themselves -- vbr already manages both sides dynamically, and turbo8 is
// the ladder's top (nothing more conservative to pair it with). No bare
// turbo1 exists, so turbo2 bottoms out at turbo1_tcq.
var turboVForK = {
  vbr: "vbr",
  turbo8: "turbo8",
  turbo4: "turbo3",
  turbo3: "turbo2",
  turbo2: "turbo1_tcq",
  turbo3_tcq: "turbo2_tcq",
  turbo2_tcq: "turbo1_tcq",
  turbo1_tcq: "turbo1_tcq"
}

function recommendedCacheTypeV(cacheTypeK) {
  return turboVForK[String(cacheTypeK || "").trim()] || null
}

// True for any --cache-type value that only the TurboQuant-fork binary
// understands (vbr and the fixed turboN_* tiers). Stock llama-server would
// reject these, so launchServerProcess() uses this to pick the binary.
function isTurboQuantCacheType(v) {
  return /^(vbr|turbo\d(_tcq)?)$/i.test(String(v || "").trim())
}

// Extra args are stored/edited as one semicolon-separated string so a
// multi-token flag ("--np 1") can sit in its own list entry without needing
// shell-quote escaping. Each piece is still shell-word-split by parseArgs
// when the server actually launches.
function splitExtraArgs(str) {
  return String(str || "")
    .split(";")
    .map(function(s) { return s.trim() })
    .filter(function(s) { return s !== "" })
}

// Chunks a list of tuning rows into sub-pages.
//
// Each entry carries a weight, and a row is never split across a page
// boundary: the vision projector's path field belongs with the mode control
// that reveals it, so that row weighs two and moves as one.
//
// `firstPageReserved` is room the first page owes to something that is not a
// row -- the note naming arguments that could not be split.
//
// A page always comes back, even for an empty list: the section renders the
// current page, and there is no such thing as no page to be on.
function paginateRows(rows, capacity, firstPageReserved) {
  var list = rows || []
  var perPage = Math.max(1, capacity || 1)
  var reserved = Math.max(0, firstPageReserved || 0)
  var pages = []
  var current = []
  var used = 0

  for (var i = 0; i < list.length; i++) {
    var weight = Math.max(1, list[i].weight || 1)
    var room = perPage - (pages.length === 0 ? reserved : 0)
    // `used > 0` is what keeps a row heavier than a whole page from looping:
    // it lands on a page of its own rather than being deferred forever.
    if (used > 0 && used + weight > room) {
      pages.push(current)
      current = []
      used = 0
    }
    current.push(list[i])
    used += weight
  }
  if (current.length > 0 || pages.length === 0) pages.push(current)
  return pages
}

if (typeof module !== "undefined") {
  module.exports = {
    statusLabel: statusLabel,
    parseTimingLine: parseTimingLine,
    parsePromptProgressLine: parsePromptProgressLine,
    isSystemdNoise: isSystemdNoise,
    isCoredumpNoise: isCoredumpNoise,
    pickErrorLine: pickErrorLine,
    parseTokensPerSecond: parseTokensPerSecond,
    metricText: metricText,
    BAR_ICON: BAR_ICON,
    barSwitchText: barSwitchText,
    parseEnvAssignments: parseEnvAssignments,
    barSwitchTooltip: barSwitchTooltip,
    barText: barText,
    dirName: dirName,
    ancestorDirs: ancestorDirs,
    baseName: baseName,
    isMmprojName: isMmprojName,
    parseFindOutput: parseFindOutput,
    quantLabel: quantLabel,
    parseProbeCapabilities: parseProbeCapabilities,
    parseProbeGeometry: parseProbeGeometry,
    paginateRows: paginateRows,
    buildModelTree: buildModelTree,
    flattenTree: flattenTree,
    collectFiles: collectFiles,
    splitExtraArgs: splitExtraArgs,
    parseArgs: parseArgs,
    turboVForK: turboVForK,
    recommendedCacheTypeV: recommendedCacheTypeV,
    isTurboQuantCacheType: isTurboQuantCacheType
  }
}
