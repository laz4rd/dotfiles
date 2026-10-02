// Aurora "Siri-style" border glow shader.
//
// Full-screen pass that lays a colored bloom along the four screen edges
// while keeping the interior dark so terminal glyphs stay readable.
// Inspired by the iOS Siri activation border bloom.
//
// Modeled after mnoise.glsl / grid-noise-glsl.glsl: we sample the
// rendered terminal from iChannel0, compute our glow color, and ADD the
// glow on top of the terminal color (preserving terminalColor.a). That
// compositing order is what makes Ghostty custom shaders show the
// effect on top of any theme instead of replacing the screen with a
// flat color.
//
// CONFIG block at the top of mainImage() collects every knob you are
// likely to want to tweak.

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

// Smooth unit-range noise used to ripple the edge inward.
float edgeNoise(float u, float t) {
    return noise(vec2(u * 6.0, t * 0.6));
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    // ============================================================
    //  CONFIG -- tweak these, everything visible responds to them
    // ============================================================

    // -- Base background (what shows through behind the glow) --
    vec3  bgColor          = vec3(0.0, 0.0, 0.0);   // inner background
    float bgNoiseAmount    = 0.012;                 // 0.0 = flat black
    float bgNoiseScale     = 8.0;                   // larger = finer grain

    // -- Border colors: one per edge --
    // Crimson / hot-pink palette.
    //   #FC0F49  bright crimson red   -- color1
    //   #ff3566  hot pink            -- color2
    //   #a20f33  deep wine           -- color3
    vec3 colorTop    = vec3(0.988, 0.059, 0.286);  //   #FC0F49 crimson
    vec3 colorBottom = vec3(1.000, 0.208, 0.400);  //   #ff3566 hot pink
    vec3 colorLeft   = vec3(0.988, 0.059, 0.286);  //   #FC0F49 crimson
    vec3 colorRight  = vec3(0.635, 0.059, 0.200);  //   #a20f33 deep wine
    // Bright "core" intensity right at the edge.
    float colorIntensity = 1.20;

    // -- Edge geometry --
    // How far each glowing border reaches inward, as a fraction of the
    // screen's short side. iOS 26 Siri hugs the edge -- the colored
    // light only lives in the outermost ~10% of the screen.
    float edgeThickness = 0.10;
    // Inner falloff exponent (>1.0 = sharper near the screen edge,
    // smoother deeper into the interior). 3.0 gives the steep,
    // tightly-hugging falloff of Siri's border.
    float edgeFalloff   = 3.0;
    // Width of the soft outer halo that bleeds past the screen edge.
    // 0 = no halo, 1.0 = halo extends one edgeThickness past the edge.
    float outerHalo     = 0.6;

    // -- Motion --
    float breathSpeed  = 0.55;  // breathing speed of the whole glow
    float rippleAmount = 0.20;  // how much each edge ripples inward
    float rippleSpeed  = 0.30;  // travel speed of the ripple

    // ============================================================
    //  Sample the rendered terminal first -- this is what we tint.
    // ============================================================
    vec2 uv = fragCoord / iResolution.xy;
    vec4 terminalColor = texture(iChannel0, uv);

    // ============================================================
    //  Edge masks
    //  Each mask is ~1 right at its edge, drops to 0 quickly as we move
    //  inward (the tight Siri falloff), and tapers smoothly into a soft
    //  outer halo for that "spilling off the bezel" feel.
    // ============================================================
    float dTop    = uv.y;
    float dBottom = 1.0 - uv.y;
    float dLeft   = uv.x;
    float dRight  = 1.0 - uv.x;

    // Aspect-correct horizontal edges so vertical/horizontal thickness
    // look the same on widescreen terminals.
    float aspect = iResolution.x / iResolution.y;

    // Inner-side falloff: 1 at the edge, dropping to 0 across the
    // edgeThickness region. smoothstep + pow gives a sharp-but-soft
    // inward curve that hugs the bezel.
    float coreTop    = 1.0 - smoothstep(0.0, edgeThickness,          dTop);
    float coreBottom = 1.0 - smoothstep(0.0, edgeThickness,          dBottom);
    float coreLeft   = 1.0 - smoothstep(0.0, edgeThickness * aspect, dLeft);
    float coreRight  = 1.0 - smoothstep(0.0, edgeThickness * aspect, dRight);

    coreTop    = pow(coreTop,    edgeFalloff);
    coreBottom = pow(coreBottom, edgeFalloff);
    coreLeft   = pow(coreLeft,   edgeFalloff);
    coreRight  = pow(coreRight,  edgeFalloff);

    // Outer halo: 0 at the edge, peaking slightly off-screen (we fake
    // it with a 1 - smoothstep on the inside so it never escapes the
    // framebuffer) and falling off inward. Lower weight than the core.
    float haloRange = edgeThickness * (1.0 + outerHalo);
    float haloTop    = 1.0 - smoothstep(0.0, haloRange,          dTop);
    float haloBottom = 1.0 - smoothstep(0.0, haloRange,          dBottom);
    float haloLeft   = 1.0 - smoothstep(0.0, haloRange * aspect, dLeft);
    float haloRight  = 1.0 - smoothstep(0.0, haloRange * aspect, dRight);

    haloTop    *= outerHalo;
    haloBottom *= outerHalo;
    haloLeft   *= outerHalo;
    haloRight  *= outerHalo;

    // Combined mask per edge.
    float mTop    = coreTop    + haloTop;
    float mBottom = coreBottom + haloBottom;
    float mLeft   = coreLeft   + haloLeft;
    float mRight  = coreRight  + haloRight;

    // ============================================================
    //  Ripples: nudge each edge inward/outward along its length using
    //  edge noise so the borders aren't perfectly straight.
    // ============================================================
    float t = iTime;
    mTop    *= 1.0 + rippleAmount * (edgeNoise(uv.x - t * rippleSpeed * 0.15, t) - 0.5);
    mBottom *= 1.0 + rippleAmount * (edgeNoise(uv.x + t * rippleSpeed * 0.21, t) - 0.5);
    mLeft   *= 1.0 + rippleAmount * (edgeNoise(uv.y - t * rippleSpeed * 0.13, t) - 0.5);
    mRight  *= 1.0 + rippleAmount * (edgeNoise(uv.y + t * rippleSpeed * 0.17, t) - 0.5);

    // Clamp to keep the math in a sane range and avoid white-out at the
    // corners where two masks meet.
    mTop    = clamp(mTop,    0.0, 1.2);
    mBottom = clamp(mBottom, 0.0, 1.2);
    mLeft   = clamp(mLeft,   0.0, 1.2);
    mRight  = clamp(mRight,  0.0, 1.2);

    // ============================================================
    //  Compose the colored edge glow.
    // ============================================================
    float breathe = 0.85 + 0.15 * sin(t * breathSpeed);

    vec3 edgeGlow = vec3(0.0);
    edgeGlow += colorTop    * mTop;
    edgeGlow += colorBottom * mBottom;
    edgeGlow += colorLeft   * mLeft;
    edgeGlow += colorRight  * mRight;
    edgeGlow *= colorIntensity * breathe;

    // ============================================================
    //  Background grain so the dark middle isn't dead-flat.
    // ============================================================
    float grain = noise(fragCoord / bgNoiseScale + t * 0.05) - 0.5;
    vec3 background = bgColor + grain * bgNoiseAmount;

    // ============================================================
    //  Composite: terminal color first, then glow + grain on top.
    //  This is the order the reference shaders use (see mnoise.glsl).
    //  We preserve terminalColor.a so Ghostty can composite us back
    //  over the framebuffer correctly.
    // ============================================================
    vec3 finalRGB = terminalColor.rgb + background + edgeGlow;

    fragColor = vec4(finalRGB, terminalColor.a);
}
