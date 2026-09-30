#ifndef MINECRAFT_VV_SUN_GLSL
#define MINECRAFT_VV_SUN_GLSL

// The sun state derived from Globals.GameTime, shared by the core shaders and the
// post effect chain.
//
// Globals is one of the uniform blocks the game binds to every render pass,
// including post effect passes (RenderSystem.bindDefaultUniforms), so a post
// shader can #include this and know exactly where the sun is. That matters for
// the volumetric passes: without it they have to guess where the light is by
// hunting for the brightest pixel, which drifts off a torch or smears across the
// sky. See RenderSystem.bindDefaultUniforms and PostPass.addToPass in 26.3.
//
// What is deliberately absent is the camera basis. Globals carries
// CameraBlockPos and CameraOffset but no orientation or field of view, and the
// Projection block a post pass sees is the screen quad's orthographic matrix
// rather than the camera's. So the sun's world direction is known exactly, but
// projecting it to a screen position is not. The volumetric search therefore
// still locates the light on screen, and uses the direction below to decide
// whether there should be light and what colour it is.

#include <minecraft:globals.glsl>

const float VV_PI = 3.14159265358979;
const float VV_INV_PI = 0.31830988618379;

// The game draws the sun by rotating (0,1,0) about +X by the sun angle and then
// about +Y by -90 degrees. Worked out, that is a circle in the XY plane:
// (1,0,0) at dawn on the east, (0,1,0) at noon, (-1,0,0) at dusk. GameTime is
// (dayTime % 24000) / 24000, so the angle is one turn of it. The moon rides the
// same circle half a turn behind.
vec3 vv_sun_direction() {
    float a = GameTime * 2.0 * VV_PI;
    return vec3(cos(a), sin(a), 0.0);
}

vec3 vv_moon_direction() {
    return -vv_sun_direction();
}

// How high the sun sits: 1 at noon, 0 at the horizon, negative at night. Every
// colour below is driven off this, which is what keeps the whole pack moving
// together through the day instead of each effect guessing on its own.
float vv_sun_height() {
    return vv_sun_direction().y;
}

// Sun colour, warm and dim while it is low, near white at noon. Kept around 1.0
// at full strength because the scene target is RGBA8: anything above 1 is
// clipped on the way into main, so the post chain blooms off the top of the
// range rather than off a real HDR buffer.
vec3 vv_sun_radiance() {
    float h = vv_sun_height();
    vec3 warm = vec3(1.00, 0.42, 0.16);
    vec3 noon = vec3(1.00, 0.95, 0.88);
    float strength = smoothstep(-0.10, 0.22, h);
    return mix(warm, noon, smoothstep(0.05, 0.55, h)) * strength * 1.15;
}

vec3 vv_moon_radiance() {
    float up = smoothstep(0.02, 0.30, -vv_sun_height());
    return vec3(0.42, 0.50, 0.72) * up * 0.30;
}

// Which of the two lights is currently the one worth drawing shafts from. The
// sun is the key light whenever it is above the horizon and the moon the rest of
// the time, so this is a plain sign test on the sun's height. The moon is far
// dimmer, so callers scale by vv_key_radiance rather than assuming the returned
// light is as strong as daylight.
bool vv_sun_is_up() {
    return vv_sun_height() > 0.0;
}

float vv_key_radiance() {
    return vv_sun_is_up() ? vv_sun_radiance().g : vv_moon_radiance().g;
}

vec3 vv_key_radiance_color() {
    return vv_sun_is_up() ? vv_sun_radiance() : vv_moon_radiance();
}

// Normalised chroma of the key light, so a pass can ask whether a pixel's colour
// is plausibly the sun rather than merely bright. Luminance alone cannot tell a
// sun disc from a lit torch or a bright red block.
vec3 vv_key_chroma() {
    vec3 c = vv_key_radiance_color();
    return c / max(max(c.r, max(c.g, c.b)), 1e-4);
}

#endif