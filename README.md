# vibrant-java

A Minecraft Java Edition **resource pack** that brings a Vibrant Visuals style
look to 26.3: custom terrain and entity lighting, atmospheric sky, screen space
reflections, volumetric light, bloom, depth of field, and a full colour grade.

Everything is shader code. The pack ships no assets, no data pack, and does not
touch world generation or gameplay.

## Requirements

| | |
|---|---|
| Minecraft | **26.3** exactly |
| Resource pack format | `97.1` |
| Loader | Works with vanilla. Fabric/Quilt/NeoForge are not required. |

`pack.mcmeta` pins the format to `97.1` rather than an open range. The pack
replaces core shaders that `#include` Mojang's own shader library, so a version
bump can change those includes without warning. When you move to a new version,
update `min_format`/`max_format` in `pack.mcmeta`, extract that version's shader
tree, and re-run the validator.

## Install

### Linux, macOS, or WSL

```sh
./deploy_shader_mc.sh
```

It installs into `~/.minecraft/resourcepacks/vibrant-java`, or into a Windows
Minecraft directory when run under WSL. To target a different launcher or
instance, set `MINECRAFT_DIR`:

```sh
MINECRAFT_DIR=~/prism/instances/default/.minecraft ./deploy_shader_mc.sh
```

### Windows

```bat
deploy.bat
```

Or set `MINECRAFT_DIR` first. Both scripts copy only `pack.mcmeta` and `assets/`,
so the validator never ends up inside an installed pack.

Then in game: **Options → Video Settings → Shader Packs**, select
**vibrant-java**. Close and reopen the world to be certain the post effect chain
is rebuilt.

## What it does

### Core shaders

| File | Purpose |
|---|---|
| `shaders/core/terrain.vsh/.fsh` | World lighting with sun and moon direction from `GameTime`, GGX specular, hemispherical ambient, and derivative based bump relief. Terrain has no normal attribute, so the normal is reconstructed. |
| `shaders/core/entity.vsh/.fsh` | Entities lit in world space in the fragment stage, using the real `Normal` attribute. |
| `shaders/core/sky.vsh/.fsh` | Sky dome with an atmospheric gradient and sun disc. |
| `shaders/core/clouds.vsh/.fsh` | Volumetric looking cloud layer lit by the sun. |
| `shaders/include/vv_sun.glsl` | Sun and moon direction, height and colour, from `Globals.GameTime`. Shared by the core shaders and the post chain. |
| `shaders/include/vv_lighting.glsl` | BRDF and ambient built on the above, for the world passes. |

### Post effect

`assets/minecraft/post_effect/end_of_frame.json` is a 25 pass chain. The file
name matters: `end_of_frame` is an always on slot the game requests every frame,
so overriding it in a resource pack is what makes the effect automatic. No
`/posteffect` command or datapack is needed.

```
 0-3   screen space reflections, roughness blurred, composited
 4-10  volumetric light: mask, shadow blur, sun disc, rays, fog
11-20  four level bloom pyramid
21-23  depth of field
   24  colour grade → minecraft:main
```

Only the last pass writes to `minecraft:main`. Every pass that samples the depth
buffer runs before it, because once a pass renders into main it owns main's
depth attachment and the depth data is gone.

### Sun direction in the post chain

The core shaders read the sun from `Globals.GameTime`, and the post chain does
the same. `Globals` is one of the blocks `RenderSystem.bindDefaultUniforms`
binds to every pass, post passes included, and `GameRenderer` updates it before
post effects run. So `vv_sun.glsl` works in both places and the whole pack agrees
on where the light is and what colour it is.

What the post chain cannot get is the camera basis. `Globals` carries the camera
position but not its orientation, and the `Projection` a post pass sees is the
screen quad's orthographic matrix, not the camera's. The sun's world direction is
therefore exact, but its screen position is not computable, so the volumetric
pass still locates the light by searching the mask. The direction does two jobs
that used to be guesswork:

- The mask is colour-keyed to the key light's chroma, so a bright torch or wall
  cannot seed a shaft, and the threshold scales with the light's radiance, so the
  sun still registers at dawn when it is dim.
- The shaft strength is gated on the real sun height (and the moon's, at night),
  so shafts cannot linger in frame after the sun has set, and the fog takes the
  light's colour, so it warms at dawn and goes cold at night.

The light's screen position comes from the brightness-weighted centroid of the
mask, weighted by the square of each sample's score and read from the raw mask
for the peak and the blurred mask for the position. The square weighting is what
keeps a second bright object from dragging the shafts off the sun.

## Tuning

Nearly every effect is driven by uniforms in `end_of_frame.json`. The shader
files are only needed for new effects, not for adjusting existing ones.

Common knobs, all under the pass that uses them:

- `SsrConfig.Strength` / `Reflectance` — reflection intensity. `TanHalfFov` sets
  the projection the ray march assumes; `DebugView` shows the raw buffer.
- `SsrCompositeConfig.MaskLevel` / `RoughStrength` — what counts as a surface to
  reflect off, and how much roughness suppresses it.
- `VolMaskConfig.SkyThreshold` — how bright a sky pixel must be, as a fraction of
  the key light's radiance, to count as the light source. Scaling by radiance is
  what keeps the sun findable at dawn instead of only at noon.
- `VolSunConfig.SunGain` — gain on the found light's peak before the elevation
  gate, mostly useful below `1.0` to calm the shafts.
- `VolRaysConfig.Density` / `Decay` / `Exposure` — how far each pixel marches
  toward the sun as a fraction of the distance, the per-step falloff that shapes
  the shaft, and the final gain.
- `VolConfig.ShaftIntensity` / `FogIntensity` — how much the shafts and the
  distance fog contribute to the final image.
- `BloomExtractConfig.Threshold` / `Knee` — raise the threshold to shrink the
  bloom to highlights only; `BloomConfig.Intensity` sets how much it adds.
- `DofConfig.AutoFocus` / `FocusDistance` / `Aperture` / `MaxBlur` — depth of
  field strength. `HandCutoff` keeps the held item from blurring.
- `ColorGradeConfig.Exposure`, `WhitePoint`, `Contrast`, `Saturation`,
  `Temperature`, `Tint`, `ShadowTint`, `HighlightTint`, `GradeStrength` — the
  final look.

### High dynamic range

`minecraft:main` and every post-chain target are `GpuFormat.RGBA8_UNORM`: the game
hardcodes that format in `MainTarget` and in `PostChain.addToFrame`, and no
resource-pack field selects another. An 8-bit UNORM attachment clamps at `1.0` on
store, so the chain cannot simply work in scene-linear and expect a highlight to
reach the final tone map intact.

To get headroom anyway, the passes that add light scale the scene down by
`1 / VV_HDR_SCALE` before writing and back up after reading (`include/vv_hdr.glsl`).
A single fixed scale is used rather than a per-pixel shared exponent (Radiance
RGBE) because a fixed scale commutes with the bilinear sampling and box blurs the
bloom pyramid and depth of field rely on; a shared exponent does not. The only
tone map is the final `colorgrade` pass, which decodes and rolls the excess off.

`VV_HDR_SCALE` (currently `4.0`) is the headroom/banding dial: higher reaches
further past white, but leaves the `0..1` range fewer codes, which is why the
encoder dithers. This widens the range the *post chain* can carry; it cannot
recover what the world render already clipped into `main`, because most core
shaders are vanilla and a pack cannot switch the whole world render to float.

## Validation

```sh
python3 validate.py
```

The pack is developed against a headless check rather than a running game. It
does two independent things:

1. **Compiles** every core and post shader with `glslang`, resolving
   `#include <minecraft:...>` against the pack's `include/` directory first and
   the game's own tree second. It injects the pipeline defines the game adds at
   load time (`ALPHA_CUTOUT`, `OIT`, `MULTIDRAW_TERRAIN`, and the OIT constants),
   covers each pipeline variant the game builds, and links vertex against
   fragment so mismatched varyings are caught.
2. **Checks the JSON**, mirroring the 26.3 `PostChainConfig` codecs: required
   fields, unique sampler names per pass, input form exclusivity, uniform block
   and member names against the shader source, uniform types and value arity,
   declared versus used targets, and the depth before main ordering rule. It
   also applies `pack.mcmeta`'s format rules, including whether the declared
   range actually contains the target version.

The compile half needs `glslang` on `PATH` (or `$GLSLANG`) and the game's
shader tree, which you can extract from a client jar:

```sh
unzip -o ~/.minecraft/versions/26.3/26.3.jar 'assets/minecraft/shaders/*' -d vanilla
export VANILLA_SHADERS="$PWD/vanilla/assets/minecraft/shaders"
```

Without both, the script says so and still runs the JSON checks.

## Known limitations

- **Not yet run in game.** Every shader compiles and the chain is structurally
  sound against the decompiled 26.3 code, but visual quality, performance, and
  runtime framegraph behaviour are unverified. Expect to want tuning.
- **The volumetric defaults are new and untuned.** The shaft and fog uniforms
  were re-derived for the sun-aware formulation and chosen so the maths lands in
  range, not against a screenshot. `VolRaysConfig.Exposure` and
  `VolConfig.ShaftIntensity` are the two to reach for first.
- **The HDR encoding trades precision for range and is untested.** `VV_HDR_SCALE`
  at `4.0` leaves the visible `0..1` range in the bottom quarter of the buffer
  and dithers the rest; that is a deliberate headroom-versus-banding choice. It
  also only widens the post chain, so world highlights that the core shaders
  clipped into `main` stay clipped. Watch for banding on skies and drop
  `VV_HDR_SCALE` if it shows.
- **Performance is untested.** Twenty five full screen passes with a depth read,
  a four level bloom pyramid, and a 40x40 mask search walked twice per frame is a
  lot of bandwidth. The chain has no quality tiers; if it is too slow, dropping
  the bloom pyramid from four levels to two, removing the two `ssr` blur passes,
  and lowering `GRID` in `vol_sun.fsh` are the first things to try.
- **The volumetric fog falls back if the `Fog` block is unbound.** It reads the
  world's real fog start, end and colour, but if that block is not bound for the
  pass every field reads as zero and would fog the frame to black, so it detects
  that and uses fixed defaults instead.
- **The GUI is not graded.** Post effects run before the HUD is drawn, so the
  grade and DOF apply to the world only. That is intentional.
