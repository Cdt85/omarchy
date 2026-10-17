#!/bin/bash

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/base-test.sh"

# QML evaluates a shell JS module again for every delegate whose component
# imports it, unless the module is `.pragma library`. While it does, any name
# the module's top level looks up without declaring it walks the delegate's
# context into Qt's list accessor, and when the Repeater's array model holds a
# destroyed object that walk crashes Quickshell (#11727). Builtins are no
# exception: `Math.PI`, `NaN`, `typeof console` and `globalThis` all crash
# Qt 6.11.2 there. `Qt` is found through the imports first, and `undefined`
# and `Infinity` compile to constants. Code inside a function only runs when
# something calls it, so a module stays safe as long as its top level, and
# anything that top level calls, uses only what the module declares.

run_node_test <<'JS'
const fs = require('fs')
const vm = require('vm')

const SAFE_AT_TOP_LEVEL = new Set(['Qt', 'undefined', 'Infinity'])

// Runs a module's top level against a global object that records every name
// looked up on it and answers each with a stub, so evaluation goes on and all
// of them are seen. The module's own declarations stay local to the wrapper.
function contextLookups(source) {
  const seen = new Set()
  const stub = new Proxy(function () {}, {
    get: (target, key) => (key === Symbol.toPrimitive ? () => 0 : stub),
    apply: () => stub,
    construct: () => stub
  })
  const global = new Proxy({}, {
    has(target, name) {
      if (typeof name === 'string') seen.add(name)
      return false
    },
    get(target, name) {
      if (typeof name === 'string') seen.add(name)
      return stub
    }
  })
  const body = source.replace(/^\.(pragma|import) .*$/gm, '')
  try {
    vm.runInContext(`(function () {\n${body}\n})()`, vm.createContext(global))
  } catch (error) {
    seen.add(`(top level threw: ${error.message})`)
  }
  return [...seen].filter((name) => !SAFE_AT_TOP_LEVEL.has(name)).sort()
}

// Each of these was run against Qt 6.11.2 as a delegate's module: the first
// group crashes it, the second does not.
const crashes = {
  'a typeof module guard': 'if (typeof module !== "undefined") module.exports = { f: f }',
  'a parenthesised guard': 'if (typeof(module) !== "undefined") module["exports"] = { f: f }',
  'a global through globalThis': 'var m = globalThis.module',
  'a builtin': 'var TAU = Math.PI * 2',
  'a builtin reached through a top-level call': 'function tau() { return Math.PI * 2 }\nvar TAU = tau()',
  'NaN': 'var missing = NaN'
}
const safe = {
  'builtins inside a function': 'function tau() { return Math.PI * 2 }',
  'local declarations and literals': 'var a = 1\nconst b = { c: [a, 2], d: "x".toUpperCase(), e: /x+/g }\nvar f = b.c.map(function (x) { return x * 2 })',
  'Qt, undefined and Infinity': 'var hasQt = typeof Qt !== "undefined"\nvar u = undefined\nvar big = Infinity'
}
for (const [name, source] of Object.entries(crashes)) {
  assert(contextLookups(source).length > 0, `the module scope check catches ${name}`)
}
for (const [name, source] of Object.entries(safe)) {
  assertDeepEqual(contextLookups(source), [], `the module scope check allows ${name}`)
}

function shellModules(dir) {
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const file = path.join(dir, entry.name)
    if (entry.isDirectory()) return shellModules(file)
    return entry.name.endsWith('.js') ? [file] : []
  })
}

const offenders = []
let checked = 0
for (const file of shellModules(path.join(root, 'shell'))) {
  const source = fs.readFileSync(file, 'utf8')
  if (/^\.pragma library\b/m.test(source)) continue
  checked++
  const names = contextLookups(source)
  if (names.length) offenders.push(`${path.relative(root, file)}: ${names.join(', ')}`)
}
assert(checked > 30, 'the module scope check finds the shell JS modules', `checked ${checked}`)
assert(
  offenders.length === 0,
  'shell JS modules look up nothing at their top level that they do not declare',
  offenders.join('\n')
)
JS

# The same thing in Qt itself, where it is installed: a Repeater per module
# whose array model keeps getting a destroyed object, and a delegate that
# imports the module.
qml_bin=$(command -v qml6 || command -v qml || ls /usr/lib/qt6/bin/qml 2>/dev/null || true)
if [[ -z $qml_bin ]]; then
  skip "shell JS modules survive delegate creation in Qt (Qt's qml runtime is not installed)"
  exit 0
fi

work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

repeaters=""
index=0
while IFS= read -r module; do
  grep -q '^\.pragma library' "$module" && continue
  (( ++index ))
  printf 'import QtQuick\nimport "file://%s" as Module\nItem { property string label: String(modelData) }\n' "$module" >"$work_dir/Row$index.qml"
  repeaters+="  Repeater { model: root.rows; delegate: Row$index {} }"$'\n'
done < <(find "$ROOT/shell" -name '*.js' | sort)

cat >"$work_dir/main.qml" <<QML
import QtQuick
Item {
  id: root
  property var rows: []
  property var held: []
  property bool armed: false
  property int reassigned: 0
  Component { id: row; QtObject {} }
$repeaters
  Timer {
    interval: 20; repeat: true; running: true
    onTriggered: {
      if (!root.armed) {
        var dead = row.createObject(null)
        root.held = [dead]
        dead.destroy()
        root.armed = true
        return
      }
      root.rows = [root.held[0], row.createObject(root)]
      root.armed = false
      if (++root.reassigned >= 10) { console.warn("survived", root.reassigned); Qt.quit() }
    }
  }
}
QML

status=0
output=$(ulimit -c 0; QT_QPA_PLATFORM=offscreen QT_FORCE_STDERR_LOGGING=1 timeout 60 "$qml_bin" "$work_dir/main.qml" 2>&1) || status=$?
if (( status == 0 )) && [[ $output == *"survived 10"* ]]; then
  pass "$index shell JS modules survive delegate creation in Qt"
else
  fail "$index shell JS modules survive delegate creation in Qt" "exit $status: $output"
fi
