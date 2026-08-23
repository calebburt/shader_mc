#!/usr/bin/env bash
# Compile this pack's core shaders against a real OpenGL 3.3 context and report
# GLSL errors, so you don't have to bounce off Minecraft's pack screen to find a
# typo. Minecraft only ever shows the first error per shader; this shows all of
# them, for every #define permutation the game compiles terrain under.
#
#   ./check_shaders.sh              # auto-detect game version from pack.mcmeta
#   MC_VERSION=26.2 ./check_shaders.sh
#
# Exits non-zero if any shader fails where the vanilla original succeeds.
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MC_DIR="${MINECRAFT_DIR:-$HOME/.minecraft}"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/shader_mc-glslcheck"
VENV="$CACHE/venv"

# PyOpenGL drives a headless EGL context. Kept out of the repo, built once.
if [ ! -x "$VENV/bin/python" ]; then
  echo "Creating check venv in $VENV ..."
  mkdir -p "$CACHE"
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install -q PyOpenGL
fi

exec "$VENV/bin/python" - "$SRC_DIR" "$MC_DIR" "${MC_VERSION:-}" <<'PY'
import ctypes, json, os, re, sys, zipfile

src_dir, mc_dir, forced_version = sys.argv[1], sys.argv[2], sys.argv[3]

# Minecraft compiles terrain once per pipeline, each with a different set of
# #defines. A shader can compile fine under one and fail under another.
VARIANTS = {
    "terrain": [
        {},                                                        # solid
        {"ALPHA_CUTOUT": "0.1"},                                   # cutout
        {"OIT": "1", "OIT_ACCUMULATE": "1"},                       # translucent
        {"OIT": "1", "OIT_ALPHA_ONLY": "1", "OIT_DEPTH_BOUNDS": "1"},
        {"OIT": "1", "OIT_ALPHA_ONLY": "1", "OIT_TRANSMITTANCE": "1"},
    ],
}
DEFAULT_VARIANTS = [{}]
MULTIDRAW = {"terrain"}          # these also get a _multidraw pipeline


def find_jar():
    """Pick the game version whose resource pack format matches pack.mcmeta."""
    versions = os.path.join(mc_dir, "versions")
    if forced_version:
        jar = os.path.join(versions, forced_version, forced_version + ".jar")
        if not os.path.exists(jar):
            sys.exit("No jar at " + jar)
        return forced_version, jar

    meta = json.load(open(os.path.join(src_dir, "pack.mcmeta")))["pack"]
    want = meta.get("min_format", meta.get("pack_format"))
    want = want[0] if isinstance(want, list) else want
    if want is None:
        sys.exit("pack.mcmeta declares no min_format; set MC_VERSION instead.")

    for name in sorted(os.listdir(versions)):
        jar = os.path.join(versions, name, name + ".jar")
        if not os.path.exists(jar):
            continue
        try:
            with zipfile.ZipFile(jar) as z:
                pv = json.loads(z.read("version.json"))["pack_version"]
        except Exception:
            continue
        if pv.get("resource_major") == want:
            return name, jar
    sys.exit("No installed version has resource format %s. Set MC_VERSION." % want)


version, jar_path = find_jar()
jar = zipfile.ZipFile(jar_path)
SHADER_ROOT = "assets/minecraft/shaders/"


def vanilla(path):
    try:
        return jar.read(SHADER_ROOT + path).decode()
    except KeyError:
        return None


def resolve(source, seen=None):
    """Inline #moj_import / #include the way Minecraft's preprocessor does."""
    seen = set() if seen is None else seen
    out = []
    for line in source.splitlines():
        m = re.match(r"\s*#(?:moj_import|include)\s*<minecraft:([\w./]+)>", line)
        if not m:
            out.append(line)
            continue
        name = m.group(1)
        if name in seen:
            continue
        seen.add(name)
        body = vanilla("include/" + name)
        if body is None:
            out.append("#error missing include " + name)
            continue
        out.append(resolve("\n".join(
            l for l in body.splitlines() if not l.startswith("#version")), seen))
    return "\n".join(out)


def build(source, defines):
    """#version and #extension must stay at the top, so defines go after them."""
    lines = resolve(source).splitlines()
    head = [l for l in lines if l.startswith(("#version", "#extension"))]
    body = [l for l in lines if not l.startswith(("#version", "#extension"))]
    injected = ["#define %s %s" % kv for kv in defines.items()]
    return "\n".join(head + injected + body)


from OpenGL import EGL, GL

display = EGL.eglGetDisplay(EGL.EGL_DEFAULT_DISPLAY)
EGL.eglInitialize(display, ctypes.pointer(EGL.EGLint()), ctypes.pointer(EGL.EGLint()))
cfgs, ncfg = (EGL.EGLConfig * 1)(), EGL.EGLint()
cfg_attrs = [EGL.EGL_SURFACE_TYPE, EGL.EGL_PBUFFER_BIT,
             EGL.EGL_RENDERABLE_TYPE, EGL.EGL_OPENGL_BIT, EGL.EGL_NONE]
EGL.eglChooseConfig(display, (EGL.EGLint * len(cfg_attrs))(*cfg_attrs),
                    cfgs, 1, ctypes.pointer(ncfg))
EGL.eglBindAPI(EGL.EGL_OPENGL_API)
ctx_attrs = [EGL.EGL_CONTEXT_MAJOR_VERSION, 3, EGL.EGL_CONTEXT_MINOR_VERSION, 3,
             EGL.EGL_CONTEXT_OPENGL_PROFILE_MASK,
             EGL.EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT, EGL.EGL_NONE]
ctx = EGL.eglCreateContext(display, cfgs[0], EGL.EGL_NO_CONTEXT,
                           (EGL.EGLint * len(ctx_attrs))(*ctx_attrs))
if not ctx:
    sys.exit("Could not create an OpenGL 3.3 context via EGL.")
EGL.eglMakeCurrent(display, EGL.EGL_NO_SURFACE, EGL.EGL_NO_SURFACE, ctx)


def compile(source, defines, stage):
    shader = GL.glCreateShader(stage)
    GL.glShaderSource(shader, build(source, defines))
    GL.glCompileShader(shader)
    ok = GL.glGetShaderiv(shader, GL.GL_COMPILE_STATUS)
    log = GL.glGetShaderInfoLog(shader)
    GL.glDeleteShader(shader)
    return bool(ok), (log.decode() if isinstance(log, bytes) else log or "").strip()


print("pack:   %s" % src_dir)
print("vanilla: %s (%s)" % (version, GL.glGetString(GL.GL_VERSION).decode()))
print()

core = os.path.join(src_dir, "assets/minecraft/shaders/core")
if not os.path.isdir(core):
    sys.exit("No core shaders at " + core)

failed = skipped = passed = 0
for filename in sorted(os.listdir(core)):
    stem, ext = os.path.splitext(filename)
    stage = {".vsh": GL.GL_VERTEX_SHADER, ".fsh": GL.GL_FRAGMENT_SHADER}.get(ext)
    if stage is None:
        continue
    ours = open(os.path.join(core, filename)).read()
    theirs = vanilla("core/" + filename)

    variants = list(VARIANTS.get(stem, DEFAULT_VARIANTS))
    if stem in MULTIDRAW:
        variants += [dict(v, MULTIDRAW_TERRAIN="1") for v in variants]

    for defines in variants:
        label = "%s [%s]" % (filename, " ".join(sorted(defines)) or "-")
        ok, log = compile(ours, defines, stage)
        if ok:
            passed += 1
            print("  PASS  %s" % label)
            continue
        # Some variants need defines Minecraft injects from its pipeline config
        # (OIT_COEFF_COUNT and friends) which aren't in the jar's shader tree.
        # If vanilla can't build them here either, it's our harness, not the pack.
        if theirs and not compile(theirs, defines, stage)[0]:
            skipped += 1
            print("  SKIP  %s  (vanilla fails here too -- needs engine defines)" % label)
            continue
        failed += 1
        print("  FAIL  %s" % label)
        for line in log.splitlines():
            print("          %s" % line)

print()
print("%d passed, %d failed, %d skipped" % (passed, failed, skipped))
sys.exit(1 if failed else 0)
PY
