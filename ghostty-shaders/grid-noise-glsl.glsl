// Soft grid-of-orbs terminal background shader.
//
// Inspired by mnoise.glsl: tiled cells, rounded SDF shapes, multi-octave
// simplex noise driving a smooth color gradient, and -- crucially -- the
// shader color is *added* to iChannel0 (the terminal texture) instead of
// replacing it. That's what makes mnoise.glsl work on any color theme,
// and we do the same here.
//
// Differences from mnoise.glsl:
//   * No hard square tile grid. Instead a soft hex-like lattice of glowing
//     orbs whose radii breathe with noise, so it feels organic.
//   * Two color palettes selectable via a uniform-like constant so the
//     shader is friendly to both light and dark themes out of the box.
//   * Slight drift per cell so the field slowly flows rather than loops
//     in place.

vec3 mod289(vec3 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
vec4 mod289(vec4 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
vec4 permute(vec4 x) { return mod289(((x * 34.0) + 10.0) * x); }
vec4 taylorInvSqrt(vec4 r) { return 1.79284291400159 - 0.85373472095314 * r; }

float snoise(vec3 v) {
  const vec2 C = vec2(1.0 / 6.0, 1.0 / 3.0);
  const vec4 D = vec4(0.0, 0.5, 1.0, 2.0);

  vec3 i  = floor(v + dot(v, C.yyy));
  vec3 x0 = v - i + dot(i, C.xxx);

  vec3 g  = step(x0.yzx, x0.xyz);
  vec3 l  = 1.0 - g;
  vec3 i1 = min(g.xyz, l.zxy);
  vec3 i2 = max(g.xyz, l.zxy);

  vec3 x1 = x0 - i1 + C.xxx;
  vec3 x2 = x0 - i2 + C.yyy;
  vec3 x3 = x0 - D.yyy;

  i = mod289(i);
  vec4 p = permute(permute(permute(
              i.z + vec4(0.0, i1.z, i2.z, 1.0))
            + i.y + vec4(0.0, i1.y, i2.y, 1.0))
            + i.x + vec4(0.0, i1.x, i2.x, 1.0));

  float n_ = 0.142857142857;
  vec3 ns = n_ * D.wyz - D.xzx;

  vec4 j = p - 49.0 * floor(p * ns.z * ns.z);

  vec4 x_ = floor(j * ns.z);
  vec4 y_ = floor(j - 7.0 * x_);

  vec4 x = x_ * ns.x + ns.yyyy;
  vec4 y = y_ * ns.x + ns.yyyy;
  vec4 h = 1.0 - abs(x) - abs(y);

  vec4 b0 = vec4(x.xy, y.xy);
  vec4 b1 = vec4(x.zw, y.zw);

  vec4 s0 = floor(b0) * 2.0 + 1.0;
  vec4 s1 = floor(b1) * 2.0 + 1.0;
  vec4 sh = -step(h, vec4(0.0));

  vec4 a0 = b0.xzyw + s0.xzyw * sh.xxyy;
  vec4 a1 = b1.xzyw + s1.xzyw * sh.zzww;

  vec3 p0 = vec3(a0.xy, h.x);
  vec3 p1 = vec3(a0.zw, h.y);
  vec3 p2 = vec3(a1.xy, h.z);
  vec3 p3 = vec3(a1.zw, h.w);

  vec4 norm = taylorInvSqrt(vec4(dot(p0, p0), dot(p1, p1),
                                 dot(p2, p2), dot(p3, p3)));
  p0 *= norm.x; p1 *= norm.y; p2 *= norm.z; p3 *= norm.w;

  vec4 m = max(0.5 - vec4(dot(x0, x0), dot(x1, x1),
                           dot(x2, x2), dot(x3, x3)), 0.0);
  m = m * m;
  return 105.0 * dot(m * m, vec4(dot(p0, x0), dot(p1, x1),
                                  dot(p2, x2), dot(p3, x3)));
}

float hash21(vec2 p) {
  p = fract(p * vec2(123.34, 456.21));
  p += dot(p, p + 45.32);
  return fract(p.x * p.y);
}

// Soft circular orb SDF.
float sdCircle(vec2 p, float r) { return length(p) - r; }

// Hexagonal-ish lattice coords: each cell gets a center in [0,1]^2.
vec2 cellCenter(vec2 id) {
  // Offset alternate rows by half a cell for a brick/hex feel.
  float row = floor(id.y);
  float xOffset = mod(row, 2.0) * 0.5;
  return vec2(fract(id.x + xOffset), fract(id.y));
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
  vec2 uv = fragCoord / iResolution.xy;
  vec4 ghosttyCol = texture(iChannel0, uv);
  float ratio = iResolution.y / iResolution.x;
  float fw = max(fwidth(uv.x), fwidth(uv.y));

  // ---- Theme-agnostic palette ---------------------------------------
  // Pick dark-friendly or light-friendly palette by flipping the constant.
  // 0.0 -> dark themes, 1.0 -> light themes. The shader only TINTS
  // existing pixels (additive), so this is a soft preference, not a
  // hard replacement.
  const float theme = 0.0;

  // Two endpoint colors for the noise gradient. Cool indigo -> warm rose
  // works on both dark and light backgrounds.
  vec3 lo = mix(vec3(0.04, 0.05, 0.18), vec3(0.55, 0.55, 0.70), theme);
  vec3 mid = mix(vec3(0.30, 0.15, 0.45), vec3(0.80, 0.55, 0.65), theme);
  vec3 hi = mix(vec3(0.95, 0.40, 0.55), vec3(0.95, 0.75, 0.55), theme);

  // ---- Cell grid -----------------------------------------------------
  // Density in cells across the short axis.
  const float cellsX = 22.0;
  vec2 gridUV = vec2(uv.x, uv.y * ratio) * vec2(cellsX, cellsX);
  vec2 cellId = floor(gridUV);
  vec2 cellUV = fract(gridUV) - 0.5;

  // Per-cell drift: each orb wobbles on its own phase.
  float cellSeed = hash21(cellId);
  float drift = 0.06 * (cellSeed - 0.5);

  // Noise sampled at the cell, evolving in time.
  float t = iTime * 0.25;
  float n1 = snoise(vec3(cellId * 0.18, t + cellSeed));
  float n2 = snoise(vec3(cellId * 0.35 + 5.7, t * 1.3 + cellSeed * 2.1));
  float n  = 0.5 + 0.5 * (n1 + 0.5 * n2);   // [0,1]

  // Breathing orb radius, larger in the brightest cells.
  float radius = 0.18 + 0.22 * smoothstep(0.4, 1.0, n);
  float d = sdCircle(cellUV + vec2(drift * sin(t + cellSeed * 6.28),
                                    drift * cos(t * 0.7 + cellSeed * 6.28)),
                      radius);

  // Soft falloff to the edge of the orb -> AA-friendly "glow".
  float glow = smoothstep(0.04, -0.02, d);

  // ---- Color gradient -----------------------------------------------
  vec3 tint = mix(lo, mid, smoothstep(0.0, 0.55, n));
  tint      = mix(tint, hi, smoothstep(0.55, 1.0, n));

  // ---- Compose -------------------------------------------------------
  // Additive blend: only TINT the terminal, never overwrite it.
  // Multiplying by the glow keeps glyphs bright; the gradient flows
  // through the empty spaces between text.
  vec3 add = tint * glow * 0.18;

  // Subtle global noise wash so empty cells aren't perfectly flat.
  float wash = snoise(vec3(uv * 3.0, t * 0.5)) * 0.5 + 0.5;
  add += mix(lo, mid, wash) * 0.02;

  fragColor = vec4(ghosttyCol.rgb + add, ghosttyCol.a);
}
