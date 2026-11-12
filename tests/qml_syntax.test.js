"use strict"

// Panel.qml is 71% of this plugin and nothing else here reads it: the JS tests
// below import .js modules, and `omarchy plugin validate` checks the manifest.
// Appending garbage to Panel.qml leaves both of them green while the widget
// fails to load on the bar -- which is how commit 4869e3f shipped calls to a
// function that had been deleted.
//
// Qt's QML compiler is the one tool that tells the two apart. qmllint and
// qmlformat both exit non-zero on the good file, so neither can.

const test = require("node:test")
const assert = require("node:assert")
const fs = require("node:fs")
const os = require("node:os")
const path = require("node:path")
const { execFileSync } = require("node:child_process")

const ROOT = path.join(__dirname, "..")

function compiler() {
  for (const candidate of ["/usr/lib/qt6/qmlcachegen", "/usr/bin/qmlcachegen",
                           "/usr/lib/qt5/bin/qmlcachegen"])
    if (fs.existsSync(candidate)) return candidate
  return null
}

// Output goes to /dev/null on purpose: with a real output path the compiler
// stops at "No resource path for file" before it parses anything, and reports
// nothing either way.
function syntaxErrors(file) {
  const cc = compiler()
  assert.ok(cc, "qmlcachegen not found — install qt6-declarative; this plugin cannot be built without it")
  let out = ""
  try {
    out = execFileSync(cc, ["-o", "/dev/null", file], { encoding: "utf8", stdio: "pipe" })
  } catch (e) {
    out = String((e.stdout || "") + (e.stderr || ""))
  }
  return out.split("\n").filter((line) => /error:/i.test(line))
}

test("every QML file in the plugin parses", () => {
  for (const name of fs.readdirSync(ROOT).filter((f) => f.endsWith(".qml"))) {
    const errors = syntaxErrors(path.join(ROOT, name))
    assert.deepStrictEqual(errors, [], name + " does not parse:\n" + errors.join("\n"))
  }
})

test("the check actually fails on a broken file", () => {
  // Without this, a compiler that silently stopped working would leave the
  // test above green for ever.
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "qmlcheck-"))
  try {
    const broken = path.join(dir, "Broken.qml")
    fs.writeFileSync(broken, "import QtQuick\nItem {\n  THIS IS NOT VALID {{{\n")
    assert.ok(syntaxErrors(broken).length > 0, "a broken QML file reported no error")
  } finally {
    fs.rmSync(dir, { recursive: true, force: true })
  }
})
