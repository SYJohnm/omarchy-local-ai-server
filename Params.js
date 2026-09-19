// Parameter catalogue, generated from each backend's own `--help`.
//
// The list of tunables is large (llama-server alone exposes ~250 flags) and
// changes between builds, so it is parsed from the binary the user actually
// has rather than hand-maintained here. A flag this build does not know about
// therefore never appears, and one it gained shows up without a plugin update.
//
// Pure logic: takes help text in, returns descriptors out. No I/O.

// ---- llama.cpp -----------------------------------------------------------
//
// Help lines put the flags in the left column and the description in the
// right, with wrapped description text and "(env: ...)" notes indented under
// it. A line that starts with a dash begins a new parameter; anything else
// continues the previous one.
//
//   -t,    --threads N                      number of CPU threads ... (default: -1)
//                                           (env: LLAMA_ARG_THREADS)
//
// The split is done on a run of two or more spaces rather than a fixed column,
// so unusually long flag lists (which push the description right) still parse.

// A flag starts with one or two dashes followed by a letter. The letter test
// matters: description text routinely begins with a negative number
// ("-1 = infinity"), which would otherwise be swallowed as a flag.
function isFlagToken(token) {
  return /^--?[A-Za-z]/.test(token)
}

function splitFlagsAndArg(head) {
  var parts = String(head).trim().split(/\s+/)
  var flags = []
  var arg = ""
  for (var i = 0; i < parts.length; i++) {
    var token = parts[i].replace(/,$/, "")
    if (isFlagToken(token)) flags.push(token)
    else { arg = parts.slice(i).join(" "); break }
  }
  return { flags: flags, arg: arg }
}

// A flag that spells its own negation: "--jinja, --no-jinja".
//
// llama.cpp writes both halves of a boolean on one help line, so the pair has
// to be recognised before a canonical name can be picked -- and it decides how
// the value is passed, since such a flag has three meaningful states rather
// than two.
function negatedForm(flag) {
  return String(flag).replace(/^--/, "--no-")
}

function isNegatablePair(flags) {
  for (var i = 0; i < flags.length; i++) {
    var f = flags[i]
    // Short forms only alias the long one and are never negated, and a name
    // that is not "--"-prefixed negates to itself -- which read every flag
    // carrying a short alias, "-np, --parallel" among them, as a pair.
    if (f.indexOf("--") !== 0) continue
    if (f.indexOf("--no-") === 0) continue
    if (flags.indexOf(negatedForm(f)) !== -1) return true
  }
  return false
}

// Longest flag is the canonical one: "--threads" reads better than "-t", and
// long forms are stable across releases where short ones get reassigned.
//
// The positive half of a negatable pair wins regardless of length. "--no-" is
// three characters longer than what it negates, so length alone named every
// such parameter after its own negation -- "--no-reasoning-preserve",
// "--no-mmproj-auto", "--no-cont-batching" -- and adding one from the picker
// then switched the setting off while the row read as switching it on.
function canonicalFlag(flags) {
  var best = ""
  var bestNegative = ""
  for (var i = 0; i < flags.length; i++) {
    var f = flags[i]
    if (f.indexOf("--") !== 0) continue
    if (f.indexOf("--no-") === 0) {
      if (f.length > bestNegative.length) bestNegative = f
      continue
    }
    if (f.length > best.length) best = f
  }
  return best || bestNegative || (flags.length > 0 ? flags[0] : "")
}

// The default exactly as documented, literal or not.
//
// Many defaults are descriptive rather than a value -- "same as --threads",
// "4k/32k/256k based on VRAM", "loaded from model". Those cannot seed a field,
// but they are exactly what a user needs to see to decide what to type, so
// they are kept for use as placeholder text.
function extractDefaultHint(description) {
  var match = String(description).match(/default:?\s+([^)]+)/i)
  if (!match) return ""
  return match[1].trim().replace(/^['"]|['"]$/g, "")
}

function extractDefault(description) {
  // "default:" is not always the first thing in its parenthetical -- e.g.
  // "('on', 'off', or 'auto', default: 'auto')" and "(0 - no polling,
  // default: 50)" -- so it is matched wherever it appears rather than
  // anchored to the opening paren. The capture stops at the next comma or
  // closing paren, which trims trailing prose like "-1 = infinity".
  var match = String(description).match(/default:?\s+([^,)]+)/i)
  if (!match) return ""
  var value = match[1].trim()
  value = value.replace(/^['"]|['"]$/g, "")
  if (/^(same as|loaded from|depends|see |unset|none$|disabled$|enabled$)/i.test(value)) return ""
  if (/\s/.test(value)) return ""
  return value
}

// Type is inferred from the value placeholder, falling back to the shape of
// the default. It decides which editor the UI shows and how the value is
// validated -- not how it is passed, which is always textual.
// The three states of a negatable flag: leave it alone, force it on, force it
// off. Passing it is not the same as passing its negation, and neither is the
// same as passing nothing -- llama.cpp's own defaults for these are "template
// default" and "enabled", which no two-state control can express.
var TRISTATE_OPTIONS = ["default", "on", "off"]

function inferType(arg, description, defaultValue, flags) {
  var a = String(arg || "").trim()
  if (a === "") return isNegatablePair(flags || []) ? "tristate" : "bool"

  // "<0...100>" is a range, not a choice, and must not be read as one.
  var bracketed = a.match(/^[\[<{]([^\]>}]*)[\]>}]$/)
  if (bracketed && bracketed[1].indexOf("...") !== -1) return "int"

  // A fixed set of accepted values, however the help spells it, is always an
  // enum: the value has to be one of them, so the UI must offer them rather
  // than a free-text field.
  if (enumOptions(a, description).length >= 2) return "enum"

  if (/^-?\d+\.\d+$/.test(String(defaultValue))) return "float"
  if (/^N$/.test(a)) return "int"
  if (/^-?\d+$/.test(String(defaultValue)) && !/FNAME|PATH|FILE|URL|STRING/i.test(a)) return "int"
  return "string"
}

function splitOptionList(body, separator) {
  return String(body).split(separator).map(function (s) {
    // Nested brackets survive the outer match on forms like "[<dev1|dev2|..>]",
    // and a leftover ">" on the last entry is what stopped the ellipsis test
    // from recognising that list as open-ended.
    return s.trim().replace(/^['"]|['"]$/g, "").replace(/^[\[<{]+|[\]>}]+$/g, "")
  }).filter(function (s) {
    return s !== "" && s.indexOf(" ") === -1
  })
}

// Distinguishes a set of accepted values from a placeholder describing a
// repeatable format. llama.cpp writes both between the same brackets:
//
//   --split-mode {none,layer,row,tensor}   a real choice
//   --device     [dev1|dev2|..]            "one or more device names"
//   --override-kv [KEY=TYPE:VALUE|...]     a syntax, not a value
//
// Offering the second kind as a dropdown would be worse than a text field: it
// looks authoritative while every entry in it is a made-up example.
function looksLikeValueSet(options) {
  if (options.length < 2) return false
  var indexedPlaceholders = 0
  for (var i = 0; i < options.length; i++) {
    var option = options[i]
    // An ellipsis means the list is open-ended, so it is not a set.
    if (/^[.…]+$/.test(option)) return false
    // "KEY=TYPE:VALUE", "FNAME:SCALE" -- a grammar for one entry.
    if (option.indexOf("=") !== -1 || option.indexOf(":") !== -1) return false
    // "dev1", "N0", "MiB2", "TOOL1" -- an example, numbered by position.
    if (/^[A-Za-z]+\d+$/.test(option)) indexedPlaceholders++
  }
  return indexedPlaceholders < options.length
}

function uniqueOptions(list) {
  var seen = {}
  var out = []
  for (var i = 0; i < list.length; i++) {
    if (seen[list[i]]) continue
    seen[list[i]] = true
    out.push(list[i])
  }
  return out
}

// The accepted values for a parameter, or [] when it takes free text.
//
// llama.cpp spells a fixed value set four different ways, and only the first
// was recognised -- so --load-mode, --cache-type-k, --split-mode, --pooling,
// --numa and --spec-type all came through as free-text fields, where a typo
// is only discovered when the server refuses to start:
//
//   1. placeholder alternatives   -fa, --flash-attn [on|off|auto]
//   2. placeholder set            --split-mode {none,layer,row,tensor}
//   3. bare placeholder list      --spec-type none,draft-simple,draft-mtp
//   4. described in the help text --cache-type-k TYPE
//                                   "allowed values: f32, f16, q8_0, ..."
//                                 --load-mode MODE
//                                   "- auto: ... - mmap: ... - mlock: ..."
//
// The placeholder is authoritative when it carries the list; the description
// is read only when it does not. A description bullet list needs two entries
// before it counts, so ordinary prose containing one dashed clause cannot
// turn a free-text parameter into a dropdown.
function enumOptions(arg, description) {
  var a = String(arg || "").trim()
  var text = String(description || "")

  var bracketed = a.match(/^[\[<{]([^\]>}]*)[\]>}]$/)
  if (bracketed) {
    var body = bracketed[1]
    if (body.indexOf("...") === -1) {
      var separator = body.indexOf("|") !== -1 ? "|" : (body.indexOf(",") !== -1 ? "," : "")
      if (separator !== "") {
        var listed = uniqueOptions(splitOptionList(body, separator))
        if (looksLikeValueSet(listed)) return listed
      }
    }
  }

  // A bare comma-separated placeholder: "--spec-type none,draft-mtp,ngram-mod".
  if (a.indexOf(",") !== -1 && a.indexOf(" ") === -1) {
    var bare = uniqueOptions(splitOptionList(a, ","))
    if (looksLikeValueSet(bare)) return bare
  }

  // "allowed values: a, b, c" continues until the next parenthetical, which is
  // where the default and the env var live.
  var allowed = text.match(/allowed values:\s*([^(]+)/i)
  if (allowed) {
    var fromHelp = uniqueOptions(splitOptionList(allowed[1], ","))
    if (looksLikeValueSet(fromHelp)) return fromHelp
  }

  // A described list: "- auto: mmap, unless ... - mlock: force system ...".
  // Anchored on the dash so a value name is only taken where the help is
  // actually enumerating, and requiring the colon keeps prose like
  // "-1 = infinity" out.
  var bulleted = []
  var bullet = /(?:^|\s)-\s+([A-Za-z][A-Za-z0-9_.+-]*):\s/g
  var match
  while ((match = bullet.exec(text)) !== null) bulleted.push(match[1])
  bulleted = uniqueOptions(bulleted)
  if (looksLikeValueSet(bulleted)) return bulleted

  return []
}

function parseLlamaHelp(text) {
  var lines = String(text || "").split("\n")
  var params = []
  var section = ""
  var current = null

  function flush() {
    if (!current) return
    var description = current.description.replace(/\s+/g, " ").trim()
    // "(env: X)" is documentation, not part of the summary.
    description = description.replace(/\(env:\s*[A-Z0-9_]+\)/g, "").trim()
    var def = extractDefault(description)
    var flag = canonicalFlag(current.flags)
    if (flag) {
      params.push({
        key: flag,
        flags: current.flags,
        flag: flag,
        label: flag.replace(/^--/, ""),
        arg: current.arg,
        type: inferType(current.arg, description, def, current.flags),
        options: inferType(current.arg, description, def, current.flags) === "tristate"
          ? TRISTATE_OPTIONS.slice()
          : enumOptions(current.arg, description),
        negatedFlag: isNegatablePair(current.flags) ? negatedForm(flag) : "",
        defaultValue: def,
        defaultHint: extractDefaultHint(description),
        description: description,
        section: section
      })
    }
    current = null
  }

  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    if (line.trim() === "") continue

    var header = line.match(/^-{3,}\s*(.+?)\s*-{3,}$/)
    if (header) { flush(); section = header[1]; continue }

    if (isFlagToken(line)) {
      flush()
      // Two or more spaces separate the columns. Aliases can occupy their own
      // chunk ("-t," then "--threads N"), so leading chunks are consumed while
      // they still look like flags; the remainder is the description.
      //
      // The chunks are kept as an array rather than rejoined -- rejoining
      // collapses the very separators the next split depends on, which
      // silently drops the value placeholder and the default.
      var chunks = line.split(/\s{2,}/)
      var flags = []
      var arg = ""
      while (chunks.length > 0) {
        var fa = splitFlagsAndArg(chunks[0])
        if (fa.flags.length === 0) break
        flags = flags.concat(fa.flags)
        chunks.shift()
        if (fa.arg !== "") { arg = fa.arg; break }
      }
      current = { flags: flags, arg: arg, description: chunks.join(" ") }
      continue
    }

    // Indented continuation of the current description.
    if (current) current.description += " " + line.trim()
  }
  flush()
  return params
}

// ---- ollama --------------------------------------------------------------
//
// ollama takes almost nothing on the command line; its tunables are
// environment variables, listed by `ollama serve --help` as:
//
//       OLLAMA_KEEP_ALIVE   The duration that models stay loaded (default "5m")

function parseOllamaHelp(text) {
  var lines = String(text || "").split("\n")
  var params = []
  for (var i = 0; i < lines.length; i++) {
    var m = lines[i].match(/^\s+(OLLAMA_[A-Z0-9_]+)\s{2,}(.+)$/)
    if (!m) continue
    var name = m[1]
    var description = m[2].trim()
    var def = extractDefault(description)
    params.push({
      key: name,
      flags: [name],
      flag: name,
      label: name.replace(/^OLLAMA_/, "").toLowerCase().replace(/_/g, " "),
      arg: "VALUE",
      type: /^-?\d+$/.test(def) ? "int" : "string",
      options: [],
      negatedFlag: "",
      defaultValue: def,
      defaultHint: extractDefaultHint(description),
      description: description,
      section: "environment"
    })
  }
  return params
}

function parse(backendId, helpText) {
  return backendId === "ollama" ? parseOllamaHelp(helpText) : parseLlamaHelp(helpText)
}

// ---- Using the catalogue -------------------------------------------------

function find(catalogue, key) {
  for (var i = 0; i < (catalogue || []).length; i++)
    if (catalogue[i].key === key) return catalogue[i]
  return null
}

// The parameter a flag belongs to, by any name it is written under: the short
// alias, the long form, or the negation. Needed wherever the text came from a
// human rather than from the catalogue -- "-np" and "--parallel" are the same
// setting, and a lookup on the canonical key alone sees only the second.
function findByFlag(catalogue, flag) {
  var wanted = String(flag || "")
  if (wanted === "") return null
  var list = catalogue || []
  var i, j
  for (i = 0; i < list.length; i++) {
    var flags = list[i].flags || []
    for (j = 0; j < flags.length; j++) if (flags[j] === wanted) return list[i]
  }
  // A negation llama.cpp documents only implicitly, by pairing it on the same
  // line -- "--no-reasoning-preserve" is never listed separately.
  for (i = 0; i < list.length; i++)
    if (list[i].negatedFlag && list[i].negatedFlag === wanted) return list[i]
  return null
}

// Options for the "add a parameter" picker: everything not already added, and
// not already covered by a dedicated control on the page.
function availableOptions(catalogue, addedKeys, reservedKeys) {
  var out = []
  for (var i = 0; i < (catalogue || []).length; i++) {
    var p = catalogue[i]
    if ((addedKeys || []).indexOf(p.key) !== -1) continue
    if ((reservedKeys || []).indexOf(p.key) !== -1) continue
    out.push({
      value: p.key,
      label: p.label,
      description: p.description.length > 90 ? p.description.slice(0, 87) + "…" : p.description
    })
  }
  return out
}

// A stand-in descriptor for a flag the catalogue does not carry.
//
// The catalogue is generated from the binary's --help, so a flag can be
// genuinely absent from it: one only an alternate build understands, one typed
// before the catalogue finished loading, or one a newer llama.cpp dropped. The
// row still has to render and, more importantly, still has to reach the server
// -- a parameter that renders but is silently skipped at launch is worse than
// one that was never accepted.
function fallbackSpec(key, type) {
  var flag = String(key || "")
  return {
    key: flag,
    flags: [flag],
    flag: flag,
    label: flag.replace(/^--?/, ""),
    arg: type === "bool" ? "" : "VALUE",
    type: type === "bool" ? "bool" : "string",
    options: [],
    negatedFlag: "",
    defaultValue: "",
    defaultHint: "",
    description: "Not in this build's --help — passed through as typed.",
    section: "unrecognised"
  }
}

// Turns a hand-written command line into one entry per parameter.
//
// Which tokens are values cannot be read off their shape: "--gpu-layers -1"
// and "--flash-attn --verbose" look identical to a scanner that assumes a
// leading dash starts a flag. The catalogue decides instead -- a parameter
// documented with a value placeholder consumes the next token, one documented
// without takes none -- and only a flag the catalogue does not know falls back
// to the shape of what follows it.
//
// Anything that cannot be attributed to a flag comes back as leftover rather
// than being dropped: what the user typed is not this function's to discard.
function fromTokens(catalogue, tokens) {
  var list = tokens || []
  var params = []
  var leftover = []
  var i = 0

  while (i < list.length) {
    var token = String(list[i])
    i += 1

    if (!isFlagToken(token)) { leftover.push(token); continue }

    // "--ctx-size=4096" -- accepted by many tools and typed by habit.
    var value = null
    var eq = token.indexOf("=")
    if (eq > 0) {
      value = token.slice(eq + 1)
      token = token.slice(0, eq)
    }

    var spec = findByFlag(catalogue, token)

    if (spec && spec.type === "tristate") {
      params.push({ key: spec.key, value: token === spec.key ? "on" : "off" })
      continue
    }
    if (spec && spec.type === "bool") {
      params.push({ key: spec.key, value: "true" })
      continue
    }
    if (spec) {
      if (value === null) {
        // Documented with a placeholder, so the next token is its value
        // whatever it looks like.
        if (i < list.length) { value = String(list[i]); i += 1 }
        else { leftover.push(token); continue }
      }
      params.push({ key: spec.key, value: value })
      continue
    }

    // Unknown: guess from what follows, and record the guess so the launch
    // line does not have to make it again from a bare string.
    if (value === null && i < list.length && !isFlagToken(String(list[i]))) {
      value = String(list[i])
      i += 1
    }
    if (value === null) params.push({ key: token, value: "true", type: "bool" })
    else params.push({ key: token, value: value, type: "string" })
  }

  return { params: params, leftover: leftover }
}

// Renders one custom parameter into argv.
//
// A boolean flag contributes only itself, and only when on. Everything else
// contributes flag + value, and is skipped when blank so an added-but-unset
// parameter cannot produce a dangling flag with no argument.
function toArgv(param, value) {
  if (!param) return []
  var v = String(value === undefined || value === null ? "" : value).trim()
  if (param.type === "tristate") {
    if (v === "on" || v === "true" || v === "1") return [param.flag]
    if (v === "off" || v === "false" || v === "0")
      return [param.negatedFlag || negatedForm(param.flag)]
    // "default", and anything a stored value predating this type holds: pass
    // nothing, which is what leaves the backend on its own default.
    return []
  }
  if (param.type === "bool") return (v === "true" || v === "1") ? [param.flag] : []
  if (v === "") return []
  return [param.flag, v]
}

// ollama parameters are environment assignments rather than argv.
function toEnvEntry(param, value) {
  if (!param) return null
  var v = String(value === undefined || value === null ? "" : value).trim()
  if (v === "") return null
  return { name: param.key, value: v }
}

if (typeof module !== "undefined") {
  module.exports = {
    splitFlagsAndArg: splitFlagsAndArg,
    canonicalFlag: canonicalFlag,
    negatedForm: negatedForm,
    isNegatablePair: isNegatablePair,
    TRISTATE_OPTIONS: TRISTATE_OPTIONS,
    extractDefault: extractDefault,
    extractDefaultHint: extractDefaultHint,
    inferType: inferType,
    enumOptions: enumOptions,
    parseLlamaHelp: parseLlamaHelp,
    parseOllamaHelp: parseOllamaHelp,
    parse: parse,
    find: find,
    findByFlag: findByFlag,
    fallbackSpec: fallbackSpec,
    fromTokens: fromTokens,
    availableOptions: availableOptions,
    toArgv: toArgv,
    toEnvEntry: toEnvEntry
  }
}
