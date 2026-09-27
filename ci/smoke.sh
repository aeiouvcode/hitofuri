#!/usr/bin/env bash
# apk-smoke v2: install -> launch -> soak -> screenshots -> monkey -> post-shot -> logcat verdict.
# v2 fixes (critic grade of run 4): suppress immersive hint before captures, never claim "render"
# from survival alone, post-monkey frame must differ or FAIL, explicit RENDER-UNKNOWN state.
set -u
APK="${1:?usage: smoke.sh <path-to-apk>}"
OUT="${2:-smoke-out}"
mkdir -p "$OUT"
VERDICT="$OUT/VERDICT.txt"
FAIL=0
RENDER=UNKNOWN
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

# --- suppress the immersive-mode hint overlay (run 4: it froze frames and hid content) ---
adb shell settings put global immersive_mode_confirmations confirmed

# --- launch ---
adb shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 > /dev/null 2>&1
if [ $? -ne 0 ]; then note "FAIL: could not fire launcher intent for $PKG"; exit 1; fi

shot() { adb exec-out screencap -p > "$OUT/$1.png" 2>/dev/null; [ -s "$OUT/$1.png" ]; }
sleep 10; shot shot_t10 || note "WARN: screencap t10 empty"
sleep 20; shot shot_t30 || note "WARN: screencap t30 empty"
sleep 30; shot shot_t60 || note "WARN: screencap t60 empty"

for t in 10 30 60; do
  f="$OUT/shot_t$t.png"
  [ -f "$f" ] || continue
  b=$(stat -c%s "$f")
  if [ "$b" -lt 8000 ]; then note "WARN: $f is ${b}B - possibly blank/solid frame (heuristic)"; fi
done
same() { [ -f "$1" ] && [ -f "$2" ] && [ "$(sha256sum "$1" | cut -d' ' -f1)" = "$(sha256sum "$2" | cut -d' ' -f1)" ]; }
if same "$OUT/shot_t30.png" "$OUT/shot_t60.png"; then
  note "WARN: t30/t60 pixel-identical after overlay suppression - static screen or stalled render (heuristic)"
fi

# --- crash smoke ---
adb shell monkey -p "$PKG" --pct-touch 70 --pct-motion 20 --pct-syskeys 0 --throttle 200 500 > "$OUT/monkey.txt" 2>&1
grep -q "Events injected: 500" "$OUT/monkey.txt" && note "MONKEY OK: 500 events injected" || note "WARN: monkey did not complete 500 events (see monkey.txt)"

# --- post-monkey frame: a live app must respond to 500 input events ---
sleep 3; shot shot_postmonkey || note "WARN: post-monkey screencap empty"
if [ -f "$OUT/shot_t60.png" ] && [ -f "$OUT/shot_postmonkey.png" ]; then
  if same "$OUT/shot_t60.png" "$OUT/shot_postmonkey.png"; then
    note "FAIL: frame unchanged after 500 input events - no visual response to input (frozen render or dead surface)"
    FAIL=1; RENDER=NO-RESPONSE
  else
    RENDER=RESPONSIVE
    note "RENDER OK: frame changed in response to input"
  fi
fi

# --- logcat verdict ---
adb logcat -d > "$OUT/logcat.txt" 2>&1
if grep -q "FATAL EXCEPTION" "$OUT/logcat.txt"; then
  note "FAIL: FATAL EXCEPTION in logcat:"; grep -m3 -A5 "FATAL EXCEPTION" "$OUT/logcat.txt" | tee -a "$VERDICT"; FAIL=1
fi
if grep -q "ANR in $PKG" "$OUT/logcat.txt"; then note "FAIL: ANR in $PKG"; FAIL=1; fi
if grep -qE "Process $PKG .*has died|Force finishing activity $PKG" "$OUT/logcat.txt"; then
  note "WARN: process died / force-finish recorded for $PKG (see logcat)"
fi

# --- shader link failures: render died at GL level - name it precisely ---
if grep -qE 'Program linking failed|GL_MAX_' "$OUT/logcat.txt"; then
  note "FAIL: shader link failure (GL uniform limit exceeded on this device's GLES3):"
  grep -m3 -A1 -E 'Program linking failed|GL_MAX_' "$OUT/logcat.txt" | tee -a "$VERDICT"
  FAIL=1
  if [ "$RENDER" = "UNKNOWN" ] || [ "$RENDER" = "NO-RESPONSE" ]; then RENDER="SHADER-LINK-FAIL"; fi
fi

note "RENDER STATE: $RENDER (survival does not prove rendering; pixels do)"
if [ "$FAIL" -eq 0 ]; then note "VERDICT: PASS (install+launch+survives input, no fatal log entries; render state above)"
else note "VERDICT: FAIL"; exit 1; fi
