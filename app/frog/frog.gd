extends RefCounted
# 개구리 마법사 캐릭터(37FRHG 에서 만든 것). 소녀 코드(main.gd 의 _pose·_fix_leg_weights·face.gdshader 등)와
# 따로 둔다. main.gd 는 캐릭터가 개구리일 때 모델 만들기(build)와 자세(pose)만 여기에 맡기고,
# 나머지(창·이동·조명·표정 시간·색 전환)는 소녀와 같은 코드를 쓴다. 그래서 셰이더 값 이름도 소녀와 같다.
# 원본 실험: 37FRHG/preview(main.gd·frog.gdshader), 기록은 37FRHG/CLAUDE.md.

const MODEL := "res://frog/frog_rig.glb"
const SHADER := preload("res://frog/frog.gdshader")
# 모델 키 1.0(모자 끝까지). 소녀(MODEL_H 1.7)보다 SIZE 배 크게(2026-11-21 사용자 요청 125%).
# main.gd 는 말풍선·버튼 메뉴 자리(머리끝)를 잡을 때 SIZE 를 곱한다.
const SIZE := 1.25
const SCALE := 1.7 * SIZE

# 리깅은 로브 전체를 다리 뼈에 거의 1.0으로 묶어 놓아서 그대로 걸으면 로브가 통째로 끌려간다.
#  - LEG_FULL 아래는 다리를 따르고 LEG_NONE 위는 골반(Hips)으로 옮긴다(모델 높이 m).
#  - 다리 뼈 선분에서 _leg_r(높이) 넘게 떨어진 점(로브)은 다리를 ROBE_FOLLOW 만큼만 따른다. 초록 피부는 그대로 다리.
#  - 다리 살로 본 점은 자기 다리 사슬 밖(반대쪽 다리·골반) 무게를 가장 가까운 자기 다리 뼈로 옮긴다.
const LEG_FULL := 0.285
const LEG_NONE := 0.325
const ROBE_FOLLOW := 0.45
# 옆구리 유리병 범위(모델 좌표 m). 정점 색 파랑을 0 으로 표시해 셰이더가 bloom 때 물약 색을 바꾼다.
const POTION_MIN := Vector3(-0.17, 0.285, 0.015)
const POTION_MAX := Vector3(-0.06, 0.38, 0.12)

# 자세(37RHHG _pose 를 옮기고 개구리에 맞춘 것)
const ARM_DOWN := 50.0      # T자 기본 자세에서 팔을 내리는 각도(더 내리면 손이 허리 책에 닿음)
const RUN_KNEE := 52.0      # 달리기 무릎(75면 뒤로 찬 발이 로브 단을 뚫음)
const RUN_ARM_OUT := 10.0   # 달리기 때 팔을 더 벌림(손이 책에 닿아서)
# 인사: 팔이 짧아 쭉 펴면 가리키는 꼴이라 팔꿈치를 굽혀 아래팔을 세우고 팔꿈치를 축으로 흔든다. 손바닥은 정면.
const GREET_TILT := -8.0
const GREET_ARM_DIR := Vector3(0.85, 0.45, 0.2)    # 위팔 (바깥, 위, 앞)
const GREET_FORE_DIR := Vector3(0.5, 0.85, 0.25)   # 아래팔(더 세우면 손이 모자 챙 밑 머리에 닿음)
const GREET_WAVE := 18.0
const PALM_SIGN := 1.0      # 기본 자세 손바닥 방향: 아래
const LOOK_MAX := 30.0
# 갸우뚱: 서 있을 때 가끔 고개를 옆으로 기울인다(소녀에는 없는 개구리 버릇).
const COCK_MAX := 16.0
const COCK_EVERY := Vector2(7.0, 16.0)
const COCK_HOLD := Vector2(1.2, 2.2)

var cock := 0.0
var cock_to := 0.0
var cock_timer := 8.0
var last_t := -1.0


# parent 아래에 모델을 붙이고 {inst, skel, mi, mat} 를 돌려준다.
func build(parent: Node3D) -> Dictionary:
	var inst: Node3D = load(MODEL).instantiate()
	inst.scale = Vector3.ONE * SCALE
	parent.add_child(inst)
	for p in inst.find_children("*", "AnimationPlayer", true, false):
		p.queue_free()
	var sk: Skeleton3D = inst.find_children("*", "Skeleton3D", true, false)[0]
	_fix_legs(inst, sk)
	var mi: MeshInstance3D = null
	var mat: ShaderMaterial = null
	for m in inst.find_children("*", "MeshInstance3D", true, false):
		if mi == null:
			mi = m
		for s in m.mesh.get_surface_count():
			var src: Material = m.mesh.surface_get_material(s)
			if src is BaseMaterial3D:
				var sm := ShaderMaterial.new()
				sm.shader = SHADER
				sm.set_shader_parameter("albedo_tex", src.albedo_texture)
				sm.set_shader_parameter("albedo_col", src.albedo_color)
				sm.set_shader_parameter("unit_scale", 1.0 / SCALE)
				m.set_surface_override_material(s, sm)
				mat = sm
	return {"inst": inst, "skel": sk, "mi": mi, "mat": mat}


func _leg_r(y: float) -> float:
	# 허벅지 5.8cm, 종아리(0.13~0.18m) 6.6cm, 신발(0.10m 아래) 10cm
	return lerpf(lerpf(0.10, 0.066, smoothstep(0.10, 0.13, y)), 0.058, smoothstep(0.18, 0.22, y))


func _seg(p: Vector3, a: Vector3, b: Vector3) -> float:
	var ab := b - a
	var t := clampf((p - a).dot(ab) / ab.length_squared(), 0.0, 1.0)
	return p.distance_to(a + ab * t)


func _fix_legs(n: Node, sk: Skeleton3D) -> void:
	var to_mesh := Transform3D()
	var nd: Node = sk
	while nd != n:
		to_mesh = (nd as Node3D).transform * to_mesh
		nd = nd.get_parent()
	var segs := []
	for sd in ["Left", "Right"]:
		var o := []
		for b in [sd + "UpLeg", sd + "Leg", sd + "Foot", sd + "ToeBase"]:
			o.append(to_mesh * sk.get_bone_global_rest(sk.find_bone(b)).origin)
		segs.append([o[0], o[1]])
		segs.append([o[1], o[2]])
		segs.append([o[2], o[3]])
	for mi in n.find_children("*", "MeshInstance3D", true, false):
		if mi.skin == null:
			continue
		var bind := {}
		for b in mi.skin.get_bind_count():
			var nm: String = mi.skin.get_bind_name(b)
			if nm == "":
				nm = sk.get_bone_name(mi.skin.get_bind_bone(b))
			bind[nm] = b
		var hips: int = bind["Hips"]
		var legs := [int(bind["LeftUpLeg"]), int(bind["RightUpLeg"]), int(bind["LeftLeg"]), int(bind["RightLeg"])]
		var chain := []
		for sd in ["Left", "Right"]:
			chain.append([int(bind[sd + "UpLeg"]), int(bind[sd + "Leg"]), int(bind[sd + "Foot"]), int(bind[sd + "ToeBase"])])
		var out := ArrayMesh.new()
		for sf in mi.mesh.get_surface_count():
			var a: Array = mi.mesh.surface_get_arrays(sf)
			var v: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
			var bo = a[Mesh.ARRAY_BONES]
			var we: PackedFloat32Array = a[Mesh.ARRAY_WEIGHTS]
			var per: int = we.size() / v.size()
			var uv: PackedVector2Array = a[Mesh.ARRAY_TEX_UV]
			var img: Image = (mi.mesh.surface_get_material(sf) as BaseMaterial3D).albedo_texture.get_image()
			if img.is_compressed():
				img.decompress()
			var isz := img.get_size()
			var vc := PackedColorArray()
			vc.resize(v.size())
			for k in v.size():
				var p := v[k]
				var in_potion := p.x > POTION_MIN.x and p.y > POTION_MIN.y and p.z > POTION_MIN.z \
					and p.x < POTION_MAX.x and p.y < POTION_MAX.y and p.z < POTION_MAX.z
				vc[k] = Color(1, 1, 0) if in_potion else Color(1, 1, 1)
				var keep := 1.0 - smoothstep(LEG_FULL, LEG_NONE, p.y)
				var dl := 1e9
				var near := 0
				for si in segs.size():
					var d := _seg(p, segs[si][0], segs[si][1])
					if d < dl:
						dl = d
						near = si
				var col := img.get_pixelv(Vector2i(uv[k] * Vector2(isz)).clamp(Vector2i.ZERO, isz - Vector2i.ONE))
				var skin := col.g > col.r * 1.15 and col.g > col.b * 1.15
				var legness := 1.0 if skin else 1.0 - smoothstep(_leg_r(p.y), _leg_r(p.y) + 0.012, dl)
				keep *= lerpf(ROBE_FOLLOW, 1.0, legness)
				if legness > 0.0 and p.y < LEG_FULL:
					var own: Array = chain[near / 3]
					var tgt: int = own[near % 3]
					var take := 0.0
					var tslot := -1
					for c in per:
						var i := k * per + c
						if not (int(bo[i]) in own) and we[i] > 0.0:
							take += we[i] * legness
							we[i] *= 1.0 - legness
						elif int(bo[i]) == tgt:
							tslot = i
					if take > 0.0:
						if tslot < 0:
							var lo := k * per
							for c in per:
								if we[k * per + c] < we[lo]:
									lo = k * per + c
							take += we[lo]
							bo[lo] = tgt
							we[lo] = 0.0
							tslot = lo
						we[tslot] += take
				if keep >= 1.0:
					continue
				var moved := 0.0
				var hip_slot := -1
				for c in per:
					var i := k * per + c
					if int(bo[i]) in legs:
						moved += we[i] * (1.0 - keep)
						we[i] *= keep
					elif int(bo[i]) == hips and we[i] > 0.0:
						hip_slot = i
				if moved <= 0.0:
					continue
				if hip_slot < 0:
					var lo := k * per
					for c in per:
						if we[k * per + c] < we[lo]:
							lo = k * per + c
					moved += we[lo]
					bo[lo] = hips
					we[lo] = 0.0
					hip_slot = lo
				we[hip_slot] += moved
			a[Mesh.ARRAY_BONES] = bo
			a[Mesh.ARRAY_WEIGHTS] = we
			a[Mesh.ARRAY_COLOR] = vc
			out.add_surface_from_arrays(mi.mesh.surface_get_primitive_type(sf), a)
			out.surface_set_material(sf, mi.mesh.surface_get_material(sf))
		mi.mesh = out


func _rot(sk: Skeleton3D, name: String, axis: Vector3, deg: float, extra := Quaternion.IDENTITY) -> void:
	var b := sk.find_bone(name)
	var g := sk.get_bone_global_rest(b).basis.orthonormalized().get_rotation_quaternion()
	var r := Quaternion(axis.normalized(), deg_to_rad(deg)) * extra
	sk.set_bone_pose_rotation(b, sk.get_bone_rest(b).basis.orthonormalized().get_rotation_quaternion() * (g.inverse() * r * g))


# main.gd _pose 와 같은 값을 받는다. greet·wave·look 은 main.gd 의 인사·두리번 상태.
func pose(sk: Skeleton3D, p: float, w: float, run: float, t: float, j: float, leap: float,
		greet: float, wave: float, look: float) -> void:
	_cock_step(t, w, greet, j + leap)
	var lat := sk.get_bone_global_rest(sk.find_bone("LeftUpLeg")).origin - sk.get_bone_global_rest(sk.find_bone("RightUpLeg")).origin
	lat.y = 0
	lat = lat.normalized()
	var up := Vector3.UP
	var fwd := lat.cross(up)
	var a0 := TAU * p
	var idle := 1.0 - w
	var breath := sin(t * TAU * 0.35)
	var unit := sk.get_bone_global_rest(sk.find_bone("Head")).origin.y / 85.0
	var thigh_a := lerpf(26.0, 40.0, run) * w
	var knee_a := lerpf(42.0, RUN_KNEE, run) * w
	var knee_base := lerpf(3.0, lerpf(4.0, 12.0, run), w)
	var arm_a := lerpf(20.0, 36.0, run) * w
	var fore_base := lerpf(-8.0, lerpf(-14.0, -62.0, run), w)
	var lean := lerpf(1.0, lerpf(3.0, 12.0, run), w)
	var twist := lerpf(5.0, 8.0, run) * w
	var bob := lerpf(1.6, 3.5, run) * w
	for side in 2:
		var S := "Left" if side == 0 else "Right"
		var sgn := 1.0 if side == 0 else -1.0
		var a := a0 + (0.0 if side == 0 else PI)
		var lead := side == 0
		var thigh := thigh_a * sin(a) - 6.0 * w - 40.0 * j + (-48.0 if lead else 34.0) * leap
		var knee := knee_base + knee_a * maxf(0.0, -cos(a)) + 72.0 * j + (18.0 if lead else 70.0) * leap
		_rot(sk, S + "UpLeg", lat, thigh)
		_rot(sk, S + "Leg", lat, knee)
		_rot(sk, S + "Foot", lat, -0.6 * (thigh + knee) - 8.0 * w * maxf(0.0, sin(a - 0.6)) + 18.0 * j)
		var arm := -arm_a * sin(a) + 4.0 * w - 15.0 * j + (25.0 if lead else -70.0) * leap
		var arm_out := (3.0 + 1.5 * breath) * idle + 4.0 * w + RUN_ARM_OUT * run * w + 27.0 * j + 22.0 * leap
		var fore := fore_base - 8.0 * w * maxf(0.0, -sin(a)) - 25.0 * j
		var q_arm := Quaternion(lat, deg_to_rad(arm)) * Quaternion(fwd, deg_to_rad(-(ARM_DOWN - arm_out) * sgn))
		# T자라서 팔꿈치는 lat(비틀기)이 아니라 위 축으로 굽혀야 앞으로 접힌다.
		var q_fore := Quaternion(up, deg_to_rad(fore * sgn))
		if side == 1 and greet > 0.0:
			var pa := sk.get_bone_global_rest(sk.find_bone("RightArm")).origin
			var pf := sk.get_bone_global_rest(sk.find_bone("RightForeArm")).origin
			var ph := sk.get_bone_global_rest(sk.find_bone("RightHand")).origin
			var e := (-lat * GREET_ARM_DIR.x + up * GREET_ARM_DIR.y + fwd * GREET_ARM_DIR.z).normalized()
			var hd := (-lat * GREET_FORE_DIR.x + up * GREET_FORE_DIR.y + fwd * GREET_FORE_DIR.z).normalized()
			hd = hd.rotated(fwd, deg_to_rad(-GREET_WAVE * wave))
			q_arm = q_arm.slerp(Quaternion((pf - pa).normalized(), e), greet)
			# 아래팔은 비틀기까지 정한다: 기본 자세 손바닥(아래)을 앞으로.
			var f0 := (ph - pf).normalized()
			var p0 := (-up * PALM_SIGN - f0 * f0.dot(-up * PALM_SIGN)).normalized()
			var p1 := (fwd - hd * hd.dot(fwd)).normalized()
			var qf := Quaternion(Basis(hd, p1, hd.cross(p1)) * Basis(f0, p0, f0.cross(p0)).inverse())
			q_fore = q_fore.slerp(q_arm.inverse() * qf, greet)
		_rot(sk, S + "Arm", up, 0.0, q_arm)
		_rot(sk, S + "ForeArm", up, 0.0, q_fore)
	var hb := sk.find_bone("Hips")
	_rot(sk, "Hips", up, twist * sin(a0), Quaternion(fwd, deg_to_rad(2.0 * w * cos(a0))))
	var drop := bob * (0.5 + 0.5 * cos(2.0 * a0)) + 6.0 * j
	sk.set_bone_pose_position(hb, sk.get_bone_rest(hb).origin + up * (-drop * unit))
	_rot(sk, "Spine02", lat, lean + 1.2 * breath * idle - 6.0 * j + 10.0 * leap)
	_rot(sk, "Spine", up, -twist * 1.4 * sin(a0))
	var nod := (-2.0 + 1.5 * cos(2.0 * a0)) * w - lean * 0.5 + 1.0 * breath * idle
	var tilt := -2.0 * w * cos(a0) + 2.5 * sin(t * TAU * 0.13) * idle + cock
	tilt = lerpf(tilt, GREET_TILT, greet)
	var turn := twist * 0.4 * sin(a0) + clampf(look, -LOOK_MAX, LOOK_MAX)
	_rot(sk, "Head", up, turn, Quaternion(lat, deg_to_rad(nod)) * Quaternion(fwd, deg_to_rad(tilt)))


# 갸우뚱: 서 있을 때(걷기·인사·점프 없음) COCK_EVERY 초마다 한쪽으로 COCK_HOLD 초 기울였다가 돌아온다.
func _cock_step(t: float, w: float, greet: float, air: float) -> void:
	var dt := clampf(t - last_t, 0.0, 0.1) if last_t >= 0.0 else 0.0
	last_t = t
	var still := w < 0.05 and greet <= 0.0 and air <= 0.0
	cock_timer -= dt
	if not still:
		cock_to = 0.0
		cock_timer = maxf(cock_timer, 2.0)
	elif cock_timer <= 0.0:
		if cock_to == 0.0:
			cock_to = COCK_MAX * randf_range(0.6, 1.0) * (1.0 if randf() < 0.5 else -1.0)
			cock_timer = randf_range(COCK_HOLD.x, COCK_HOLD.y)
		else:
			cock_to = 0.0
			cock_timer = randf_range(COCK_EVERY.x, COCK_EVERY.y)
	cock = lerpf(cock, cock_to, 1.0 - exp(-5.0 * dt))
