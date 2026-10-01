#ifndef MINECRAFT_VV_HDR_GLSL
#define MINECRAFT_VV_HDR_GLSL

// The world render reaches the post chain through minecraft:main, which
// MainTarget allocates as GpuFormat.RGBA8_UNORM, and every post-chain target is
// the same format (PostChain.addToFrame hardcodes RGBA8_UNORM). An 8-bit UNORM
// attachment clamps at 1.0 on store, so a pass cannot keep working in scene
// linear and expect a highlight above 1.0 to survive to the tone map.
//
// This is the "HDR in an LDR buffer" trick: scale the scene down by
// 1/VV_HDR_SCALE before storing and back up after reading, so linear values up to
// VV_HDR_SCALE fit in eight bits. A single fixed scale is used rather than a
// per-pixel shared exponent (Radiance RGBE) on purpose: a fixed scale commutes
// with the bilinear sampling and box blurs that the bloom pyramid and depth of
// field run, so those filters keep working untouched. A shared exponent does
// not, and would need every filter tap decoded by hand.
//
// The cost is precision: [0, 1] now occupies the bottom 1/VV_HDR_SCALE of the
// buffer. VV_HDR_SCALE is the headroom/banding dial -- raise it for more
// highlight reach, lower it if flat gradients start to band. The dither below
// turns whatever banding is left into a static grain, which blurs away far more
// gracefully than hard steps.
//
// This only widens the range the *post chain* can carry. The core shaders still
// write through minecraft:main, so what they clipped is already gone; see the
// README for why that needs a fork rather than a pack.
const float VV_HDR_SCALE = 4.0;

vec3 vv_hdr_decode(vec3 encoded) {
    return encoded * VV_HDR_SCALE;
}

vec3 vv_hdr_encode(vec3 linearColor) {
    vec3 scaled = linearColor / VV_HDR_SCALE;

    // One LSB of the stored buffer, in encoded units. Interleaved gradient noise
    // is a cheap, well-distributed per-pixel offset; it is a function of the
    // pixel only, so it does not sparkle on a still frame.
    float lsb = 1.0 / 255.0;
    float n = fract(52.9829189 * fract(dot(gl_FragCoord.xy, vec2(0.06711056, 0.00583715))));
    scaled += (n - 0.5) * lsb;

    return clamp(scaled, 0.0, 1.0);
}

#endif
