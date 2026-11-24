import bpy, math, sys, random
from mathutils import Vector

argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
PREVIEW = "final" not in argv
OUT = argv[-1]
SRC = r"D:\Godot_Projects\AudioSyncMaster\assets\instruments\source\instruments.blend"

sc = bpy.data.scenes.new("Hero")
bpy.context.window.scene = sc
for s in list(bpy.data.scenes):
    if s != sc:
        bpy.data.scenes.remove(s)

NAMES = ["Driftwood", "Undertow", "Lumen", "Pulsar", "Comet", "Tangle"]
COL_MAT = {"Pulsar": "Pulsar_Orange", "Undertow": "Undertow_Teal", "Comet": "Comet_Pink",
           "Lumen": "Lumen_Gold", "Driftwood": "Driftwood_Green", "Tangle": "Tangle_Violet"}


def mat_color(name):
    m = bpy.data.materials[name]
    b = next(n for n in m.node_tree.nodes if n.type == "BSDF_PRINCIPLED")
    return tuple(b.inputs["Base Color"].default_value)


def emis(name, col, strength):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    nt.nodes.clear()
    o = nt.nodes.new("ShaderNodeOutputMaterial")
    e = nt.nodes.new("ShaderNodeEmission")
    e.inputs[0].default_value = col
    e.inputs[1].default_value = strength
    nt.links.new(e.outputs[0], o.inputs[0])
    return m


def principled(name, col, rough=0.4, metal=0.0, rim=None, rim_strength=0.0):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    b = next(n for n in nt.nodes if n.type == "BSDF_PRINCIPLED")
    b.inputs["Base Color"].default_value = col
    b.inputs["Roughness"].default_value = rough
    b.inputs["Metallic"].default_value = metal
    if rim:
        lw = nt.nodes.new("ShaderNodeLayerWeight")
        lw.inputs[0].default_value = 0.25
        mp = nt.nodes.new("ShaderNodeMath")
        mp.operation = "POWER"
        mp.inputs[1].default_value = 1.6
        ml = nt.nodes.new("ShaderNodeMath")
        ml.operation = "MULTIPLY"
        ml.inputs[1].default_value = rim_strength
        nt.links.new(lw.outputs["Facing"], mp.inputs[0])
        nt.links.new(mp.outputs[0], ml.inputs[0])
        b.inputs["Emission Color"].default_value = rim
        nt.links.new(ml.outputs[0], b.inputs["Emission Strength"])
    return m


with bpy.data.libraries.load(SRC, link=False) as (src, dst):
    dst.collections = [n for n in src.collections if n in NAMES]
colors = {n: mat_color(COL_MAT[n]) for n in NAMES}

R = 1.6
ANG = [-115, -69, -23, 23, 69, 115]


def obj(name, mesh_fn, mat, loc=(0, 0, 0), parent=None):
    mesh_fn()
    o = bpy.context.active_object
    o.name = name
    o.location = loc
    if mat:
        o.data.materials.clear()
        o.data.materials.append(mat)
    if parent:
        o.parent = parent
    return o


def smooth(o):
    for p in o.data.polygons:
        p.use_smooth = True


glass = principled("TableGlass", (0.03, 0.04, 0.07, 1), rough=0.15, metal=0.2)
for n, a in zip(NAMES, ANG):
    col = colors[n]
    phi = math.radians(a)
    root = bpy.data.objects.new(n + "_Station", None)
    sc.collection.objects.link(root)
    root.location = (R * math.sin(phi), R * math.cos(phi), 0)
    root.rotation_euler = (0, 0, math.pi - phi)
    c = bpy.data.collections[n]
    sc.collection.children.link(c)
    tops = [o for o in c.objects if o.parent is None]
    pts = [o.matrix_basis @ Vector(v) for o in c.objects if o.type == "MESH" for v in o.bound_box]
    mn = Vector([min(p[k] for p in pts) for k in range(3)])
    mx = Vector([max(p[k] for p in pts) for k in range(3)])
    ctr = (mn + mx) / 2
    w, d, h = mx.x - mn.x, mx.y - mn.y, mx.z - mn.z
    pivot = bpy.data.objects.new(n + "_Pivot", None)
    sc.collection.objects.link(pivot)
    pivot.parent = root
    pivot.location = (0, 0, 0.80)
    for o in tops:
        o.location -= Vector((ctr.x, ctr.y, mn.z))
        o.parent = pivot
    s = 1.6
    pivot.scale = (s, s, s)
    tw, td = w * s + 0.16, d * s + 0.16
    t = obj(n + "_Table", lambda: bpy.ops.mesh.primitive_cube_add(size=1), glass, (0, 0, 0.78), root)
    t.scale = (tw, td, 0.04)
    bev = t.modifiers.new("b", "BEVEL")
    bev.width = 0.012
    bev.segments = 3
    edge = obj(n + "_Edge", lambda: bpy.ops.mesh.primitive_cube_add(size=1), emis(n + "_EdgeGlow", col, 6), (0, 0, 0.755), root)
    edge.scale = (tw + 0.012, td + 0.012, 0.006)
    # avatar: a remote player, facing +y toward the instrument
    tint = tuple(0.06 * c + 0.025 for c in col[:3]) + (1,)
    bm = principled(n + "_Avatar", tint, rough=0.32, metal=0.3, rim=col, rim_strength=2.2)
    AV = -0.5
    av = bpy.data.objects.new(n + "_Avatar", None)
    sc.collection.objects.link(av)
    av.parent = root
    av.location = (0, AV, 0)
    tor = obj(n + "_Torso", lambda: bpy.ops.mesh.primitive_uv_sphere_add(radius=1, segments=48, ring_count=24), bm, (0, 0, 1.06), av)
    tor.scale = (0.19, 0.12, 0.27)
    smooth(tor)
    nk = obj(n + "_Neck", lambda: bpy.ops.mesh.primitive_cylinder_add(radius=0.04, depth=0.12, vertices=24), bm, (0, 0, 1.33), av)
    smooth(nk)
    hd = obj(n + "_Head", lambda: bpy.ops.mesh.primitive_uv_sphere_add(radius=0.105, segments=48, ring_count=24), bm, (0, 0.0, 1.45), av)
    hd.scale = (0.9, 1, 1.08)
    smooth(hd)
    vis = obj(n + "_Visor", lambda: bpy.ops.mesh.primitive_uv_sphere_add(radius=0.1, segments=48, ring_count=24), emis(n + "_VisorGlow", col, 14), (0, 0.055, 1.465), av)
    vis.scale = (1.02, 0.6, 0.36)
    smooth(vis)
    top_z = 0.80 + h * s
    hmat = principled(n + "_HandMat", tint, rough=0.3, rim=col, rim_strength=5)
    for sx in (-1, 1):
        hx = sx * min(0.15, w * s * 0.26)
        hp_ = Vector((hx, -0.06, top_z + 0.05))
        hnd = obj(n + "_Hand", lambda: bpy.ops.mesh.primitive_uv_sphere_add(radius=0.04, segments=32, ring_count=16), hmat, hp_, root)
        hnd.scale = (0.9, 1.5, 0.5)
        smooth(hnd)
        # arm: shoulder -> elbow -> hand
        ac = bpy.data.curves.new(n + "_Arm", "CURVE")
        ac.dimensions = "3D"
        ac.bevel_depth = 0.026
        ac.bevel_resolution = 4
        ac.resolution_u = 32
        ac.use_fill_caps = True
        asp = ac.splines.new("BEZIER")
        asp.bezier_points.add(1)
        sh = Vector((sx * 0.17, AV, 1.24))
        a0, a1 = asp.bezier_points
        a0.co = sh
        a0.handle_left = sh + Vector((0, 0, 0.05))
        a0.handle_right = sh + Vector((sx * 0.05, 0.02, -0.16))
        a1.co = hp_ + Vector((0, -0.05, 0))
        a1.handle_left = a1.co + Vector((0, -0.1, 0.02))
        a1.handle_right = a1.co
        ao = bpy.data.objects.new(n + "_Arm", ac)
        sc.collection.objects.link(ao)
        ao.parent = root
        ac.materials.append(bm)
    # link from the player's head to the shared clock
    cu = bpy.data.curves.new(n + "_Link", "CURVE")
    cu.dimensions = "3D"
    cu.bevel_depth = 0.0035
    cu.bevel_resolution = 3
    cu.resolution_u = 64
    sp = cu.splines.new("BEZIER")
    sp.bezier_points.add(1)
    rr = R + 0.5
    hp = Vector((rr * math.sin(phi), rr * math.cos(phi), 1.45))
    cp = Vector((0, 0, 1.55))
    p0, p1 = sp.bezier_points
    p0.co = hp + Vector((0, 0, 0.12))
    p0.handle_left = p0.co
    p0.handle_right = p0.co + Vector((0, 0, 0.55)) + (cp - hp) * 0.2
    p1.co = cp
    p1.handle_right = cp
    p1.handle_left = cp + Vector((0, 0, 0.35)) + (hp - cp) * 0.3
    lo = bpy.data.objects.new(n + "_Link", cu)
    sc.collection.objects.link(lo)
    cu.materials.append(emis(n + "_LinkGlow", col, 7))

# center: the shared clock
orb = obj("Orb", lambda: bpy.ops.mesh.primitive_uv_sphere_add(radius=0.09, segments=48, ring_count=24), emis("Orb", (0.75, 0.9, 1, 1), 25), (0, 0, 1.55))
smooth(orb)
for k, (rad, tilt, st) in enumerate([(0.2, 70, 8), (0.27, 110, 6), (0.34, 90, 4)]):
    t = obj("OrbRing%d" % k, lambda: bpy.ops.mesh.primitive_torus_add(major_radius=rad, minor_radius=0.004, major_segments=128, minor_segments=12), emis("OrbRing%d" % k, (0.6, 0.85, 1, 1), st), (0, 0, 1.55))
    t.rotation_euler = (math.radians(tilt), math.radians(k * 35), 0)
for k in range(5):
    rad = 0.35 + k * 0.32
    t = obj("Wave%d" % k, lambda: bpy.ops.mesh.primitive_torus_add(major_radius=rad, minor_radius=0.006, major_segments=192, minor_segments=8), emis("Wave%d" % k, (0.4, 0.7, 1, 1), 3.0 * (0.72 ** k)), (0, 0, 0.003))
    t.scale = (1, 1, 0.3)

obj("Floor", lambda: bpy.ops.mesh.primitive_plane_add(size=400), principled("FloorMat", (0.010, 0.012, 0.02, 1), rough=0.38))

random.seed(7)
spk = [emis("Speck%d" % i, c, s) for i, (c, s) in enumerate([((0.4, 0.6, 1, 1), 6), ((1, 0.5, 0.7, 1), 5), ((0.6, 1, 0.8, 1), 5), ((1, 0.8, 0.4, 1), 5)])]
for i in range(90):
    a = random.uniform(-1.3, 1.3)
    dist = random.uniform(5, 11)
    p = (dist * math.sin(a), dist * math.cos(a) + 1.0, random.uniform(0.3, 4.5))
    rad = random.uniform(0.012, 0.035)
    obj("Speck", lambda: bpy.ops.mesh.primitive_ico_sphere_add(radius=rad, subdivisions=2), random.choice(spk), p)

wd = bpy.data.worlds.new("W")
sc.world = wd
wd.use_nodes = True
bg = wd.node_tree.nodes["Background"]
bg.inputs[0].default_value = (0.006, 0.008, 0.018, 1)


def light(name, typ, loc, energy, col, size=1.0):
    ld = bpy.data.lights.new(name, typ)
    ld.energy = energy
    ld.color = col
    if typ == "AREA":
        ld.size = size
    o = bpy.data.objects.new(name, ld)
    sc.collection.objects.link(o)
    o.location = loc
    d = Vector((0, 0, 1.0)) - Vector(loc)
    o.rotation_euler = d.to_track_quat("-Z", "Y").to_euler()


light("Key", "AREA", (-2.5, -3.5, 4.5), 450, (0.85, 0.9, 1), 3)
light("Rim", "AREA", (2.5, 4.5, 5.0), 350, (0.55, 0.45, 1), 4)
light("Top", "AREA", (0, 0, 4.2), 160, (0.8, 0.9, 1), 2.5)
light("OrbLight", "POINT", (0, 0, 1.55), 60, (0.6, 0.85, 1))

cd = bpy.data.cameras.new("Cam")
cd.lens = 30
cam = bpy.data.objects.new("Cam", cd)
sc.collection.objects.link(cam)
cam.location = (0.0, -4.5, 2.85)
tgt = Vector((0, 0.45, 0.9))
cam.rotation_euler = (tgt - cam.location).to_track_quat("-Z", "Y").to_euler()
sc.camera = cam
cd.dof.use_dof = True
cd.dof.focus_distance = (tgt - cam.location).length
cd.dof.aperture_fstop = 4.0

r = sc.render
r.engine = "CYCLES"
r.resolution_x, r.resolution_y = 1920, 1080
r.resolution_percentage = 50 if PREVIEW else 100
cy = sc.cycles
cy.samples = 48 if PREVIEW else 512
cy.use_denoising = True
try:
    prefs = bpy.context.preferences.addons["cycles"].preferences
    prefs.compute_device_type = "OPTIX"
    prefs.get_devices()
    for dv in prefs.devices:
        dv.use = dv.type != "CPU"
    cy.device = "GPU"
except Exception as e:
    print("HERO GPU fail", e)
sc.view_settings.view_transform = "AgX"
try:
    sc.view_settings.look = "AgX - Medium High Contrast"
except TypeError as e:
    print("HERO look", e)
sc.use_nodes = True
nt = sc.node_tree
nt.nodes.clear()
rl = nt.nodes.new("CompositorNodeRLayers")
g = nt.nodes.new("CompositorNodeGlare")
co = nt.nodes.new("CompositorNodeComposite")
g.glare_type = "FOG_GLOW"
g.quality = "HIGH"
for k, v in (("size", 8), ("mix", -0.55)):
    try:
        setattr(g, k, v)
    except Exception as e:
        print("HERO glare", k, e)
nt.links.new(rl.outputs["Image"], g.inputs["Image"])
nt.links.new(g.outputs["Image"], co.inputs["Image"])
r.filepath = OUT
r.image_settings.file_format = "PNG"
bpy.ops.render.render(write_still=True)
if False:
    bpy.ops.wm.save_as_mainfile(filepath=OUT.replace(".png", ".blend"))
print("HERO done", OUT)
