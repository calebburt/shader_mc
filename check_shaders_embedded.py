import ctypes, json, os, re, sys, zipfile

os.environ.setdefault("PYOPENGL_PLATFORM", "egl")

src_dir, mc_dir = sys.argv[1], sys.argv[2]
forced_version = sys.argv[3] if len(sys.argv) > 3 else ""

VARIANTS = {
    "terrain": [
        {},
        {"ALPHA_CUTOUT": "0.1"},
        {"OIT": "1", "OIT_ACCUMULATE": "1"},
        {"OIT": "1", "OIT_ALPHA_ONLY": "1", "OIT_DEPTH_BOUNDS": "1"},
        {"OIT": "1", "OIT_ALPHA_ONLY": "1", "OIT_TRANSMITTANCE": "1"},
    ],
    "ssr": [{}],
}
DEFAULT_VARIANTS = [{}]
MULTIDRAW = {"terrain"}
POST_PASS_SHADERS = {"ssr"}

def find_jar():
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
    lines = resolve(source).splitlines()
    head = [l for l in lines if l.startswith(("#version", "#extension"))]
    body = [l for l in lines if not l.startswith(("#version", "#extension"))]
    injected = ["#define %s %s" % kv for kv in defines.items()]
    return "\n".join(head + injected + body)

try:
    from OpenGL import EGL, GL
except ImportError as exc:
    print("Shader validation requires a working EGL/OpenGL runtime.", file=sys.stderr)
    print("PyOpenGL could not load the EGL backend on this machine.", file=sys.stderr)
    print("Install a Mesa/EGL runtime or run the checker from WSL/Linux.", file=sys.stderr)
    raise SystemExit(1) from exc

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
post = os.path.join(src_dir, "assets/minecraft/shaders/post")
if not os.path.isdir(core):
    sys.exit("No core shaders at " + core)

failed = skipped = passed = 0

# Check core shaders
print("Core shaders:")
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
        if theirs and not compile(theirs, defines, stage)[0]:
            skipped += 1
            print("  SKIP  %s  (vanilla fails here too -- needs engine defines)" % label)
            continue
        failed += 1
        print("  FAIL  %s" % label)
        for line in log.splitlines():
            print("          %s" % line)

# Check post-pass shaders if directory exists
if os.path.isdir(post):
    print()
    print("Post-pass shaders:")
    for filename in sorted(os.listdir(post)):
        stem, ext = os.path.splitext(filename)
        stage = {".vsh": GL.GL_VERTEX_SHADER, ".fsh": GL.GL_FRAGMENT_SHADER}.get(ext)
        if stage is None:
            continue
        # Skip post-pass shaders not in our VARIANTS list
        if stem not in VARIANTS:
            continue
        
        ours = open(os.path.join(post, filename)).read()
        variants = list(VARIANTS.get(stem, DEFAULT_VARIANTS))
        
        for defines in variants:
            label = "%s [%s]" % (filename, " ".join(sorted(defines)) or "-")
            ok, log = compile(ours, defines, stage)
            if ok:
                passed += 1
                print("  PASS  %s" % label)
                continue
            failed += 1
            print("  FAIL  %s" % label)
            for line in log.splitlines():
                print("          %s" % line)

print()
print("%d passed, %d failed, %d skipped" % (passed, failed, skipped))
sys.exit(1 if failed else 0)
