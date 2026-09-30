#!/usr/bin/env python3
"""Validate the pack: compile every shader, and check the post effect chain.

Minecraft's shader preprocessor resolves `#include <minecraft:name>` against
shaders/include/, and injects pipeline defines that never appear in the source
(ALPHA_CUTOUT, OIT, MULTIDRAW_TERRAIN and friends). This does both so the shaders
can be compiled outside the game, then checks the post effect chain's wiring,
which nothing else here would catch.

Needs glslang on PATH (or $GLSLANG) and an extracted 26.3 client jar's shader tree
(or $VANILLA_SHADERS). Both are only needed for the compile half; the chain checks
run either way. To produce the tree:

    unzip -o client.jar 'assets/minecraft/shaders/*' -d vanilla
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.abspath(__file__))
SHADERS = os.path.join(ROOT, "assets/minecraft/shaders")
POST_EFFECTS = os.path.join(ROOT, "assets/minecraft/post_effect")


def find_vanilla():
    """Locate the game's own shader tree, which supplies the includes we use."""
    candidates = [
        os.environ.get("VANILLA_SHADERS"),
        "/tmp/opencode/vanilla/assets/minecraft/shaders",
        os.path.join(ROOT, "vanilla", "assets", "minecraft", "shaders"),
    ]
    for c in candidates:
        if c and os.path.isdir(os.path.join(c, "include")):
            return c
    return None


def find_glslang():
    candidates = [os.environ.get("GLSLANG"), shutil.which("glslangValidator"),
                  shutil.which("glslang"), "/tmp/opencode/glslang/usr/bin/glslang"]
    for c in candidates:
        if c and os.path.isfile(c) and os.access(c, os.X_OK):
            return c
    return None


VANILLA_SHADERS = find_vanilla()
GLSLANG = find_glslang()

# Pack overrides first, then the game's tree, since `<minecraft:name>` resolves
# against whichever pack is on top at runtime and the game supplies the rest.
INCLUDE_DIRS = [os.path.join(SHADERS, "include")]
if VANILLA_SHADERS:
    INCLUDE_DIRS.append(os.path.join(VANILLA_SHADERS, "include"))
SEARCH_SHADERS = [SHADERS] + ([VANILLA_SHADERS] if VANILLA_SHADERS else [])

# The only external target the game hands a post chain in the world context.
EXTERNAL_TARGETS = {"minecraft:main"}
MAIN = "minecraft:main"

INCLUDE_RE = re.compile(r"^\s*#\s*include\s*<minecraft:([^>]+)>\s*$", re.M)


def find_include(name):
    for d in INCLUDE_DIRS:
        target = os.path.join(d, name)
        if os.path.exists(target):
            return target
    raise SystemExit("missing include %s (looked in %s)" % (name, INCLUDE_DIRS))


def preprocess(path, seen=None):
    seen = seen or set()
    real = os.path.realpath(path)
    if real in seen:
        return ""
    seen.add(real)

    with open(path) as f:
        source = f.read()

    # The #version directive has to stay on the first line, and the defines the
    # game injects go after it, so lift it out here and let compile_one put it
    # back in the right place.
    source = re.sub(r"^\s*#\s*version\s+\d+[^\n]*\n", "", source, count=1)

    def replace(match):
        return preprocess(find_include(match.group(1)), seen)

    # Includes can nest, and the guard macros around them are the only thing
    # stopping infinite recursion, so resolve repeatedly.
    for _ in range(16):
        expanded = INCLUDE_RE.sub(replace, source)
        if expanded == source:
            break
        source = expanded
    return source


def compile_one(src, defines, stage):
    lines = ["#version 330", "#extension GL_ARB_separate_shader_objects : require"]
    lines += ["#define %s %s" % (k, v) for k, v in sorted(defines.items())]
    if stage == "vert":
        # gl_VertexIndex only exists from GLSL 4.00 / ES 3.00 on, but the game
        # compiles these at 330 with it available, and the vanilla cloud shader
        # relies on it.
        lines.append("#define gl_VertexIndex gl_VertexID")
    lines.append(src)
    body = "\n".join(lines)
    with tempfile.NamedTemporaryFile("w", suffix="." + stage, delete=False) as f:
        f.write(body)
        name = f.name
    try:
        return subprocess.run([GLSLANG, name], capture_output=True, text=True)
    finally:
        os.unlink(name)


BASE = {
    "GLINT": "",
    "APPLY_TEXTURE_MATRIX": "",
    "APPLY_BEACON": "",
    "TEXTURE_MATRIX": "",
    "USE_RGSS": "",
    # Supplied by the game's OIT setup, never present in the source. Any power of
    # two works; 4 is what the fabulous pipeline ships with.
    "OIT_COEFF_COUNT": "4",
    "OIT_WAVELET_RANK": "3",
}

# (name, vertex, fragment, defines)
CASES = [
    ("terrain/plain", "core/terrain.vsh", "core/terrain.fsh",
     {"MULTIDRAW_TERRAIN": "", "PER_FACE_LIGHTING": ""}),
    ("terrain/cutout", "core/terrain.vsh", "core/terrain.fsh",
     {"MULTIDRAW_TERRAIN": "", "ALPHA_CUTOUT": "0.5"}),
    ("terrain/oit-accumulate", "core/terrain.vsh", "core/terrain.fsh",
     {"MULTIDRAW_TERRAIN": "", "OIT": "", "OIT_ACCUMULATE": ""}),
    ("terrain/oit-alpha-only", "core/terrain.vsh", "core/terrain.fsh",
     {"MULTIDRAW_TERRAIN": "", "OIT": "", "OIT_ALPHA_ONLY": ""}),

    ("entity/plain", "core/entity.vsh", "core/entity.fsh", {}),
    ("entity/cutout", "core/entity.vsh", "core/entity.fsh", {"ALPHA_CUTOUT": "0.1"}),
    ("entity/glint", "core/entity.vsh", "core/entity.fsh", {"GLINT": ""}),
    ("entity/emissive", "core/entity.vsh", "core/entity.fsh", {"EMISSIVE": ""}),
    ("entity/no-overlay", "core/entity.vsh", "core/entity.fsh", {"NO_OVERLAY": ""}),
    ("entity/dissolve", "core/entity.vsh", "core/entity.fsh", {"DISSOLVE": ""}),
    ("entity/per-face", "core/entity.vsh", "core/entity.fsh", {"PER_FACE_LIGHTING": ""}),
    ("entity/oit", "core/entity.vsh", "core/entity.fsh",
     {"OIT": "", "OIT_ACCUMULATE": "", "ALPHA_CUTOUT": "0.1"}),

    ("clouds/plain", "core/clouds.vsh", "core/clouds.fsh", {}),
    ("clouds/oit", "core/clouds.vsh", "core/clouds.fsh",
     {"OIT": "", "OIT_ACCUMULATE": ""}),
    # The depth-bounds pass is always the alpha-only one, and oit_depth_bounds
    # declares fragColor itself, so the pair has to be tested together.
    ("clouds/depth-bounds", "core/clouds.vsh", "core/clouds.fsh",
     {"OIT": "", "OIT_DEPTH_BOUNDS": "", "OIT_ALPHA_ONLY": ""}),

    ("sky", "core/sky.vsh", "core/sky.fsh", {}),
]

POST = [
    "ssr", "ssr_composite", "vol_mask", "vol_sun", "vol_rays", "vol_fog",
    "vol_composite", "bloom_extract", "bloom_composite", "dof", "colorgrade",
]


def resolve_shader(identifier):
    """minecraft:post/box_blur -> a path, pack first then vanilla."""
    _, _, path = identifier.partition(":")
    if not path:
        path = identifier
    if path.endswith((".fsh", ".vsh", ".glsl")):
        names = [path]
    else:
        names = [path + ".fsh", path + ".vsh", path]
    for base in SEARCH_SHADERS:
        for name in names:
            candidate = os.path.join(base, name)
            if os.path.exists(candidate):
                return candidate
    return None


# UniformValue.Type in 26.3, mapped to the length of its JSON value.
UNIFORM_TYPES = {"int": 1, "ivec3": 3, "float": 1, "vec2": 2, "vec3": 3, "vec4": 4,
                 "matrix4x4": 16}
UNIFORM_BLOCK_RE = re.compile(r"uniform\s+(\w+)\s*\{(.*?)\}", re.S)


def check_uniforms(where, source, uniforms, errors):
    """Match the JSON uniform blocks against the shader's declarations."""
    blocks = {name: re.findall(r"\b(\w+)\s*;", body) for name, body in UNIFORM_BLOCK_RE.findall(source)}

    for block, entries in uniforms.items():
        if block not in blocks:
            errors.append("%s: shader has no uniform block %s" % (where, block))
            continue
        for u in entries:
            name = u.get("name")
            if name not in blocks[block]:
                errors.append("%s: %s.%s is not in the shader" % (where, block, name))

            kind = u.get("type")
            if kind not in UNIFORM_TYPES:
                errors.append("%s: %s.%s has unknown type %r" % (where, block, name, kind))
                continue
            if "value" not in u:
                errors.append("%s: %s.%s has no value" % (where, block, name))
                continue
            value = u["value"]
            want = UNIFORM_TYPES[kind]
            got = len(value) if isinstance(value, list) else 1
            if got != want:
                errors.append("%s: %s.%s is %s but has %d value(s)"
                              % (where, block, name, kind, got))


# The game version this pack targets, as (major, minor) of the resource format.
CLIENT_VERSION = (97, 1)
# PackFormat.lastPreMinorVersion for client resources: below this, a pack must
# also declare the legacy pack_format / supported_formats fields.
LAST_PRE_MINOR = 64


def as_format(value):
    """A pack format is either [major] or [major, minor]."""
    if isinstance(value, int):
        return (value, 0)
    if isinstance(value, list) and value and all(isinstance(v, int) for v in value):
        return tuple(value) if len(value) > 1 else (value[0], 0)
    return None


def check_mcmeta(path, version):
    """Mirror PackFormat.IntermediaryFormat.validate for a resource pack."""
    name = os.path.basename(path)
    errors = []
    try:
        with open(path) as f:
            meta = json.load(f)
    except (OSError, ValueError) as exc:
        print("FAIL %s: %s" % (name, exc))
        return 1

    pack = meta.get("pack")
    if not isinstance(pack, dict):
        print("FAIL %s: no pack object" % name)
        return 1

    if "description" not in pack:
        errors.append("description is required")

    lo, hi = pack.get("min_format"), pack.get("max_format")
    if (lo is None) != (hi is None):
        errors.append("min_format and max_format must both be declared")
    elif lo is not None:
        lo_f, hi_f = as_format(lo), as_format(hi)
        if lo_f is None or hi_f is None:
            errors.append("min_format/max_format must be [major] or [major, minor]")
        else:
            if lo_f > hi_f:
                errors.append("min_format %s is greater than max_format %s"
                              % (list(lo), list(hi)))
            if "pack_format" in pack:
                errors.append("pack_format is only allowed below format %d" % LAST_PRE_MINOR)
            if "supported_formats" in pack:
                errors.append("supported_formats is deprecated from format %d on"
                              % (LAST_PRE_MINOR + 1))
            if lo_f[0] <= LAST_PRE_MINOR:
                errors.append("min_format is %s but formats up to %d need a pack_format field"
                              % (list(lo), LAST_PRE_MINOR))
            if version < lo_f or version > hi_f:
                errors.append("target %d.%d falls outside %d.%d to %d.%d, so the pack "
                              "will not load on the version it targets"
                              % (version + lo_f + hi_f))

    for e in errors:
        print("FAIL %s: %s" % (name, e))
    return len(errors)


def check_chain(name, path):
    """Structural checks on a post effect definition.

    Mirrors PostChainConfig's codecs in 26.3 closely enough that a chain which
    passes here is very unlikely to be rejected at load time.
    """
    errors = []
    with open(path) as f:
        chain = json.load(f)

    declared = set(chain.get("targets", {}))
    passes = chain.get("passes", [])

    if not passes:
        errors.append("no passes")

    for target, spec in chain.get("targets", {}).items():
        for dim in ("width", "height"):
            if dim in spec and not (isinstance(spec[dim], int) and spec[dim] > 0):
                errors.append("target %r has a non-positive %s" % (target, dim))

    written = set()
    read = set()
    main_write = None
    last_depth_read = -1

    for i, p in enumerate(passes):
        where = "pass %d (%s)" % (i, p.get("fragment_shader", "?"))

        for key in ("vertex_shader", "fragment_shader"):
            if not p.get(key):
                errors.append("%s: missing %s" % (where, key))
            elif resolve_shader(p[key]) is None:
                # Without the game's own shader tree, the passes that reuse a
                # vanilla shader (box_blur, blit) simply cannot be resolved.
                if VANILLA_SHADERS:
                    errors.append("%s: cannot resolve %s" % (where, p[key]))

        if "output" not in p:
            errors.append("%s: output is required" % where)
        out = p.get("output", "")
        if out and out not in declared and out not in EXTERNAL_TARGETS:
            errors.append("%s: writes undeclared target %r" % (where, out))
        written.add(out)

        if out == MAIN:
            if main_write is not None:
                errors.append("%s: main is written twice" % where)
            main_write = i

        # The codec rejects a pass whose inputs reuse a sampler name.
        seen_samplers = set()
        for inp in p.get("inputs", []):
            sampler_name = inp.get("sampler_name")
            if not sampler_name:
                errors.append("%s: an input has no sampler_name" % where)
                continue
            if sampler_name in seen_samplers:
                errors.append("%s: repeated sampler name %r" % (where, sampler_name))
            seen_samplers.add(sampler_name)

            # Input.CODEC is an xor of the texture and target forms, so an input
            # has to match exactly one of them.
            texture_fields = {"location", "width", "height"}
            target_fields = {"target"}
            has_texture = bool(texture_fields & set(inp))
            has_target = bool(target_fields & set(inp))
            if has_texture and has_target:
                errors.append("%s: input %r is both a texture and a target input"
                              % (where, sampler_name))
                continue
            if not has_texture and not has_target:
                errors.append("%s: input %r has neither target nor location" % (where, sampler_name))
                continue

            if has_texture:
                # A texture input samples textures/effect/, not a chain target.
                continue

            target = inp["target"]
            if target not in declared and target not in EXTERNAL_TARGETS:
                errors.append("%s: reads undeclared target %r" % (where, target))
            read.add(target)

            if inp.get("use_depth_buffer"):
                # Only the imported main target is guaranteed a depth texture.
                if target != MAIN:
                    errors.append("%s: %r has no depth buffer to read" % (where, target))
                last_depth_read = i

        # The game appends "Sampler" to the sampler name before binding it.
        frag = resolve_shader(p.get("fragment_shader", ""))
        if frag:
            with open(frag) as f:
                source = f.read()
            for sampler_name in seen_samplers:
                sampler = sampler_name + "Sampler"
                if not re.search(r"\b%s\b" % re.escape(sampler), source):
                    errors.append("%s: shader has no %s" % (where, sampler))

            check_uniforms(where, source, p.get("uniforms", {}), errors)

    for target in declared:
        if target not in written:
            errors.append("target %r is never written" % target)
        elif target not in read:
            errors.append("target %r is never read" % target)

    # Everything that samples depth has to do so before a pass renders into main,
    # because that pass owns main's depth attachment from then on.
    if main_write is not None and last_depth_read > main_write:
        errors.append("depth is read after main is written (pass %d)" % last_depth_read)
    if main_write is not None and main_write != len(passes) - 1:
        errors.append("main is not written by the final pass")

    for e in errors:
        print("CHAIN FAIL %s: %s" % (name, e))
    return len(errors)


def main():
    failures = 0
    total = 0

    if GLSLANG and VANILLA_SHADERS:
        for name, vert, frag, defines in CASES:
            for stage, rel in (("vert", vert), ("frag", frag)):
                if not os.path.exists(os.path.join(SHADERS, rel)):
                    continue
                total += 1
                d = dict(BASE)
                d.update(defines)
                src = preprocess(os.path.join(SHADERS, rel))
                res = compile_one(src, d, stage)
                if res.returncode != 0:
                    failures += 1
                    print("FAIL %s [%s]" % (name, stage))
                    print(res.stdout[:4000])
                    print(res.stderr[:2000])

        for name in POST:
            total += 1
            src = preprocess(os.path.join(SHADERS, "post", name + ".fsh"))
            res = compile_one(src, {}, "frag")
            if res.returncode != 0:
                failures += 1
                print("FAIL post/%s" % name)
                print(res.stdout[:4000])
                print(res.stderr[:2000])

        # Linking a stage pair catches varyings that disagree between them, which
        # compiling each side on its own cannot.
        for name, vert, frag, defines in CASES:
            vpath = os.path.join(SHADERS, vert)
            fpath = os.path.join(SHADERS, frag)
            if not (os.path.exists(vpath) and os.path.exists(fpath)):
                continue
            if name.endswith("oit-alpha-only"):
                continue
            total += 1
            d = dict(BASE)
            d.update(defines)
            v = compile_one(preprocess(vpath), d, "vert").returncode == 0
            f = compile_one(preprocess(fpath), d, "frag").returncode == 0
            if not (v and f):
                continue
            with tempfile.TemporaryDirectory() as tmp:
                vp = os.path.join(tmp, "a.vert")
                fp = os.path.join(tmp, "a.frag")
                for path, rel, stage in ((vp, vert, "vert"), (fp, frag, "frag")):
                    with open(path, "w") as fh:
                        fh.write("\n".join(
                            ["#version 330",
                             "#extension GL_ARB_separate_shader_objects : require"]
                            + ["#define %s %s" % (k, v) for k, v in sorted(d.items())]
                            + (["#define gl_VertexIndex gl_VertexID"] if stage == "vert" else [])
                            + [preprocess(os.path.join(SHADERS, rel))]))
                res = subprocess.run([GLSLANG, "-l", vp, fp], capture_output=True, text=True)
                if res.returncode != 0:
                    failures += 1
                    print("LINK FAIL %s" % name)
                    print(res.stdout[:4000])
    else:
        missing = []
        if not GLSLANG:
            missing.append("glslang (set $GLSLANG or put glslangValidator on PATH)")
        if not VANILLA_SHADERS:
            missing.append("the game's shader tree (set $VANILLA_SHADERS)")
        print("SKIP: cannot compile shaders, missing %s" % " and ".join(missing))
        print("      Only the post effect chain checks below will run.\n")

    if os.path.isdir(POST_EFFECTS):
        for entry in sorted(os.listdir(POST_EFFECTS)):
            if not entry.endswith(".json"):
                continue
            total += 1
            bad = check_chain(entry[:-5], os.path.join(POST_EFFECTS, entry))
            if bad:
                failures += 1

    total += 1
    bad = check_mcmeta(os.path.join(ROOT, "pack.mcmeta"), CLIENT_VERSION)
    if bad:
        failures += 1

    print("\n%d/%d ok, %d failed" % (total - failures, total, failures))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
