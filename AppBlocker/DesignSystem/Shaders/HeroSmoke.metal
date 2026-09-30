//
//  HeroSmoke.metal
//  AppBlocker
//
//  Procedural smoke/fog shader that drifts behind the hook screen (ARISE-style hero) (2026-07-29).
//  No video asset, loops forever, lightweight: a few hundred μs of GPU time per frame.
//  Value-noise FBM (4 octaves) with domain warping, so the smoke "swirls and drifts slowly".
//  The color is the brand off-white, and brightness is capped at about 0.2 so the text and CTA stand out
//  (the dark gradient overlay is layered on the SwiftUI side).
//
//  SwiftUI side: Rectangle().colorEffect(ShaderLibrary.heroSmoke(.float2(size), .float(time)))
//

#include <metal_stdlib>
using namespace metal;

static float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

static float valueNoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    float a = hash21(i);
    float b = hash21(i + float2(1.0, 0.0));
    float c = hash21(i + float2(0.0, 1.0));
    float d = hash21(i + float2(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

static float fbm(float2 p) {
    float v = 0.0;
    float amp = 0.5;
    for (int i = 0; i < 4; i++) {
        v += amp * valueNoise(p);
        p *= 2.03;
        amp *= 0.5;
    }
    return v;
}

[[ stitchable ]] half4 heroSmoke(float2 position, half4 currentColor, float2 size, float time) {
    // UV that keeps the aspect ratio (based on the short side). Slow rise plus sideways drift
    // (2026-07-29 feedback round 2: speed 0.035→0.065, fast enough to see that it "is moving")
    float2 uv = position / max(size.x, 1.0) * 2.4;
    float t = time * 0.065;

    // Domain warp: distort the coordinates with a first FBM, then sample a second one → swirling smoke texture
    float2 drift1 = float2(t * 0.6, -t);          // updraft
    float2 drift2 = float2(-t * 0.4, -t * 0.7);
    float q = fbm(uv + drift1);
    float n = fbm(uv + 1.9 * float2(q, q * 0.8) + drift2);

    // Shaping: do not lift the midtones too much (do not saturate to pure white)
    // (2026-07-29 feedback round 2: density 0.22→0.30)
    float intensity = smoothstep(0.35, 0.95, n);
    intensity = intensity * intensity * 0.30;

    // Put the brand off-white (around #F2EFE7) on the black background
    half3 smoke = half3(0.95h, 0.93h, 0.90h) * half(intensity);

    // Against banding (2026-07-31 real-device feedback: "there are a lot of lines in it"):
    // a gentle gradient in the dark areas turns into contour-like stripes when it is quantized to 8 bits.
    // Adding noise smaller than 1 LSB (±0.5/255) at the end scatters the step edges = dithering.
    // It does not look noisy, only the stripes disappear. It depends on position, so it is stable when still
    float dither = fract(sin(dot(position, float2(12.9898, 78.233))) * 43758.5453) - 0.5;
    smoke += half3(half(dither / 255.0));

    return half4(smoke, 1.0h);
}
