import ctypes, itertools, json, os, re, sys, zipfile

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
}
DEFAULT_VARIANTS = [{}]
MULTIDRAW = {"terrain"}

# Backend-dependent macros renderpearl injects. Any shader that tests one gets
# checked with it both set and unset, since which backend the game picks varies.
BACKEND_MACROS = ["RENDERPEARL_DEPTH_IS_ZERO_TO_ONE",
                  "RENDERPEARL_EXPLICIT_DEPTH_INVARIANCE"]

# Uniform blocks PostPass binds itself, so a post shader may declare them
# without the post_effect json listing them. Blocks that arrive through a vanilla
# include (Globals, Projection, ...) are engine-owned too, and are excluded by
# reflecting on the unresolved source.
ENGINE_POST_BLOCKS = {"SamplerInfo"}

def cache_dir():
    if os.name == "nt":
        base = os.environ.get("LOCALAPPDATA", os.path.expanduser("~"))
        return os.path.join(base, "shader_mc-glslcheck")
    base = os.environ.get("XDG_CACHE_HOME", os.path.expanduser("~/.cache"))
    return os.path.join(base, "shader_mc-glslcheck")

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

def backend_variants(source):
    """Permute over the backend macros this shader actually tests."""
    used = [m for m in BACKEND_MACROS if m in resolve(source)]
    if not used:
        return [{}]
    return [dict(zip(used, ("1",) * len(used)))
            for used in [[m for m, on in zip(used, flags) if on]
                         for flags in itertools.product((0, 1), repeat=len(used))]]

# --- compiler backends -------------------------------------------------------
# Minecraft (renderpearl) does not hand GLSL to the GL driver any more: it
# compiles it to SPIR-V with shaderc, targeting Vulkan, with uniforms auto-bound.
# That compiler is much stricter than a desktop GL driver -- it requires explicit
# layout(location=) on every in/out, for instance -- so validating against the
# driver reports shaders as fine that crash the game. Use the game's own shaderc
# native when we can find it, and only fall back to a GL context if we cannot.

VERT, FRAG = "vert", "frag"

class Shaderc:
    KIND = {VERT: 0, FRAG: 1}
    TARGET_ENV_VULKAN = 0

    def __init__(self, lib):
        self.lib = lib
        lib.shaderc_compiler_initialize.restype = ctypes.c_void_p
        lib.shaderc_compile_options_initialize.restype = ctypes.c_void_p
        lib.shaderc_compile_options_set_target_env.argtypes = [
            ctypes.c_void_p, ctypes.c_int, ctypes.c_uint32]
        lib.shaderc_compile_options_set_auto_bind_uniforms.argtypes = [
            ctypes.c_void_p, ctypes.c_bool]
        lib.shaderc_compile_into_spv.restype = ctypes.c_void_p
        lib.shaderc_compile_into_spv.argtypes = [
            ctypes.c_void_p, ctypes.c_char_p, ctypes.c_size_t, ctypes.c_int,
            ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p]
        lib.shaderc_result_get_compilation_status.restype = ctypes.c_int
        lib.shaderc_result_get_compilation_status.argtypes = [ctypes.c_void_p]
        lib.shaderc_result_get_error_message.restype = ctypes.c_char_p
        lib.shaderc_result_get_error_message.argtypes = [ctypes.c_void_p]
        lib.shaderc_result_release.argtypes = [ctypes.c_void_p]
        self.compiler = lib.shaderc_compiler_initialize()

    name = "shaderc (as Minecraft does)"

    def compile(self, source, stage, label):
        opts = self.lib.shaderc_compile_options_initialize()
        self.lib.shaderc_compile_options_set_target_env(
            opts, self.TARGET_ENV_VULKAN, 1 << 22)
        self.lib.shaderc_compile_options_set_auto_bind_uniforms(opts, True)
        blob = source.encode()
        res = self.lib.shaderc_compile_into_spv(
            self.compiler, blob, len(blob), self.KIND[stage],
            label.encode(), b"main", opts)
        ok = self.lib.shaderc_result_get_compilation_status(res) == 0
        log = self.lib.shaderc_result_get_error_message(res) or b""
        log = log.decode(errors="replace").strip()
        self.lib.shaderc_result_release(res)
        return ok, log

def load_shaderc():
    plat, ext = {"linux": ("linux", ".so"), "win32": ("windows", ".dll"),
                 "darwin": ("macos", ".dylib")}.get(sys.platform, (None, None))
    if plat is None:
        return None
    roots = [mc_dir, os.path.expanduser("~/.minecraft")]
    for root in roots:
        libs = os.path.join(root, "libraries/org/lwjgl/lwjgl-shaderc")
        if not os.path.isdir(libs):
            continue
        for ver in sorted(os.listdir(libs), reverse=True):
            natives = os.path.join(
                libs, ver, "lwjgl-shaderc-%s-natives-%s.jar" % (ver, plat))
            if not os.path.exists(natives):
                continue
            with zipfile.ZipFile(natives) as z:
                member = next((n for n in z.namelist() if n.endswith(ext)), None)
                if member is None:
                    continue
                out = os.path.join(cache_dir(), "shaderc-" + ver,
                                   os.path.basename(member))
                if not os.path.exists(out):
                    os.makedirs(os.path.dirname(out), exist_ok=True)
                    with open(out, "wb") as fh:
                        fh.write(z.read(member))
            try:
                return Shaderc(ctypes.CDLL(out))
            except OSError:
                continue
    return None

class DriverGL:
    name = "desktop GL driver (fallback -- LOOSER than Minecraft)"

    def __init__(self):
        from OpenGL import EGL, GL
        self.GL = GL
        display = EGL.eglGetDisplay(EGL.EGL_DEFAULT_DISPLAY)
        EGL.eglInitialize(display, ctypes.pointer(EGL.EGLint()),
                          ctypes.pointer(EGL.EGLint()))
        cfgs, ncfg = (EGL.EGLConfig * 1)(), EGL.EGLint()
        cfg_attrs = [EGL.EGL_SURFACE_TYPE, EGL.EGL_PBUFFER_BIT,
                     EGL.EGL_RENDERABLE_TYPE, EGL.EGL_OPENGL_BIT, EGL.EGL_NONE]
        EGL.eglChooseConfig(display, (EGL.EGLint * len(cfg_attrs))(*cfg_attrs),
                            cfgs, 1, ctypes.pointer(ncfg))
        EGL.eglBindAPI(EGL.EGL_OPENGL_API)
        ctx_attrs = [EGL.EGL_CONTEXT_MAJOR_VERSION, 3,
                     EGL.EGL_CONTEXT_MINOR_VERSION, 3,
                     EGL.EGL_CONTEXT_OPENGL_PROFILE_MASK,
                     EGL.EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT, EGL.EGL_NONE]
        ctx = EGL.eglCreateContext(display, cfgs[0], EGL.EGL_NO_CONTEXT,
                                   (EGL.EGLint * len(ctx_attrs))(*ctx_attrs))
        if not ctx:
            sys.exit("Could not create an OpenGL 3.3 context via EGL.")
        EGL.eglMakeCurrent(display, EGL.EGL_NO_SURFACE, EGL.EGL_NO_SURFACE, ctx)

    def compile(self, source, stage, label):
        GL = self.GL
        shader = GL.glCreateShader(
            {VERT: GL.GL_VERTEX_SHADER, FRAG: GL.GL_FRAGMENT_SHADER}[stage])
        GL.glShaderSource(shader, source)
        GL.glCompileShader(shader)
        ok = GL.glGetShaderiv(shader, GL.GL_COMPILE_STATUS)
        log = GL.glGetShaderInfoLog(shader)
        GL.glDeleteShader(shader)
        return bool(ok), (log.decode() if isinstance(log, bytes) else log or "").strip()

backend = load_shaderc()
if backend is None:
    print("WARNING: could not find the game's shaderc native under %s." % mc_dir,
          file=sys.stderr)
    print("Falling back to the GL driver, which accepts shaders Minecraft "
          "rejects.", file=sys.stderr)
    try:
        backend = DriverGL()
    except ImportError as exc:
        print("PyOpenGL could not load the EGL backend on this machine.",
              file=sys.stderr)
        raise SystemExit(1) from exc

def compile(source, defines, stage, label="shader"):
    return backend.compile(build(source, defines), stage, label)

# --- interface reflection ----------------------------------------------------
# renderpearl links stages by location, and rejects a shader that declares a
# uniform the pass does not provide, so check both without launching the game.

IO_RE = re.compile(
    r"layout\s*\(\s*location\s*=\s*(\d+)\s*\)\s*(?:flat\s+)?(in|out)\s+(\w+)\s+(\w+)")
SAMPLER_RE = re.compile(r"uniform\s+sampler\w+\s+(\w+)\s*;")
BLOCK_RE = re.compile(r"layout\s*\(\s*std140\s*\)\s*uniform\s+(\w+)")

def interface(source, direction):
    return {int(loc): (typ, name)
            for loc, d, typ, name in IO_RE.findall(source) if d == direction}

def check_pass_interface(vsh, fsh, provided_samplers, provided_blocks):
    problems = []
    outs, ins = interface(vsh, "out"), interface(fsh, "in")
    for loc, (typ, name) in sorted(ins.items()):
        if loc not in outs:
            problems.append("fragment input %s at location %d has no vertex "
                            "shader output" % (name, loc))
        elif outs[loc][0] != typ:
            problems.append("location %d: vertex outputs %s %s, fragment reads "
                            "%s %s" % (loc, outs[loc][0], outs[loc][1], typ, name))
    declared = set(SAMPLER_RE.findall(fsh))
    for name in sorted(declared - provided_samplers):
        problems.append("declares sampler %s, which the pass does not bind "
                        "(expected one of: %s)"
                        % (name, ", ".join(sorted(provided_samplers)) or "none"))
    for name in sorted(provided_samplers - declared):
        problems.append("pass binds %s, which the shader never declares" % name)
    blocks = set(BLOCK_RE.findall(fsh)) | set(BLOCK_RE.findall(vsh))
    for name in sorted(blocks - provided_blocks - ENGINE_POST_BLOCKS):
        problems.append("declares uniform block %s, which the pass does not "
                        "provide" % name)
    return problems

def shader_source(shader_id, ext):
    """Pack source for a shader id like 'minecraft:post/ssr', else vanilla."""
    name = shader_id.split(":", 1)[-1] + ext
    path = os.path.join(src_dir, "assets/minecraft/shaders", name)
    if os.path.exists(path):
        return name, open(path).read()
    return name, vanilla(name)

print("pack:    %s" % src_dir)
print("vanilla: %s" % version)
print("compiler: %s" % backend.name)
print()

core = os.path.join(src_dir, "assets/minecraft/shaders/core")
post_effect = os.path.join(src_dir, "assets/minecraft/post_effect")
if not os.path.isdir(core):
    sys.exit("No core shaders at " + core)

failed = skipped = passed = 0

def report(label, ok, log, vanilla_source=None, defines=None, stage=None):
    global failed, skipped, passed
    if ok:
        passed += 1
        print("  PASS  %s" % label)
        return
    if vanilla_source and not compile(vanilla_source, defines, stage, label)[0]:
        skipped += 1
        print("  SKIP  %s  (vanilla fails here too -- needs engine defines)" % label)
        return
    failed += 1
    print("  FAIL  %s" % label)
    for line in log.splitlines():
        print("          %s" % line)

print("Core shaders:")
for filename in sorted(os.listdir(core)):
    stem, ext = os.path.splitext(filename)
    stage = {".vsh": VERT, ".fsh": FRAG}.get(ext)
    if stage is None:
        continue
    ours = open(os.path.join(core, filename)).read()
    theirs = vanilla("core/" + filename)

    variants = list(VARIANTS.get(stem, DEFAULT_VARIANTS))
    if stem in MULTIDRAW:
        variants += [dict(v, MULTIDRAW_TERRAIN="1") for v in variants]
    variants = [dict(v, **b) for v in variants for b in backend_variants(ours)]

    for defines in variants:
        label = "%s [%s]" % (filename, " ".join(sorted(defines)) or "-")
        ok, log = compile(ours, defines, stage, filename)
        report(label, ok, log, theirs, defines, stage)

# Post-pass shaders are checked through their post_effect json, which is what
# names the samplers and pairs each fragment shader with a vertex shader.
if os.path.isdir(post_effect):
    print()
    print("Post-effect chains:")
    for filename in sorted(os.listdir(post_effect)):
        if not filename.endswith(".json"):
            continue
        chain = json.load(open(os.path.join(post_effect, filename)))
        for i, chain_pass in enumerate(chain.get("passes", [])):
            for key, ext, stage in (("vertex_shader", ".vsh", VERT),
                                    ("fragment_shader", ".fsh", FRAG)):
                name, source = shader_source(chain_pass[key], ext)
                label = "%s pass %d: %s" % (filename, i, name)
                if source is None:
                    failed += 1
                    print("  FAIL  %s  (no such shader in pack or vanilla)" % label)
                    continue
                for defines in backend_variants(source):
                    ok, log = compile(source, defines, stage, name)
                    report(label, ok, log)

            vname, vsh = shader_source(chain_pass["vertex_shader"], ".vsh")
            fname, fsh = shader_source(chain_pass["fragment_shader"], ".fsh")
            if vsh is None or fsh is None:
                continue
            samplers = {inp["sampler_name"] + "Sampler"
                        for inp in chain_pass.get("inputs", [])}
            blocks = set(chain_pass.get("uniforms", {}))
            problems = check_pass_interface(vsh, fsh, samplers, blocks)
            label = "%s pass %d: %s + %s" % (filename, i, vname, fname)
            if not problems:
                passed += 1
                print("  PASS  %s  (interface)" % label)
                continue
            failed += 1
            print("  FAIL  %s  (interface)" % label)
            for problem in problems:
                print("          %s" % problem)

print()
print("%d passed, %d failed, %d skipped" % (passed, failed, skipped))
sys.exit(1 if failed else 0)
