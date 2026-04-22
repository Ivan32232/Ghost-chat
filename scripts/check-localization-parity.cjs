#!/usr/bin/env node
/* Localization parity checker — iOS `Localizable.xcstrings` keys (dot-separated)
 * must be in lock-step with Android `strings.xml` entries on both `values/` and
 * `values-ru/` (underscore-separated). Exit non-zero on any gap so CI (and the
 * Phase 7 verify script) blocks merges that introduce drift.
 */

const fs = require('fs');
const path = require('path');

const root = path.resolve(__dirname, '..');
const iosPath  = path.join(root, 'ios/GhostChat/Resources/Localizable.xcstrings');
const enPath   = path.join(root, 'android/app/src/main/res/values/strings.xml');
const ruPath   = path.join(root, 'android/app/src/main/res/values-ru/strings.xml');

function readIOSKeys() {
  const json = JSON.parse(fs.readFileSync(iosPath, 'utf8'));
  // Only count dot-separated identifier keys (section.name_with_underscores).
  // Xcode auto-extracts raw literals from SwiftUI source (e.g. "Recording…",
  // "Cannot display image", "%@") into the xcstrings file; those are NOT real
  // localization keys — they're just cached English strings — and should not
  // participate in parity. A real key matches /^[a-z][a-z0-9_]*(\.[a-z0-9_]+)+$/.
  const idKey = /^[a-z][a-z0-9_]*(\.[a-z0-9_]+)+$/;
  return new Set(Object.keys(json.strings || {}).filter(k => idKey.test(k)));
}

function readAndroidKeys(xmlPath) {
  const xml = fs.readFileSync(xmlPath, 'utf8');
  const rx = /<string\s+name="([^"]+)"/g;
  const out = new Set();
  let m;
  while ((m = rx.exec(xml)) != null) out.add(m[1]);
  return out;
}

function iosToAndroidKey(k) { return k.replace(/\./g, '_'); }
function androidToIosKey(k) { return k.replace(/_/g, '.'); }

const ios = readIOSKeys();
const en  = readAndroidKeys(enPath);
const ru  = readAndroidKeys(ruPath);

// "app_name" is seeded by the Android manifest and has no iOS counterpart — whitelisted.
const whitelist = new Set(['app_name']);

const iosAsAndroid = new Set([...ios].map(iosToAndroidKey));

let fails = 0;
function report(label, missing) {
  if (missing.length === 0) return;
  fails += missing.length;
  console.log(`  ${label} (${missing.length}):`);
  for (const k of missing) console.log(`    - ${k}`);
}

const missingFromEN = [...iosAsAndroid].filter(k => !en.has(k) && !whitelist.has(k));
const missingFromRU = [...iosAsAndroid].filter(k => !ru.has(k) && !whitelist.has(k));
const extraInEN = [...en].filter(k => !iosAsAndroid.has(k) && !whitelist.has(k));
const extraInRU = [...ru].filter(k => !iosAsAndroid.has(k) && !whitelist.has(k));
const mismatchEnRu = [...en].filter(k => !ru.has(k) && !whitelist.has(k))
  .concat([...ru].filter(k => !en.has(k) && !whitelist.has(k)));

console.log('Localization parity check:');
console.log(`  iOS keys:     ${ios.size}`);
console.log(`  Android EN:   ${en.size}`);
console.log(`  Android RU:   ${ru.size}`);
console.log('');
report('Android EN missing (present in iOS, absent in values/)', missingFromEN);
report('Android RU missing (present in iOS, absent in values-ru/)', missingFromRU);
report('Android EN has keys absent in iOS', extraInEN);
report('Android RU has keys absent in iOS', extraInRU);
report('Android EN ↔ RU drift (keys in one locale but not the other)', [...new Set(mismatchEnRu)]);

if (fails === 0) {
  console.log('OK: every key present on all three surfaces.');
  process.exit(0);
} else {
  console.error(`FAIL: ${fails} gap(s).`);
  process.exit(1);
}
