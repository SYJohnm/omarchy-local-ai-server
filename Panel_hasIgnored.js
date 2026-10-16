  // Check if any of a row's flags were ignored this build
  function rowHasIgnoredFlag(id) {
    var row = null
    for (var i = 0; i < root.builtinRows.length; i++) {
      if (root.builtinRows[i].id === id) { row = root.builtinRows[i]; break }
    }
    if (!row) return false
    var rowFlags = []
    for (var j = 0; j < row.props.length; j++) {
      var spec = Params.find(root.paramCatalogue, row.props[j])
      if (spec) rowFlags.push(spec.flag)
      // Check all params in catalogue that map to this row's props
      for (var k = 0; k < root.paramCatalogue.length; k += 3) {
        var flag = root.paramCatalogue[k]
        if (row.props.indexOf(root.paramCatalogue[k + 1]) !== -1)
          rowFlags.push(flag)
      }
    }
    for (var f = 0; f < rowFlags.length; f++)
      if (ignoredFlags.indexOf(rowFlags[f]) !== -1) return true
    return false
  }
