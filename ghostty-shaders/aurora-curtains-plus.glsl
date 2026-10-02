// Aurora "Siri-style" border glow shader -- PLUS variant.
//
// Like aurora-curtains.glsl but tuned to feel more alive: faster
// breathing, bigger organic ripples, per-edge phase offsets so the
// four borders don't move in lockstep, an animated outer halo that
// pulses around the bezel, and a slow "aurora curtain" drift along
// each edge.
//
// Crucially, the BRIGHT CORE stays locked to the outermost ~10% of
// the screen. The animation lives in the halo, the curtain, the
// background wash, and the breathing -- none of which spread past the
// edge region. Terminal glyphs in the middle of the screen stay as
// readable as in the base variant.
//
// Composites the same way as mnoise.glsl / aurora-curtains.glsl:
// sample iChannel0, ADD the glow on top, preserve terminalColor.a.

// ---------- Noise helpers (cheap, shadertoy-safe) ----------
float hash21(vec2 p) {
    p = fract(p * vec2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

float noise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float a = hash21(i);
    float b = hash21(i + vec2(1.0, 0.0));
    float c = hash21(i + vec2(0.0, 1.0));
    float d = hash21(i + vec2(1.0, 1.0));
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

// Smooth unit-range noise used for the edge ripples.
float edgeNoise(float u, float t) {
    return noise(vec2(u * 6.0, t * 0.6));
}

// 3-octave fbm used for the aurora curtain. Returns ~[0, 1].
float fbm3(vec2 p) {
    float v = 0.0;
    float a = 0.5;
    for (int i = 0; i < 3; i++) {
        v += a * noise(p);
        p *= 2.07;
        a *= 0.5;
    }
    return v;
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    // ============================================================
    //  CONFIG -- tweak these, everything visible responds to them
    // ============================================================

    // -- Base background (what shows through behind the glow) --
    vec3  bgColor       = vec3(0.0, 0.0, 0.0);   // inner background
    float bgNoiseAmount = 0.020;                 // slightly more grain
    float bgNoiseScale  = 6.0;

    // -- Border colors: one per edge --
    // Crimson / hot-pink palette (same as the base variant).
    //   #FC0F49  bright crimson red   -- color1
    //   #ff3566  hot pink            -- color2
    //   #a20f33  deep wine           -- color3
    vec3 colorTop    = vec3(0.988, 0.059, 0.286);  //   #FC0F49 crimson
    vec3 colorBottom = vec3(1.000, 0.208, 0.400);  //   #ff3566 hot pink
    vec3 colorLeft   = vec3(0.988, 0.059, 0.286);  //   #FC0F49 crimson
    vec3 colorRight  = vec3(0.635, 0.059, 0.200);  //   #a20f33 deep wine

    // Bright "core" intensity right at the edge. Slightly higher than
    // the base variant so the border punches through the moving halo.
    float colorIntensity = 1.0;

    // -- Edge geometry --
    // The core stays tight: colored light only in the outermost ~10%.
    // Anything past that is the (animated) halo.  outerHalo is wider
    // than the base variant so the more aggressive breathing has room
    // to play without crossing into the text region.
    float edgeThickness = 0.10;
    float edgeFalloff   = 3.0;
    float outerHalo     = 0.85;

    // -- Motion (faster / bigger than the base variant) --
    float breathSpeed   = 1.60;   // breathing pulse of the whole border
    float breathDepth   = 0.28;   // how much the border dims/brightens
    float rippleAmount  = 0.55;   // how much the core edge ripples
    float rippleSpeed   = 0.95;   // travel speed of the ripple
    float haloBreathSpeed = 0.90; // halo pulse, closer to core cycle
    float curtainSpeed  = 0.70;   // horizontal drift of the aurora curtain

    // ============================================================
    //  Sample the rendered terminal first -- we tint, never replace.
    // ============================================================
    vec2 uv = fragCoord / iResolution.xy;
    vec4 terminalColor = texture(iChannel0, uv);

    // Aspect-correct horizontal distances so vertical/horizontal
    // thickness look the same on widescreen terminals.
    vec2 res    = iResolution.xy;
    float aspect = res.x / res.y;

    // Distance to each edge (1 at edge, 0 in the interior).
    float dTop    = uv.y;
    float dBottom = 1.0 - uv.y;
    float dLeft   = uv.x;
    float dRight  = 1.0 - uv.x;

    // ============================================================
    //  Edge masks
    //  core: tight bright band right at the edge
    //  halo: wider, lower-intensity band that fades inward
    // ============================================================
    float coreTop    = 1.0 - smoothstep(0.0, edgeThickness,          dTop);
    float coreBottom = 1.0 - smoothstep(0.0, edgeThickness,          dBottom);
    float coreLeft   = 1.0 - smoothstep(0.0, edgeThickness * aspect, dLeft);
    float coreRight  = 1.0 - smoothstep(0.0, edgeThickness * aspect, dRight);

    coreTop    = pow(coreTop,    edgeFalloff);
    coreBottom = pow(coreBottom, edgeFalloff);
    coreLeft   = pow(coreLeft,   edgeFalloff);
    coreRight  = pow(coreRight,  edgeFalloff);

    float haloRange = edgeThickness * (1.0 + outerHalo);
    float haloTop    = 1.0 - smoothstep(0.0, haloRange,          dTop);
    float haloBottom = 1.0 - smoothstep(0.0, haloRange,          dBottom);
    float haloLeft   = 1.0 - smoothstep(0.0, haloRange * aspect, dLeft);
    float haloRight  = 1.0 - smoothstep(0.0, haloRange * aspect, dRight);

    haloTop    *= outerHalo;
    haloBottom *= outerHalo;
    haloLeft   *= outerHalo;
    haloRight  *= outerHalo;

    // ============================================================
    //  Per-edge phase offsets so the four borders don't move together.
    //  Each edge gets its own slow phase for breathing AND its own
    //  ripple direction / speed.
    // ============================================================
    float t = iTime;

    // Breathing -- per-edge phases so the pulse travels around the
    // screen rather than every edge dimming in unison.
    float phaseT = t * breathSpeed + 0.0;
    float phaseB = t * breathSpeed + 1.7;
    float phaseL = t * breathSpeed + 3.3;
    float phaseR = t * breathSpeed + 4.9;

    // Each edge pulses between (1 - depth) and 1 around a midpoint of
    // (1 - depth/2), so the border never fully fades.
    float bMid = 1.0 - breathDepth * 0.5;
    float breatheT = bMid + breathDepth * 0.5 * sin(phaseT);
    float breatheB = bMid + breathDepth * 0.5 * sin(phaseB);
    float breatheL = bMid + breathDepth * 0.5 * sin(phaseL);
    float breatheR = bMid + breathDepth * 0.5 * sin(phaseR);

    // Halo pulses with its own depth so the layered breathing is more
    // dramatic than the base variant.
    float hMid = 1.0 - breathDepth;
    float haloBreatheT = hMid + breathDepth * sin(t * haloBreathSpeed + 0.0);
    float haloBreatheB = hMid + breathDepth * sin(t * haloBreathSpeed + 1.1);
    float haloBreatheL = hMid + breathDepth * sin(t * haloBreathSpeed + 2.3);
    float haloBreatheR = hMid + breathDepth * sin(t * haloBreathSpeed + 3.7);

    // ============================================================
    //  Aspect-corrected sampling coordinates for the horizontal edges.
    //  On a widescreen terminal uv.x spans a larger physical distance
    //  than uv.y, so sampling noise with raw uv.x stretches the
    //  ripple wavelength horizontally.  Multiplying by `aspect`
    //  (iResolution.x / iResolution.y) compresses uv.x to the same
    //  scale as uv.y, so the top/bottom ripple spacing matches what
    //  you see on the left/right edges.
    // ============================================================
    float uH = uv.x * aspect;     // aspect-corrected horizontal coord
    float vH = uv.y;              // vertical coord already normalized

    // ============================================================
    //  Ripples -- two layers, different speeds, different scales, so
    //  the edges don't look like a single sine wave traveling along.
    // ============================================================
    float rs = rippleSpeed;

    // Core ripples: faster, smaller scale, larger amplitude.
    // Horizontal edges use uH (aspect-corrected), vertical edges use vH.
    float coreRipT = (edgeNoise(uH - t * rs * 0.21, t * 1.1) - 0.5)
                   + (edgeNoise(uH - t * rs * 0.07, t * 0.6) - 0.5) * 0.6;
    float coreRipB = (edgeNoise(uH + t * rs * 0.19, t * 1.3) - 0.5)
                   + (edgeNoise(uH + t * rs * 0.05, t * 0.7) - 0.5) * 0.6;
    float coreRipL = (edgeNoise(vH - t * rs * 0.17, t * 1.0) - 0.5)
                   + (edgeNoise(vH - t * rs * 0.09, t * 0.5) - 0.5) * 0.6;
    float coreRipR = (edgeNoise(vH + t * rs * 0.23, t * 1.2) - 0.5)
                   + (edgeNoise(vH + t * rs * 0.11, t * 0.8) - 0.5) * 0.6;

    // Apply ripple to cores, then breathe.
    float mTop    = (coreTop    + haloTop    * haloBreatheT) * (1.0 + rippleAmount * coreRipT) * breatheT;
    float mBottom = (coreBottom + haloBottom * haloBreatheB) * (1.0 + rippleAmount * coreRipB) * breatheB;
    float mLeft   = (coreLeft   + haloLeft   * haloBreatheL) * (1.0 + rippleAmount * coreRipL) * breatheL;
    float mRight  = (coreRight  + haloRight  * haloBreatheR) * (1.0 + rippleAmount * coreRipR) * breatheR;

    // Clamp to keep things in range; the breathing+ripple peaks can
    // otherwise exceed 1.0 at the corners where two edges meet.
    mTop    = clamp(mTop,    0.0, 1.25);
    mBottom = clamp(mBottom, 0.0, 1.25);
    mLeft   = clamp(mLeft,   0.0, 1.25);
    mRight  = clamp(mRight,  0.0, 1.25);

    // ============================================================
    //  Aurora curtain -- an fbm ribbon that flows ALONG each edge.
    //  Multiplies the halo so the curtain is visible but never crosses
    //  into the bright core or the interior.  The horizontal-axis
    //  sample is aspect-corrected (uH = uv.x * aspect) so the curtain
    //  wavelength looks the same on left/right as on top/bottom.
    // ============================================================
    vec2 curtainInputH = vec2(uH * 8.0 - t * curtainSpeed, vH * 8.0);
    vec2 curtainInputV = vec2(vH * 8.0, uH * 8.0 - t * curtainSpeed * 0.85);
    float curtainH    = fbm3(curtainInputH) * 1.2 - 0.2;
    float curtainV    = fbm3(curtainInputV + vec2(11.3, 7.7)) * 1.2 - 0.2;
    curtainH = clamp(curtainH, 0.0, 1.0);
    curtainV = clamp(curtainV, 0.0, 1.0);

    // Apply curtain only to the halo portion of each mask so the
    // bright core stays continuous.
    vec3 curtainGlow = vec3(0.0);
    curtainGlow += colorTop    * haloTop    * curtainH * haloBreatheT * 0.75;
    curtainGlow += colorBottom * haloBottom * curtainH * haloBreatheB * 0.75;
    curtainGlow += colorLeft   * haloLeft   * curtainV * haloBreatheL * 0.75;
    curtainGlow += colorRight  * haloRight  * curtainV * haloBreatheR * 0.75;

    // ============================================================
    //  Compose the colored edge glow from the masked cores.
    // ============================================================
    vec3 edgeGlow = vec3(0.0);
    edgeGlow += colorTop    * mTop;
    edgeGlow += colorBottom * mBottom;
    edgeGlow += colorLeft   * mLeft;
    edgeGlow += colorRight  * mRight;
    edgeGlow *= colorIntensity;

    // ============================================================
    //  Slow background flow so the dark interior isn't dead.
    //  Very low amplitude -- it's a "breathing of the dark", not a
    //  visible pattern.  Keeps the screen feeling alive without
    //  competing with glyphs.
    // ============================================================
    vec2 washInput = vec2(uH * 1.5 + t * 0.02, vH * 1.5 - t * 0.015);
    float wash = fbm3(washInput) - 0.5;
    vec3 background = bgColor + wash * bgNoiseAmount * 1.5;

    // Faint animated grain on top of the background.
    float grain = noise(fragCoord / bgNoiseScale + t * 0.07) - 0.5;
    background += grain * bgNoiseAmount;

    // ============================================================
    //  Composite: terminal color first, then background + glow +
    //  curtain on top.  Preserve terminalColor.a.
    // ============================================================
    vec3 finalRGB = terminalColor.rgb + background + edgeGlow + curtainGlow;

    fragColor = vec4(finalRGB, terminalColor.a);
}
