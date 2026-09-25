//
//  HeroSmoke.metal
//  AppBlocker
//
//  フック画面 (ARISE型ヒーロー) の背景に漂う煙/霧の手続き生成シェーダー (2026-07-29)。
//  動画アセット不要・無限ループ・GPU数百μs/フレームの軽量実装。
//  値ノイズのFBM (4オクターブ) をドメインワープして「渦を巻いてゆっくり流れる」煙にする。
//  色はブランドのオフホワイト、輝度は最大 ~0.2 に抑えて文字とCTAを立たせる
//  (暗幕グラデーションは SwiftUI 側で重ねる)。
//
//  SwiftUI 側: Rectangle().colorEffect(ShaderLibrary.heroSmoke(.float2(size), .float(time)))
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
    // 縦横比を保った UV (短辺基準)。ゆっくり上昇+横流れ
    // (2026-07-29 FB2回目: 速度 0.035→0.065 で「動いてる」が分かる速さに)
    float2 uv = position / max(size.x, 1.0) * 2.4;
    float t = time * 0.065;

    // ドメインワープ: 1段目のFBMで座標を歪ませてから2段目を引く → 渦を巻く煙の質感
    float2 drift1 = float2(t * 0.6, -t);          // 上昇気流
    float2 drift2 = float2(-t * 0.4, -t * 0.7);
    float q = fbm(uv + drift1);
    float n = fbm(uv + 1.9 * float2(q, q * 0.8) + drift2);

    // シェーピング: 中間値を持ち上げすぎない (真っ白に飽和させない)
    // (2026-07-29 FB2回目: 濃さ 0.22→0.30)
    float intensity = smoothstep(0.35, 0.95, n);
    intensity = intensity * intensity * 0.30;

    // ブランドのオフホワイト (#F2EFE7 系) を黒地に乗せる
    half3 smoke = half3(0.95h, 0.93h, 0.90h) * half(intensity);

    // バンディング対策 (2026-07-31 実機FB「すごい線入っちゃってる」):
    // 暗部の緩やかなグラデーションは 8bit へ量子化される時に等高線状の縞になる。
    // 1LSB 未満 (±0.5/255) のノイズを最後に足して段差の境界を散らす = ディザリング。
    // 見た目のノイズ感は出ず、縞だけが消える。position 依存なので静止時も安定
    float dither = fract(sin(dot(position, float2(12.9898, 78.233))) * 43758.5453) - 0.5;
    smoke += half3(half(dither / 255.0));

    return half4(smoke, 1.0h);
}
