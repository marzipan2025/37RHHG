extends Node3D
const FILE := "res://p2f_walk.glb"
const N := 24
var mode := "custom"
func _find(n: Node, cls: String) -> Node:
	if n.is_class(cls): return n
	for c in n.get_children():
		var r := _find(c, cls)
		if r: return r
	return null
func _matte(n: Node):
	if n is MeshInstance3D:
		for s in n.mesh.get_surface_count():
			var m: BaseMaterial3D = n.mesh.surface_get_material(s).duplicate()
			m.metallic = 0.0; m.metallic_texture = null; m.roughness = 1.0; m.roughness_texture = null; m.normal_enabled = false
			n.set_surface_override_material(s, m)
	for c in n.get_children(): _matte(c)
func _rot(sk: Skeleton3D, name: String, axis: Vector3, deg: float, extra := Quaternion.IDENTITY):
	var b := sk.find_bone(name)
	var g := sk.get_bone_global_rest(b).basis.orthonormalized().get_rotation_quaternion()
	var r := Quaternion(axis.normalized(), deg_to_rad(deg)) * extra
	sk.set_bone_pose_rotation(b, sk.get_bone_rest(b).basis.orthonormalized().get_rotation_quaternion() * (g.inverse() * r * g))
func pose(sk: Skeleton3D, p: float):
	var lat := (sk.get_bone_global_rest(sk.find_bone("LeftUpLeg")).origin - sk.get_bone_global_rest(sk.find_bone("RightUpLeg")).origin)
	lat.y = 0; lat = lat.normalized()
	var up := Vector3.UP
	var fwd := lat.cross(up)
	var ph := TAU * p
	var unit := sk.get_bone_global_rest(sk.find_bone("Head")).origin.y / 85.0
	for side in 2:
		var S := "Left" if side == 0 else "Right"
		var a := ph + (0.0 if side == 0 else PI)
		var thigh := 26.0 * sin(a)
		var knee := 42.0 * maxf(0.0, -cos(a)) + 4.0
		_rot(sk, S + "UpLeg", lat, thigh - 6.0)
		_rot(sk, S + "Leg", lat, knee)
		_rot(sk, S + "Foot", lat, -0.6 * (thigh - 6.0 + knee) - 8.0 * maxf(0.0, sin(a - 0.6)))
		var arm := -20.0 * sin(a)
		_rot(sk, S + "Arm", lat, arm + 4.0)
		_rot(sk, S + "ForeArm", lat, -14.0 - 8.0 * maxf(0.0, -sin(a)))
	var twist := 5.0 * sin(ph)
	var hb := sk.find_bone("Hips")
	_rot(sk, "Hips", up, twist, Quaternion(fwd, deg_to_rad(2.0 * cos(ph))))
	sk.set_bone_pose_position(hb, sk.get_bone_rest(hb).origin + up * (-1.6 * unit * (0.5 + 0.5 * cos(2.0 * ph))))
	_rot(sk, "Spine02", lat, 3.0)
	_rot(sk, "Spine", up, -twist * 1.4)
	_rot(sk, "Head", up, twist * 0.4, Quaternion(lat, deg_to_rad(-2.0 + 1.5 * cos(2.0 * ph))) * Quaternion(fwd, deg_to_rad(-2.0 * cos(ph))))
func _ready():
	for a in OS.get_cmdline_user_args(): mode = a
	var env := Environment.new(); env.background_mode = Environment.BG_COLOR; env.background_color = Color(0.96,0.96,0.97)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR; env.ambient_light_color = Color.WHITE; env.ambient_light_energy = 0.85
	var we := WorldEnvironment.new(); we.environment = env; add_child(we)
	var sun := DirectionalLight3D.new(); sun.rotation_degrees = Vector3(-40,25,0); sun.light_energy = 0.45; add_child(sun)
	var angles := [-90.0, -30.0]
	var sks := []; var aps := []
	for k in 2:
		var doc := GLTFDocument.new(); var st := GLTFState.new()
		doc.append_from_file(FILE, st)
		var n := doc.generate_scene(st); _matte(n)
		var pivot := Node3D.new(); pivot.position = Vector3((k-0.5)*1.7, 0, 0); pivot.rotation_degrees.y = angles[k]
		pivot.add_child(n); add_child(pivot)
		var ap: AnimationPlayer = _find(n, "AnimationPlayer"); aps.append(ap)
		var sk: Skeleton3D = _find(n, "Skeleton3D"); sks.append(sk)
		if k == 0:
			for nm in ["Hips","Head","headfront","LeftUpLeg","RightUpLeg","LeftArm","RightArm","LeftHand","RightHand","LeftFoot","RightFoot"]:
				print(nm, " ", sk.get_bone_global_rest(sk.find_bone(nm)).origin.snapped(Vector3.ONE*0.1))
			print("skel basis ", sk.global_transform.basis.get_scale(), " anim ", ap.get_animation_list())
	var cam := Camera3D.new(); cam.projection = Camera3D.PROJECTION_ORTHOGONAL; cam.size = 2.0
	cam.position = Vector3(0,0.85,6); add_child(cam)
	var an: String = aps[0].get_animation_list()[0]
	var L: float = aps[0].get_animation(an).length
	var frames := N if mode == "custom" else 50
	for f in frames:
		for k in 2:
			if mode == "custom":
				aps[k].stop(); sks[k].reset_bone_poses(); pose(sks[k], float(f) / N)
			elif mode == "rest":
				aps[k].stop(); sks[k].reset_bone_poses()
			else:
				aps[k].play(an); aps[k].seek(L * f / 50.0, true); aps[k].pause()
		await get_tree().create_timer(0.05).timeout
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("res://gif/%s%02d.png" % [mode, f])
		if mode == "rest": break
	get_tree().quit()
