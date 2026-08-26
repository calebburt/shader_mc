#version 330
#extension GL_ARB_separate_shader_objects : require

#include <minecraft:fog.glsl>
#include <minecraft:globals.glsl>
#include <minecraft:texture_sampling.glsl>
#include <minecraft:oit.glsl>
#include <minecraft:terrainglobals.glsl>
#ifndef MULTIDRAW_TERRAIN
    #include <minecraft:chunksection.glsl>
#endif

uniform sampler2D Sampler0;

layout(location = 0) in float sphericalVertexDistance;
layout(location = 1) in float cylindricalVertexDistance;
layout(location = 2) in vec4 vertexColor;
layout(location = 3) in vec2 texCoord0;
layout(location = 4) in float chunkVisibility;
layout(location = 5) in vec3 cameraRelativePos;

#ifndef OIT_ALPHA_ONLY
layout(location = 0) out vec4 fragColor;
#endif

float value(vec3 c) {
    return max(max(c.r, max(c.g, c.b)), 1e-5);
}

vec3 chroma(vec3 c) {
    return c / value(c);
}

// Internal mutable state
float rngState = 0.0;

// Initialize RNG state once per shader invocation
void initRNG(float seed) {
    rngState = seed;
}

// Hash function
float hash(float x) {
    return fract(sin(x) * 43758.5453123);
}

// Combine all inputs into one seed
float makeSeed() {
    float s = 0.0;

    // Mix floats
    s += sphericalVertexDistance * 1.2345;
    s += cylindricalVertexDistance * 5.6789;
    s += chunkVisibility * 9.1011;

    // Mix vec2
    s += dot(texCoord0, vec2(12.9898, 78.233));

    // Mix vec3
    s += dot(cameraRelativePos, vec3(45.123, 12.345, 98.765));

    // Mix vec4
    s += dot(vertexColor, vec4(3.14159, 2.71828, 1.61803, 0.57721));

    return hash(s);
}

// Random float in [0,1)
float rand() {
    rngState = hash(rngState + 1.0);
    return rngState;
}

// Deterministically perturb a normal using a color.
vec3 perturbNormal(vec3 normal, vec3 color) {
    // Map color from [0,1] to [-1,1] so it acts like a direction vector
    vec3 influence = normalize(color * 2.0 - 1.0);

    // Strength of perturbation based on color intensity
    float strength = length(color) * 0.5;  // tweakable

    // Combine original normal with influence
    vec3 perturbed = normalize(normal + influence * strength);

    return perturbed;
}

// Vanilla's terrain texture sample: RGSS when supersampling is on, nearest
// otherwise, tinted by the vertex colour. Not wired into the output -- swap it
// into fragColor when you want the albedo back.
vec4 sampleTexture() {
    vec2 pixelSize = 1.0f / TextureSize;
    vec4 texel = UseRgss == 1
        ? sampleRGSS(Sampler0, texCoord0, pixelSize)
        : sampleNearest(Sampler0, texCoord0, pixelSize);
    return texel * vec4(chroma(vertexColor.rgb), vertexColor.a);
}

// The terrain vertex format has no normal attribute, so reconstruct the flat
// geometric normal from the screen-space derivatives of the camera-relative
// world position, then orient it back towards the camera (which sits at the
// origin of that space).
vec3 geometricNormal(vec3 cameraRelative) {
    vec3 normal = normalize(cross(dFdx(cameraRelative), dFdy(cameraRelative)));
    return dot(normal, cameraRelative) > 0.0 ? -normal : normal;
}

vec3 getLighting() {
    const float shininess = 0.5;

    vec4 texColor = sampleTexture();

    vec3 normal = geometricNormal(cameraRelativePos);
    normal = normalize(mix(normal, perturbNormal(normal, texColor.rgb), 0.5));

    vec3 N = normalize(normal);
    vec3 V = normalize(-cameraRelativePos);   // view direction
    vec3 L = normalize(vec3(1.0, 1.0, 1.0));  // directional light
    vec3 R = reflect(-L, N);                  // reflection vector

    // Ambient term
    float ambient = 0.2;

    // Diffuse term
    float diff = max(dot(N, L), 0.0);
    float diffuse = 0.5 * diff;

    // Specular term
    float spec = pow(max(dot(R, V), 0.0), shininess);
    float specular = 0.25 * spec;

    // Final color
    float lighting = ambient + diffuse;

    vec3 litColor = lighting * texColor.rgb + vec3(specular);

    float lightmap = value(vertexColor.rgb);

    litColor = clamp(mix(lightmap * texColor.rgb + specular * lightmap, litColor, lightmap), 0.0, 1.0);

    return litColor;
}

void doFog(inout vec3 color) {
    const float density = 0.01; // base extinction coefficient

    // distances
    float dist = sphericalVertexDistance;

    // resolve environment and render ranges
    float envStart = FogEnvironmentalStart;
    float envEnd = FogEnvironmentalEnd;
    float renderStart = FogRenderDistanceStart;
    float renderEnd = FogRenderDistanceEnd;

    // overall fog influence in [0,1]
    float fogValue = total_fog_value(sphericalVertexDistance, cylindricalVertexDistance, envStart, envEnd, renderStart, renderEnd);

    // compute fogStart/fogEnd influenced by the combined fogValue
    float fogStart = mix(renderStart, envStart, fogValue);
    float fogEnd = mix(renderEnd, envEnd, fogValue);

    float rangeLen = max(0.0001, fogEnd - fogStart);
    float rangeFactor = clamp((dist - fogStart) / rangeLen, 0.0, 1.0);

    // height-based falloff reduces density above the camera
    float height = cameraRelativePos.y;
    float heightFalloff = 0.02;

    float localDensity = density * exp(-heightFalloff * max(height, 0.0));

    float tau = localDensity * dist * rangeFactor;
    float transmittance = exp(-tau);

    vec3 inscatter = (1.0 - transmittance) * FogColor.rgb;

    color = inscatter + color * transmittance;
}

void main() {
    initRNG(makeSeed());

    // Derivatives must be evaluated before any discard so that neighbouring
    // fragments in the same quad still agree on them.
    vec3 normal = geometricNormal(cameraRelativePos);

    vec4 color = (UseRgss == 1 ? sampleRGSS(Sampler0, texCoord0, 1.0f / TextureSize) : sampleNearest(Sampler0, texCoord0, 1.0f / TextureSize)) * vertexColor;
    #ifdef ALPHA_CUTOUT
    if (color.a < ALPHA_CUTOUT) {
        discard;
    }
    #endif

    #ifdef OIT_ALPHA_ONLY
    executeAlphaOnlyPhase(gl_FragCoord.z, color.a);
    #else

    vec4 texColor = sampleTexture();

    vec3 litColor = getLighting();

    doFog(litColor);

    float lightmap = value(vertexColor.rgb);

    vec3 baseScene = clamp(mix(vec3(lightmap * texColor.rgb), litColor, lightmap), 0.0, 1.0);

    #ifdef OIT
    fragColor = vec4(baseScene, vertexColor.a);
    #else
    // Opaque terrain tags itself in main's alpha with 0, so the ssr post pass can
    // tell it apart from translucent surfaces. There is no translucent-only
    // target to sample in this version -- OIT resolves translucency into main
    // before any post pass runs -- and this alpha channel is read by nothing
    // else. Translucent terrain goes through OIT, where fragColor's alpha is
    // coverage and must not be touched, and reaches main via the composite with
    // a high alpha instead. Drop the #ifdef to undo.
    fragColor = vec4(baseScene, 0.0);
    #endif
    #endif
}
