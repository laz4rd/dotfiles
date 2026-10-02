// Crimson "ocean" full-screen gradient shader.
//
// Inspired by the React component quoted in the task: a three-color
// gradient (crimson / hot-pink / deep-wine) that fills the whole
// terminal, domain-warped with FBM-style noise to feel liquid, with a
// slow vortex rotation, a diagonal blend line, contrast / saturation /
// gamma trims, and a static film grain on top.
//
// Composites the same way as mnoise.glsl: we SAMPLE the rendered
// terminal from iChannel0, ADD our gradient on top, and preserve
// terminalColor.a so Ghostty can blend us back over the framebuffer
// correctly. That keeps terminal glyphs readable through any color
// theme.

// ---------- Noise helpers ----------
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

// Fractal Brownian motion: 4 octaves of value noise. Returns roughly
// [0, 1] but biased -- we re-normalize at use sites.
float fbm(vec2 p) {
    float v = 0.0;
    float a = 0.5;
    for (int i = 0; i < 4; i++) {
        v += a * noise(p);
        p *= 2.02;
        a *= 0.5;
    }
    return v;
}

// Luminance used for saturation control.
float luma(vec3 c) {
    return dot(c, vec3(0.2126, 0.7152, 0.0722));
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    // ============================================================
    //  CONFIG -- all the React component props live here.
    // ============================================================

    // -- Palette --
    vec3 color1 = vec3(0.988, 0.059, 0.286); // #FC0F49 crimson
    vec3 color2 = vec3(1.000, 0.208, 0.400); // #ff3566 hot pink
    vec3 color3 = vec3(0.635, 0.059, 0.200); // #a20f33 deep wine

    // -- Animation --
    float timeSpeed  = 2.0;   // master time multiplier

    // -- Color balance --
    // -1.0 -> pull toward color1/color3, +1.0 -> pull toward color2.
    float colorBalance = -0.6;

    // -- Domain warp --
    float warpStrength   = 4.0;
    float warpFrequency  = 5.0;
    float warpSpeed      = 2.5;
    // warpAmplitude is in pixels; we scale by 1/res so the displacement
    // is resolution-independent. 50 / 1080 ~= 0.046 at 1080p.
    float warpAmplitude  = 50.0;
    float noiseScale     = 2.0;

    // -- Blend between the two halves of the gradient --
    // 0 radians = diagonal from bottom-left to top-right.
    float blendAngle     = 0.0;
    float blendSoftness  = 0.05;

    // -- Vortex rotation --
    // 500 looks huge but we scale by iTime so the rotation speed is
    // tiny -- the gradient slowly tumbles rather than spinning fast.
    float rotationAmount = 500.0;

    // -- Grain --
    float grainAmount    = 0.10;
    float grainScale     = 2.0;
    bool  grainAnimated  = false;

    // -- Color grading --
    float contrast       = 1.5;
    float gamma          = 1.0;
    float saturation     = 1.1;

    // -- Centering + zoom --
    float centerX        = 0.0;
    float centerY        = 0.0;
    float zoom           = 0.6;  // <1 zooms out (samples a larger area)

    // ============================================================
    //  Sample the rendered terminal first -- we tint, never replace.
    // ============================================================
    vec2 uv = fragCoord / iResolution.xy;
    vec4 terminalColor = texture(iChannel0, uv);

    // ============================================================
    //  Build the warped sample coordinate.
    // ============================================================
    vec2 p = uv - vec2(0.5 + centerX, 0.5 + centerY);

    // Apply zoom (smaller zoom = sample a larger region = zoom out).
    vec2 z = (zoom > 0.0001) ? (p / zoom) : p;

    // Slow vortex: rotate z by an angle that grows with iTime. The
    // rotationAmount / timeSpeed pair sets how many radians per second.
    float t = iTime * timeSpeed;
    float rot = t / max(rotationAmount, 1.0) * 2.0;
    float cr = cos(rot), sr = sin(rot);
    z = mat2(cr, -sr, sr, cr) * z;

    // Domain warp: shift z by fbm noise evaluated at a moving
    // coordinate.  warpAmplitude is in pixels so we scale by 1/res.
    vec2 warpInput = z * warpFrequency * noiseScale + t * warpSpeed * 0.1;
    vec2 warp = vec2(fbm(warpInput),
                     fbm(warpInput + vec2(31.7, 17.3))) - 0.5;
    vec2 warped = z + warp * (warpAmplitude / max(iResolution.y, 1.0)) * warpStrength;

    // ============================================================
    //  Build the diagonal gradient.
    //  blendAngle rotates a unit vector; the dot product with warped
    //  coords gives a 0..1 blend factor across the screen.
    // ============================================================
    vec2 dir = vec2(cos(blendAngle), sin(blendAngle));
    float blendRaw = dot(warped, dir) * 0.5 + 0.5;

    // Soft threshold around 0.5 using smoothstep + blendSoftness.
    // blendSoftness == 0.05 means the transition is ~5% wide.
    float lo = 0.5 - blendSoftness;
    float hi = 0.5 + blendSoftness;
    float blend = smoothstep(lo, hi, blendRaw);

    // Apply colorBalance: shift blend toward 0 or 1 to bias which
    // color dominates.  We scale & clamp the balance so it stays sane.
    blend = clamp(blend + colorBalance * 0.5, 0.0, 1.0);

    // Three-stop gradient: bottom half -> color1 -> color2 -> color3.
    vec3 grad = mix(color1, color2, smoothstep(0.0, 0.5, blend));
    grad     = mix(grad,  color3, smoothstep(0.5, 1.0, blend));

    // ============================================================
    //  Color grading: contrast -> gamma -> saturation.
    // ============================================================
    grad = (grad - 0.5) * contrast + 0.5;
    grad = clamp(grad, 0.0, 1.0);
    grad = pow(grad, vec3(gamma));
    float L = luma(grad);
    grad = mix(vec3(L), grad, saturation);

    // ============================================================
    //  Static (or animated) film grain.
    // ============================================================
    vec2 grainCoord = fragCoord / grainScale;
    float grainSeed = grainAnimated ? (iTime * 17.13) : 0.0;
    float g = hash21(floor(grainCoord) + grainSeed) - 0.5;
    vec3 grain = vec3(g) * grainAmount;

    // ============================================================
    //  Composite: terminal color first, then the gradient ocean + grain
    //  on top.  Preserves terminalColor.a, matching the reference
    //  Ghostty shaders (see mnoise.glsl).
    // ============================================================
    vec3 finalRGB = terminalColor.rgb + grad + grain;

    fragColor = vec4(finalRGB, terminalColor.a);
}
