//
//  sh_renderfx.qc — GoldSrc kRenderFx* animation evaluator
//
//  Pure-function evaluator that takes a base (alpha, colormod, effects)
//  plus a renderfx enum (0..16) and elapsed time since the entity's
//  animation epoch, and writes the modulated alpha/colormod/effects to
//  `self`.  Callers (CSQC predraw for brushsync brushes + point
//  entities) are responsible for storing the BASE values once when the
//  entity is updated, and passing them in every frame so the modulator
//  starts from a stable origin.
//
//  GoldSrc renderfx values:
//    0  Normal               — no modulation (identity copy).
//    1  Slow Pulse           — sin wave, freq 4 rad/s, amp 0.3.
//    2  Fast Pulse           — sin wave, freq 10 rad/s, amp 0.3.
//    3  Slow Wide Pulse      — sin wave, freq 4, amp 0.5.
//    4  Fast Wide Pulse      — sin wave, freq 10, amp 0.5.
//    5  Slow Fade Away       — linear decay to 0 over 15 s, then off.
//    6  Fast Fade Away       — linear decay to 0 over 3 s, then off.
//    7  Slow Become Solid    — linear ramp to 1 over 15 s, then full.
//    8  Fast Become Solid    — linear ramp to 1 over 3 s, then full.
//    9  Slow Strobe          — 0.5 s on / 0.1 s off square wave.
//    10 Fast Strobe          — 0.1 s on / 0.05 s off.
//    11 Faster Strobe        — 0.05 s on / 0.025 s off.
//    12 Slow Flicker         — quasi-random alpha [0.3, 1.0] every 0.1 s.
//    13 Fast Flicker         — quasi-random every 0.05 s.
//    14 Constant Glow        — force EF_ADDITIVE (no alpha modulation).
//    15 Distort              — base alpha; jitter handled by caller's
//                              origin offset.
//    16 Hologram             — slow alpha pulse + jitter (distort + fade).
//
//  Values 1..13 modulate alpha only.  14 ORs EF_ADDITIVE into effects.
//  15 and 16 set a sentinel on .effects (RENDERFX_JITTER_FLAG) so the
//  caller's predraw can apply a small per-frame origin offset; the
//  helper itself only modulates alpha for those.
//
//  Naming convention: `BrushSync_*` to match the existing
//  BrushSync_ApplyRenderKeys helper, even though this is used by
//  point entities too — keeps the "render-key plumbing" namespace
//  cohesive.
//

// EF_ADDITIVE constant — duplicated from sv_brushsync.qc to keep
// this helper self-contained.  Both files use the same numeric value
// (32) so fteqcc shares the constant slot.
#ifndef SOLIDBRUSH_EF_ADDITIVE
const float SOLIDBRUSH_EF_ADDITIVE = 32;
#endif

// Sentinel bit caller checks to apply origin jitter for renderfx
// 15 (Distort) and 16 (Hologram).  Picks a high bit so it doesn't
// collide with engine EF_* flags.  The caller is expected to mask
// this off before assigning to self.effects (or before networking).
const float RENDERFX_JITTER_FLAG = 1048576;     // 1 << 20

// Quasi-random alpha for flicker.  Step-quantised on `quantum` so
// the alpha holds a constant value for `quantum` seconds then jumps.
// Using sin/cos-based hashes instead of random() so the pattern is
// deterministic across CSQC/SSQC runs (matters when both sides
// evaluate the helper for the same entity).
float(float t, float quantum) BrushSync_FlickerSample =
{
    float bucket = floor(t / quantum);
    // Deterministic pseudo-random in [0,1] from bucket index.  Two
    // sin terms with irrational coefficients give a flat-ish
    // distribution without any QC builtin RNG.
    float h = sin(bucket * 12.9898 + 78.233);
    h = h - floor(h);     // fract — clamp to [0, 1)
    // Map to [0.3, 1.0] alpha range (matches HL flicker bias).
    return 0.3 + h * 0.7;
};

void(float base_alpha,
     vector base_colormod,
     float  base_effects,
     float  fx,
     float  t) BrushSync_ApplyRenderFX =
{
    // Default: identity copy.  Covers fx == 0 and any out-of-range
    // value the wire could legally carry (bound 0..16 on send).
    self.alpha    = base_alpha;
    self.colormod = base_colormod;
    self.effects  = base_effects;

    if (fx <= 0 || fx > 16) return;
    if (t < 0) t = 0;       // guard against backward clock drift

    float a_mul = 1;        // multiplied into base_alpha at the end

    // ---- Pulse family (1..4): sin wave alpha modulation ----
    if (fx == 1)        a_mul = 1 + 0.3 * sin(t * 4);
    else if (fx == 2)   a_mul = 1 + 0.3 * sin(t * 10);
    else if (fx == 3)   a_mul = 1 + 0.5 * sin(t * 4);
    else if (fx == 4)   a_mul = 1 + 0.5 * sin(t * 10);

    // ---- Fade family (5..8): linear ramp on alpha ----
    else if (fx == 5)   a_mul = max(0, 1 - t / 15);    // slow fade away
    else if (fx == 6)   a_mul = max(0, 1 - t / 3);     // fast fade away
    else if (fx == 7)   a_mul = min(1, t / 15);        // slow become solid
    else if (fx == 8)   a_mul = min(1, t / 3);         // fast become solid

    // ---- Strobe family (9..11): square-wave on/off ----
    // period = on_time + off_time; alpha = base when phase < on_time
    // else 0.  Matches HL's "strobe" rather than "flicker" cadence.
    else if (fx == 9 || fx == 10 || fx == 11)
    {
        float on_time, off_time;
        if (fx == 9)       { on_time = 0.5;  off_time = 0.1;  }
        else if (fx == 10) { on_time = 0.1;  off_time = 0.05; }
        else               { on_time = 0.05; off_time = 0.025; }
        float period = on_time + off_time;
        float phase  = t - floor(t / period) * period;     // fmod
        a_mul = (phase < on_time) ? 1 : 0;
    }

    // ---- Flicker family (12..13): pseudo-random per quantum ----
    else if (fx == 12)  a_mul = BrushSync_FlickerSample(t, 0.1);
    else if (fx == 13)  a_mul = BrushSync_FlickerSample(t, 0.05);

    // ---- Special family (14..16) ----
    else if (fx == 14)
    {
        // Constant glow — keep alpha; force additive blend.
        self.effects = base_effects | SOLIDBRUSH_EF_ADDITIVE;
        return;
    }
    else if (fx == 15)
    {
        // Distort — alpha unchanged; caller applies origin jitter
        // when it sees the sentinel bit set.
        self.effects = base_effects | RENDERFX_JITTER_FLAG;
        return;
    }
    else if (fx == 16)
    {
        // Hologram — slow pulse + jitter.  Combine pulse formula
        // with the jitter sentinel.
        a_mul = 1 + 0.3 * sin(t * 6);
        self.effects = base_effects | RENDERFX_JITTER_FLAG;
    }

    // Clamp the result.  Some formulas can dip below 0 or above 1;
    // alpha outside that range is undefined behaviour.
    float a_out = base_alpha * a_mul;
    if (a_out < 0) a_out = 0;
    if (a_out > 1) a_out = 1;
    self.alpha = a_out;
};
