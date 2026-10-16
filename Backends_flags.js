// ---- Flag support per build (étape 7: tolérance aux paramètres non supportés) ----
//
// A build carries a `flags` array extracted from its --help by llama_builds.py.
// supportsFlag(build, flag) returns true when the flag (or an alias) is present,
// or when the build is unknown (no flags known = assume all supported).

// Map of canonical flag name → aliases. Filled from --help during probing.
var flagAliases = {}

function registerFlagAliases(canonical, aliases) {
  flagAliases[canonical] = aliases
}

function supportsFlag(build, flag) {
  // Unknown build or no flags known → assume supported
  if (!build || !build.flags || build.flags.length === 0) return true
  // Direct match
  if (build.flags.indexOf(flag) !== -1) return true
  // Check aliases
  var aliases = flagAliases[flag]
  if (aliases) {
    for (var i = 0; i < aliases.length; i++)
      if (build.flags.indexOf(aliases[i]) !== -1) return true
  }
  // Also check canonical name of alias variants
  for (var key in flagAliases) {
    var list = flagAliases[key]
    for (var j = 0; j < list.length; j++) {
      if (list[j] === flag && build.flags.indexOf(key) !== -1) return true
    }
  }
  return false
}

