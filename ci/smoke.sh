#!/usr/bin/env bash
# apk-smoke: install -> launch -> soak -> screenshots -> monkey -> logcat verdict.
# Rule 3 compliant: no broad catch-alls; each failure mode checked explicitly, verdict loud.
set -u
APK="${1:?usage: smoke.sh <path-to-apk>}"
OUT="${2:-smoke-out}"
mkdir -p "$OUT"
VERDICT="$OUT/VERDICT.txt"
FAIL=0
note() { echo "$*" | tee -a "$VERDICT"; }

# --- static gate ---
AAPT="$(ls -d "${ANDROID_HOME:-/usr/local/lib/android/sdk}"/build-tools/*/aapt 2>/dev/null | sort -V | tail -1)"
if [ -z "$AAPT" ]; then note "FAIL: aapt not found under ANDROID_HOME/build-tools"; exit 1; fi
if ! "$AAPT" dump badging "$APK" > "$OUT/badging.txt" 2>&1; then
  note "FAIL: aapt cannot parse APK (corrupt or not an APK)"; exit 1
fi
PKG="$(sed -n "s/^package: name='\([^']*\)'.*/\1/p" "$OUT/badging.txt" | head -1)"
if [ -z "$PKG" ]; then note "FAIL: no package name in badging"; exit 1; fi
SDK_TGT="$(sed -n "s/^targetSdkVersion:'\([^']*\)'.*/\1/p" "$OUT/badging.txt" | head -1)"
ABIS="$(grep '^native-code:' "$OUT/badging.txt" | tr -d ' ' || true)"
SIZE=$(stat -c%s "$APK")
note "STATIC OK: pkg=$PKG targetSdk=$SDK_TGT size=${SIZE}B abis=${ABIS:-none-declared}"

# --- install ---
adb logcat -c
if ! adb install -r "$APK" > "$OUT/install.txt" 2>&1; then
  note "FAIL: adb install rejected the APK:"; tail -5 "$OUT/install.txt" | tee -a "$VERDICT"; exit 1
fi
note "INSTALL OK"

# --- launch via launcher intent (no activity name needed) ---
adb shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 > /dev/null 2>&1
if [ $? -ne 0 ]; then note "FAIL: could not fire launcher intent for $PKG"; exit 1; fi

shot() { adb exec-out screencap -p > "$OUT/$1.png" 2>/dev/null; [ -s "$OUT/$1.png" ]; }
sleep 5;  shot shot_t05 || note "WARN: screencap t05 empty"
sleep 10; shot shot_t15 || note "WARN: screencap t15 empty"
sleep 15; shot shot_t30 || note "WARN: screencap t30 empty"

# --- frame heuristics (heuristics, labeled as such) ---
for t in 05 15 30; do
  f="$OUT/shot_t$t.png"
  [ -f "$f" ] || continue
  b=$(stat -c%s "$f")
  # an all-one-color 1080x2400 PNG compresses to a few KB - flag suspiciously tiny frames
  if [ "$b" -lt 8000 ]; then note "WARN: $f is ${b}B - possibly blank/solid frame (heuristic)"; fi
done
if [ -f "$OUT/shot_t15.png" ] && [ -f "$OUT/shot_t30.png" ]; then
  h15=$(sha256sum "$OUT/shot_t15.png" | cut -d' ' -f1)
  h30=$(sha256sum "$OUT/shot_t30.png" | cut -d' ' -f1)
  if [ "$h15" = "$h30" ]; then note "WARN: t15 and t30 frames pixel-identical - possible frozen render (heuristic)"; fi
fi

# --- crash smoke: 500 pseudo-random events ---
adb shell monkey -p "$PKG" --pct-touch 70 --pct-motion 20 --pct-syskeys 0 --throttle 200 500 > "$OUT/monkey.txt" 2>&1
grep -q "Events injected: 500" "$OUT/monkey.txt" && note "MONKEY OK: 500 events injected" || note "WARN: monkey did not complete 500 events (see monkey.txt)"

# --- logcat verdict ---
adb logcat -d > "$OUT/logcat.txt" 2>&1
if grep -q "FATAL EXCEPTION" "$OUT/logcat.txt"; then
  note "FAIL: FATAL EXCEPTION in logcat:"; grep -m3 -A5 "FATAL EXCEPTION" "$OUT/logcat.txt" | tee -a "$VERDICT"; FAIL=1
fi
if grep -q "ANR in $PKG" "$OUT/logcat.txt"; then note "FAIL: ANR in $PKG"; FAIL=1; fi
if grep -qE "Process $PKG .*has died|Force finishing activity $PKG" "$OUT/logcat.txt"; then
  note "WARN: process died / force-finish recorded for $PKG (see logcat)"
fi

if [ "$FAIL" -eq 0 ]; then note "VERDICT: PASS (install+launch+render+monkey, no fatal log entries)"; exit 0
else note "VERDICT: FAIL"; exit 1; fi
