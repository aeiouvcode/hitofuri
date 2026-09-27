# Smoke gate renderer calibration (2026-09-27)

## Basis for the change

The apk-smoke gate (ci/smoke.sh) failed the ISSEN CI APK with:

    FAIL: shader link failure (GL uniform limit exceeded on this device's GLES3)
    E godot: ERROR: SceneShaderGLES3: Program linking failed

A decisive experiment isolated instrument vs app: ci/empty-scene/ builds a
minimal Godot 4.5 gl_compatibility project (one lit StandardMaterial3D box +
one Label - the smallest scene exercising Godot's base scene and canvas shader
paths) and runs the same smoke.sh v3 against it in CI.

Result (workflow empty-scene-smoke, run 36315964496, job 108610605242,
artifact 10930537693): the minimal scene failed the SAME shader-link check
with the SAME logcat signature. A near-empty project cannot exceed a real
device's GLES3 uniform budget, so the gate's emulator profile - the
android-emulator-runner default `-gpu swiftshader_indirect` - enforces GLES3
uniform limits stricter than any shipping device. The 261-link failure was an
instrument artifact, not an ISSEN defect.

## The change

Both emulator workflows now launch with:

    emulator-options: -no-window -gpu angle_indirect -noaudio -no-boot-anim -camera-back none

`-gpu angle_indirect` runs GLES3 through ANGLE on top of SwiftShader's Vulkan
backend (SwiftANGLE): still fully software-rendered and CI-safe (no host GPU
required), but with uniform limits representative of real GLES3 devices.

## What the gate still measures

The recalibration changes ONLY the renderer profile. smoke.sh still fails on:
static badging problems, install rejection, launch failure, frozen frames
(post-monkey frame must differ), blank-frame heuristics, and crash/logcat
errors. The gate measures app defects; the renderer is no longer one of them.
