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

# 소품 들어 보이기(37FRHG preview ⑩ 책·⑪ 유리병, 2026-11-23). main.gd 가 pose 에 소품 이름(act)과 시작 뒤 초(at)를 넘긴다.
# 소품 점은 정점 색 빨강(책 0, 병 0.5)으로 표시하고 골반에만 1.0 으로 묶는다. 셰이더가 book_m·vial_m 으로 손에 옮긴다.
# 소품이 붙어 있던 로브 자리는 정점 색 초록(책 0, 병 0.5)으로 표시해 들고 있는 동안 허리띠 높이는 갈색, 나머지는 로브 보라로 덮는다.
# 정점 색 알파 = 기본 자세 높이(0.30~0.45 m → 0~1).
# 책(캐릭터 왼쪽 +x): BOOK_MIN~MAX 안에서 로브 보라(색상 0.60~0.79)가 아닌 점. 책 표지 그늘은 색상 0.80~0.90.
const BOOK_MIN := Vector3(0.112, 0.27, -0.07)
const BOOK_MAX := Vector3(0.19, 0.42, 0.115)
const BOOK_UNDER_X := 0.09
# 앞 유리병(캐릭터 오른쪽 -x): 앞·안쪽 병 공 가운데 VIAL_C, 뒤·바깥 병 VIAL_C2. 앞 병만 든다.
# 병 점 = VIAL_R 안이고 뒤 병보다 VIAL_C 에 가까운 점 + 목·코르크(VIAL_NECK_R 원기둥, 높이 VIAL_NECK_Y).
# 두 병이 메시로 붙어 있어서 떼면 맞닿은 쪽이 뚫려 있다 → 두 병 안에 조금 작은 공(VIAL_FILL)을 하나씩 넣어 메운다
# (겉면이 있는 방향은 겉면의 0.85배까지만 → 숨고, 뚫린 쪽에서만 보임. 셰이더가 높이별 병 그라데이션으로 칠함, UV x -1).
# 앞 병 뒤 로브도 움푹 뚫려 있어서 로브 앞면 바로 안쪽에 납작한 판(VIAL_PATCH)을 댄다(로브 보라, UV x -2).
const VIAL_C := Vector3(-0.096, 0.328, 0.090)
const VIAL_C2 := Vector3(-0.131, 0.334, 0.055)
const VIAL_R := 0.036
const VIAL_NECK_R := 0.016
const VIAL_NECK_Y := Vector2(0.345, 0.40)
const VIAL_FILL := Vector2(0.026, 0.027)
const VIAL_PATCH := Vector3(-0.097, 0.328, 0.071)
const VIAL_PATCH_R := Vector2(0.028, 0.034)
# 동작: 손 뻗기 reach → 만지기 pat → 들기 lift → 들고 있기 hold → 돌려놓기 lift → 손 내리기 reach(초).
# 좌표는 몸 기준 cm (바깥, 위, 앞): 바깥은 소품 쪽 손의 바깥. 팔이 짧아(위팔 7.8·아래팔 8.9) 손목은 어깨에서 16.5 안쪽.
#  touch·t_hand·t_palm·t_hint: 만질 때 손목·손가락·손바닥·팔꿈치 쪽, pat_v: 만지는 동안 손목이 떴다 닿는 방향
#  wrist·hand·p_hint: 들 때 손목·손가락·팔꿈치 쪽, palm·f_palm: 손·아래팔 손바닥(기본 앞·-손가락: 손등 쪽으로 젖힘)
#  ofs: 손목 → 소품 가운데, tilt·yaw: 들 때 소품 회전, push: 한 번 더 앞으로(cm), spin·spins: 손목을 축으로 흔들기(도·횟수)
#  lean: 들 때 상체 앞으로, see_*: 만질 때 고개 돌림·숙임·몸 기울임, show_cock: 들고 있을 때 갸우뚱
const PROPS := {
	# ⑩ 책(왼손): 두 번 톡톡 만진 뒤 집어 정면으로 내민다. 손은 책 왼쪽 뒤에 숨는다.
	"book": {"side": 0, "reach": 0.5, "pat": 0.7, "pats": 2.0, "lift": 0.7, "hold": 1.3,
		"touch": Vector3(18.3, 44.5, 2.5), "pat_v": Vector3(1.5, 1.2, 0.0), "t_hint": Vector3(1, 0, -0.5),
		"t_hand": Vector3(0.15, -1, 0.2), "t_palm": Vector3(-1, 0, 0),
		"wrist": Vector3(6.5, 46.0, 9.8), "p_hint": Vector3(1, -0.6, 0), "hand": Vector3(0.0, 0.99, -0.14),
		"ofs": Vector3(-4.5, 3.0, 3.2), "tilt": -8.0, "yaw": -90.0, "push": 1.2, "spin": 0.0, "spins": 0.0, "lean": 4.0,
		"see_look": 22.0, "see_nod": 12.0, "see_side": 4.0, "show_cock": -6.0},
	# ⑪ 앞 유리병(오른손): 병목을 위에서 집어 꺼내 어깨 높이로 들어 대롱대롱 매달아 보이고, 살랑 흔든 뒤 다시 건다. 뒤 병은 남는다.
	"vial": {"side": 1, "reach": 0.5, "pat": 0.35, "pats": 1.0, "lift": 0.6, "hold": 1.6,
		"touch": Vector3(11.0, 43.5, 7.5), "pat_v": Vector3(0.0, -0.8, 0.0), "t_hint": Vector3(1, 0, -0.6),
		"t_hand": Vector3(0.0, -1, 0.15), "t_palm": Vector3(0, 0, -1),
		"wrist": Vector3(17.0, 60.0, 11.0), "p_hint": Vector3(1, -1, -0.3), "hand": Vector3(-0.35, 0.1, 0.93),
		"palm": Vector3(0, -1, 0), "f_palm": Vector3(0, -1, 0),
		"ofs": Vector3(0.0, -5.0, 3.0), "tilt": 0.0, "yaw": 0.0, "push": 0.0, "spin": 14.0, "spins": 2.0, "lean": 0.0,
		"see_look": 24.0, "see_nod": 14.0, "see_side": 4.0, "show_cock": 7.0},
}

var mi_main: MeshInstance3D
var mats: Array = []
var prop_c := {}      # 소품 가운데(메시 좌표 m)
var prop_hb := -1     # 골반 bind 번호
var pr_q := {}
var prop_on := false

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
				mats.append(sm)
	mi_main = mi
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
			_prop_split(a, img, hips, "book", 0.0)
			_prop_split(a, img, hips, "vial", 0.5)
			out.add_surface_from_arrays(mi.mesh.surface_get_primitive_type(sf), a)
			out.surface_set_material(sf, mi.mesh.surface_get_material(sf))
		mi.mesh = out


func _robe(col: Color) -> bool:
	return col.h > 0.6 and col.h < 0.79 and col.s > 0.12


func _sel(name: String, p: Vector3, col: Color) -> bool:
	if name == "book":
		if p.x < BOOK_MIN.x or p.y < BOOK_MIN.y or p.z < BOOK_MIN.z or p.x > BOOK_MAX.x or p.y > BOOK_MAX.y or p.z > BOOK_MAX.z:
			return false
		return not _robe(col)
	if _robe(col) and col.v < 0.45:
		return false
	if p.distance_to(VIAL_C) >= p.distance_to(VIAL_C2):
		return false
	if p.distance_to(VIAL_C) < VIAL_R:
		return true
	return Vector2(p.x - VIAL_C.x, p.z - VIAL_C.z).length() < VIAL_NECK_R and p.y > VIAL_NECK_Y.x and p.y < VIAL_NECK_Y.y


func _under(name: String, p: Vector3) -> bool:
	if name == "book":
		return p.x >= BOOK_UNDER_X and p.x < BOOK_MIN.x and p.y >= BOOK_MIN.y and p.y <= BOOK_MAX.y \
			and p.z >= BOOK_MIN.z and p.z <= BOOK_MAX.z
	return p.distance_to(VIAL_C) < VIAL_R + 0.022 and p.z < VIAL_C.z + 0.01 and p.distance_to(VIAL_C) < p.distance_to(VIAL_C2)


# 소품 하나를 떼어 낸다(tag: 정점 색 빨강·초록 값). 메시가 로브와 이어져 있어서 소품 점·로브 점이 섞인 삼각형은
# 소품 점을 복사해 로브 쪽에 남기고 이웃 로브 점 평균으로 모은다(들어도 늘어나지 않게).
func _prop_split(a: Array, img: Image, hips: int, name: String, tag: float) -> void:
	var v: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
	var nrm: PackedVector3Array = a[Mesh.ARRAY_NORMAL]
	var tan = a[Mesh.ARRAY_TANGENT]
	var uv: PackedVector2Array = a[Mesh.ARRAY_TEX_UV]
	var vc: PackedColorArray = a[Mesh.ARRAY_COLOR]
	var bo = a[Mesh.ARRAY_BONES]
	var we: PackedFloat32Array = a[Mesh.ARRAY_WEIGHTS]
	var idx: PackedInt32Array = a[Mesh.ARRAY_INDEX]
	var per: int = we.size() / v.size()
	var isz := img.get_size()
	var n0 := v.size()
	var mine := PackedByteArray()
	mine.resize(n0)
	for k in n0:
		vc[k].a = clampf((v[k].y - 0.30) / 0.15, 0.0, 1.0)
	var mn := Vector3(9, 9, 9)
	var mx := -mn
	for k in n0:
		if vc[k].r < 0.9:
			continue
		var p := v[k]
		var col := img.get_pixelv(Vector2i(uv[k] * Vector2(isz)).clamp(Vector2i.ZERO, isz - Vector2i.ONE))
		if not _sel(name, p, col):
			continue
		mine[k] = 1
		vc[k] = Color(tag, 1.0, vc[k].b, vc[k].a)
		mn = mn.min(p)
		mx = mx.max(p)
		for c in per:
			bo[k * per + c] = hips if c == 0 else 0
			we[k * per + c] = 1.0 if c == 0 else 0.0
	# 붙어 있던 로브 자리: 진한 점(그늘·끈). 허리띠 갈색은 그대로. 병 뒤 로브는 구멍·그늘투성이라 통째로 덮는다.
	for k in n0:
		if mine[k] == 1 or vc[k].r < 0.9 or not _under(name, v[k]):
			continue
		var col := img.get_pixelv(Vector2i(uv[k] * Vector2(isz)).clamp(Vector2i.ZERO, isz - Vector2i.ONE))
		var belt := col.h > 0.04 and col.h < 0.16 and col.v > 0.18
		var dark := not belt and (col.h > 0.79 or col.h < 0.04 or col.v < 0.2) or (belt and col.v < 0.3)
		if dark or (name == "vial" and not belt):
			vc[k] = Color(vc[k].r, tag, vc[k].b, vc[k].a)
	prop_c[name] = VIAL_C if name == "vial" else (mn + mx) * 0.5
	prop_hb = hips
	var copy := {}
	var acc := {}
	for t in range(0, idx.size(), 3):
		var sb := 0
		for c in 3:
			if idx[t + c] < n0:
				sb += mine[idx[t + c]]
		if sb == 0 or sb == 3:
			continue
		for c in 3:
			var k := idx[t + c]
			if k >= n0 or mine[k] == 0:
				continue
			if not copy.has(k):
				copy[k] = v.size()
				v.append(v[k])
				nrm.append(nrm[k])
				uv.append(uv[k])
				vc.append(Color(1.0, tag, vc[k].b, vc[k].a))
				if tan != null:
					for q in 4:
						tan.append(tan[k * 4 + q])
				for c2 in per:
					bo.append(bo[k * per + c2])
					we.append(we[k * per + c2])
			idx[t + c] = copy[k]
			var ci: int = copy[k]
			if not acc.has(ci):
				acc[ci] = [Vector3.ZERO, 0]
			for c2 in 3:
				if idx[t + c2] < n0 and mine[idx[t + c2]] == 0:
					acc[ci][0] += v[idx[t + c2]]
					acc[ci][1] += 1
	for ci in acc:
		if acc[ci][1] > 0:
			v[ci] = acc[ci][0] / float(acc[ci][1])
	a[Mesh.ARRAY_VERTEX] = v
	a[Mesh.ARRAY_NORMAL] = nrm
	a[Mesh.ARRAY_TEX_UV] = uv
	a[Mesh.ARRAY_COLOR] = vc
	if tan != null:
		a[Mesh.ARRAY_TANGENT] = tan
	a[Mesh.ARRAY_BONES] = bo
	a[Mesh.ARRAY_WEIGHTS] = we
	a[Mesh.ARRAY_INDEX] = idx
	if name == "vial":
		# 두 병 속을 메우는 공(앞 병 공은 앞 병과 같이 움직임)과 앞 병 뒤 로브 구멍을 막는 판.
		for which in 2:
			var cc: Vector3 = VIAL_C if which == 0 else VIAL_C2
			var oc: Vector3 = VIAL_C2 if which == 0 else VIAL_C
			var src := PackedVector3Array()
			for k in n0:
				var p := v[k]
				if p.distance_to(cc) > VIAL_R or p.distance_to(cc) > p.distance_to(oc):
					continue
				var col := img.get_pixelv(Vector2i(uv[k] * Vector2(isz)).clamp(Vector2i.ZERO, isz - Vector2i.ONE))
				if col.v > 0.45 and not (col.h > 0.03 and col.h < 0.2):
					src.append(p)
			_add_ball(a, cc, VIAL_FILL[which], Color(tag if which == 0 else 1.0, 1.0, 0.0), src, hips)
		_add_patch(a, VIAL_PATCH, VIAL_PATCH_R, hips)


# 덧붙이는 점의 공통 값(골반 1.0, 탄젠트, 정점 색 알파 = 높이)
func _push_pt(a: Array, p: Vector3, n: Vector3, uv2: Vector2, col: Color, hips: int, per: int) -> void:
	a[Mesh.ARRAY_VERTEX].append(p)
	a[Mesh.ARRAY_NORMAL].append(n)
	a[Mesh.ARRAY_TEX_UV].append(uv2)
	a[Mesh.ARRAY_COLOR].append(Color(col.r, col.g, col.b, clampf((p.y - 0.30) / 0.15, 0.0, 1.0)))
	if a[Mesh.ARRAY_TANGENT] != null:
		var tg := Vector3.UP.cross(n)
		if tg.length() < 0.01:
			tg = Vector3.RIGHT
		tg = tg.normalized()
		a[Mesh.ARRAY_TANGENT].append_array([tg.x, tg.y, tg.z, 1.0])
	for k in per:
		a[Mesh.ARRAY_BONES].append(hips if k == 0 else 0)
		a[Mesh.ARRAY_WEIGHTS].append(1.0 if k == 0 else 0.0)


# 병 안을 메우는 공. 이 방향 가까이(25° 안)에 병 겉면 점(src)이 있으면 그 0.85배까지만, 없으면 r.
func _add_ball(a: Array, c: Vector3, r: float, col: Color, src: PackedVector3Array, hips: int) -> void:
	var per: int = (a[Mesh.ARRAY_WEIGHTS] as PackedFloat32Array).size() / (a[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	var rings := 12
	var segs := 18
	var base: int = (a[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	for i in rings + 1:
		var th := PI * float(i) / rings
		for j2 in segs + 1:
			var ph := TAU * float(j2) / segs
			var d := Vector3(sin(th) * cos(ph), cos(th), sin(th) * sin(ph))
			var rr := r
			for q in src.size():
				var o := src[q] - c
				if o.normalized().dot(d) > 0.9:
					rr = minf(rr, o.length() * 0.85)
			_push_pt(a, c + d * rr, d, Vector2(-1.0, d.y), col, hips, per)
	var idx: PackedInt32Array = a[Mesh.ARRAY_INDEX]
	for i in rings:
		for j2 in segs:
			var a0 := base + i * (segs + 1) + j2
			var b0 := a0 + segs + 1
			idx.append_array([a0, b0, a0 + 1, a0 + 1, b0, b0 + 1])
	a[Mesh.ARRAY_INDEX] = idx


# 로브 구멍을 막는 납작한 타원 판(앞을 봄).
func _add_patch(a: Array, c: Vector3, rr: Vector2, hips: int) -> void:
	var per: int = (a[Mesh.ARRAY_WEIGHTS] as PackedFloat32Array).size() / (a[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	var segs := 24
	var base: int = (a[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	for i in segs + 1:
		var p := c if i == 0 else c + Vector3(cos(TAU * (i - 1) / segs) * rr.x, sin(TAU * (i - 1) / segs) * rr.y, 0.0)
		_push_pt(a, p, Vector3.BACK, Vector2(-2.0, 0.0), Color(1, 1, 1), hips, per)
	var idx: PackedInt32Array = a[Mesh.ARRAY_INDEX]
	for i in segs:
		idx.append_array([base, base + 1 + i, base + 1 + (i + 1) % segs])
	a[Mesh.ARRAY_INDEX] = idx


func prop_len(name: String) -> float:
	var P: Dictionary = PROPS[name]
	return 2.0 * P.reach + P.pat + 2.0 * P.lift + P.hold


## 들기 전(만지기까지)이면 손을 거두는 데로, 들고 있으면 돌려놓는 데로 건너뛴 시간. 걷기 시작할 때 main.gd 가 쓴다.
func prop_cancel(name: String, at: float) -> float:
	var P: Dictionary = PROPS[name]
	var t2: float = P.reach + P.pat
	var t4: float = t2 + P.lift + P.hold
	var t5: float = t4 + P.lift
	var ph := prop_phase(name, at)
	if at < t2:
		return t5 + P.reach * (1.0 - ph.r)
	if at < t4:
		return t4 + P.lift * (1.0 - ph.k)
	return at


## at(초) → r 손 뻗기, pat 만지기(0~1 들림), k 들기, push 한 번 더 앞으로, spin 흔들기(-1~1)
func prop_phase(name: String, at: float) -> Dictionary:
	var d := {"r": 0.0, "pat": 0.0, "k": 0.0, "push": 0.0, "spin": 0.0}
	if name == "" or at < 0.0 or at > prop_len(name):
		return d
	var P: Dictionary = PROPS[name]
	var t1: float = P.reach
	var t2: float = t1 + P.pat
	var t3: float = t2 + P.lift
	var t4: float = t3 + P.hold
	var t5: float = t4 + P.lift
	d.r = smoothstep(0.0, t1, at) if at < t5 else 1.0 - smoothstep(t5, t5 + P.reach, at)
	if at > t1 and at < t2:
		d.pat = pow(sin(PI * P.pats * (at - t1) / P.pat), 2.0)
	d.k = smoothstep(t2, t3, at) if at < t4 else 1.0 - smoothstep(t4, t5, at)
	if at > t3 - 0.15 and at < t4:
		d.push = sin(PI * clampf((at - t3 + 0.15) / 0.6, 0.0, 1.0))
	if at > t3 and at < t4:
		var u: float = (at - t3) / P.hold
		d.spin = sin(TAU * P.spins * u) * pow(sin(PI * u), 0.5)
	return d


func _seg_q(d0: Vector3, p0: Vector3, d1: Vector3, p1: Vector3) -> Quaternion:
	p0 = (p0 - d0 * d0.dot(p0)).normalized()
	p1 = (p1 - d1 * d1.dot(p1)).normalized()
	return Quaternion(Basis(d1, p1, d1.cross(p1)) * Basis(d0, p0, d0.cross(p0)).inverse())


func _ik(s: Vector3, t: Vector3, l1: float, l2: float, hint: Vector3) -> Array:
	var d := t - s
	var L := clampf(d.length(), absf(l1 - l2) + 0.01, (l1 + l2) * 0.999)
	var n := d.normalized()
	var a := (l1 * l1 + L * L - l2 * l2) / (2.0 * L)
	var h := sqrt(maxf(l1 * l1 - a * a, 0.0))
	var pole := (hint - n * hint.dot(n)).normalized()
	var e := s + n * a + pole * h
	return [(e - s).normalized(), (s + n * L - e).normalized()]


func _arm_set(sk: Skeleton3D, S: String, qa: Quaternion, qf: Quaternion, qh: Quaternion) -> void:
	_rot(sk, S + "Arm", Vector3.UP, 0.0, qa)
	_rot(sk, S + "ForeArm", Vector3.UP, 0.0, qa.inverse() * qf)
	_rot(sk, S + "Hand", Vector3.UP, 0.0, qf.inverse() * qh)


# 소품을 손에 들게 하는 셰이더 값. 손이 만지는 자세·드는 자세일 때 손 기준 소품 자리를 재서 그 사이로 보간하고
# 지금 손에 붙인다(집는·놓는 순간 튀지 않게). 든 소품은 가슴 기준 회전, spin 은 손목을 축으로 앞축 둘레로 흔든다.
func _prop_update(sk: Skeleton3D, name: String, ph: Dictionary, now: Array) -> void:
	var xf := {"book": Transform3D.IDENTITY, "vial": Transform3D.IDENTITY}
	var away := {"book": 0.0, "vial": 0.0}
	if name != "" and ph.r > 0.0 and now.size() > 0:
		away[name] = smoothstep(0.0, 0.2, ph.k)
	if name != "" and ph.k > 0.0 and now.size() > 0 and mi_main != null and mi_main.skin != null:
		var P: Dictionary = PROPS[name]
		var S := "Left" if P.side == 0 else "Right"
		var hb := sk.find_bone("Hips")
		var hn := sk.find_bone(S + "Hand")
		var c0: Vector3 = sk.get_bone_global_rest(hb) * mi_main.skin.get_bind_pose(prop_hb) * (prop_c[name] as Vector3)
		var hips_d := sk.get_bone_global_pose(hb) * sk.get_bone_global_rest(hb).affine_inverse()
		var rest_n := hips_d * Transform3D(Basis(), c0)
		rest_n.basis = rest_n.basis.orthonormalized()
		var s2 := sk.find_bone("Spine02")
		var chest := (sk.get_bone_global_pose(s2).basis * sk.get_bone_global_rest(s2).basis.inverse()).orthonormalized()
		_arm_set(sk, S, pr_q.ta, pr_q.tf, pr_q.th)
		var h_t := sk.get_bone_global_pose(hn)
		h_t.basis = h_t.basis.orthonormalized()
		_arm_set(sk, S, pr_q.pa, pr_q.pf, pr_q.ph)
		var h_p := sk.get_bone_global_pose(hn)
		h_p.basis = h_p.basis.orthonormalized()
		_arm_set(sk, S, now[0], now[1], now[2])
		var h_n := sk.get_bone_global_pose(hn)
		h_n.basis = h_n.basis.orthonormalized()
		var out: Vector3 = now[3]
		var fwd: Vector3 = now[4]
		var sw := Basis(chest * fwd, deg_to_rad(P.spin * ph.spin))
		var o: Vector3 = h_p.origin + sw * (chest * (out * P.ofs.x + Vector3.UP * P.ofs.y + fwd * P.ofs.z))
		var rot := sw * chest * Basis(Vector3.RIGHT, deg_to_rad(P.tilt)) * Basis(Vector3.UP, deg_to_rad(P.yaw))
		var g_c := h_t.affine_inverse() * rest_n
		var g_p := h_p.affine_inverse() * Transform3D(rot, o)
		var cur := h_n * g_c.interpolate_with(g_p, smoothstep(0.0, 1.0, ph.k))
		var sg := sk.global_transform
		xf[name] = sg * cur * rest_n.affine_inverse() * sg.affine_inverse()
	for m in mats:
		m.set_shader_parameter("book_m", Projection(xf.book))
		m.set_shader_parameter("vial_m", Projection(xf.vial))
		m.set_shader_parameter("book_away", away.book)
		m.set_shader_parameter("vial_away", away.vial)


func _rot(sk: Skeleton3D, name: String, axis: Vector3, deg: float, extra := Quaternion.IDENTITY) -> void:
	var b := sk.find_bone(name)
	var g := sk.get_bone_global_rest(b).basis.orthonormalized().get_rotation_quaternion()
	var r := Quaternion(axis.normalized(), deg_to_rad(deg)) * extra
	sk.set_bone_pose_rotation(b, sk.get_bone_rest(b).basis.orthonormalized().get_rotation_quaternion() * (g.inverse() * r * g))


# main.gd _pose 와 같은 값을 받는다. greet·wave·look 은 main.gd 의 인사·두리번 상태.
func pose(sk: Skeleton3D, p: float, w: float, run: float, t: float, j: float, leap: float,
		greet: float, wave: float, look: float, act := "", at := -1.0) -> void:
	var bph := prop_phase(act, at)
	var PP: Dictionary = PROPS[act] if act != "" else {}
	var pr_now := []
	_cock_step(t, w, greet + bph.r, j + leap)
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
		if bph.r > 0.0 and side == PP.side:
			# 소품 쪽 팔: 몸 기준 전역 회전으로 만지기(IK)·들기(IK) 자세를 정하고, 평소 → 만지기 → 들기로 잇는다.
			var out := lat * sgn
			var pa := sk.get_bone_global_rest(sk.find_bone(S + "Arm")).origin
			var pf := sk.get_bone_global_rest(sk.find_bone(S + "ForeArm")).origin
			var phd := sk.get_bone_global_rest(sk.find_bone(S + "Hand")).origin
			var u0 := (pf - pa).normalized()
			var f0 := (phd - pf).normalized()
			var p0 := -up * PALM_SIGN
			var B := func(v: Vector3) -> Vector3: return out * v.x + up * v.y + fwd * v.z
			var wt: Vector3 = B.call(PP.touch + PP.pat_v * bph.pat)
			var ik := _ik(pa, wt, pa.distance_to(pf), pf.distance_to(phd), B.call(PP.t_hint))
			var tp: Vector3 = B.call(PP.t_palm)
			pr_q.ta = _seg_q(u0, p0, ik[0], tp)
			pr_q.tf = _seg_q(f0, p0, ik[1], tp)
			pr_q.th = _seg_q(f0, p0, (B.call(PP.t_hand) as Vector3).normalized(), tp)
			var wp: Vector3 = B.call(PP.wrist) + fwd * PP.push * bph.push
			var ikp := _ik(pa, wp, pa.distance_to(pf), pf.distance_to(phd), B.call(PP.p_hint))
			var eh := (B.call(PP.hand) as Vector3).normalized()
			var hp: Vector3 = B.call(PP.palm) if PP.has("palm") else fwd
			var fp: Vector3 = B.call(PP.f_palm) if PP.has("f_palm") else -eh
			pr_q.pa = _seg_q(u0, p0, ikp[0], fp)
			pr_q.pf = _seg_q(f0, p0, ikp[1], fp)
			pr_q.ph = _seg_q(f0, p0, eh, hp)
			var qf_abs := q_arm * q_fore
			var qa: Quaternion
			var qf: Quaternion
			var qh: Quaternion
			if bph.k > 0.0:
				var kk := smoothstep(0.0, 1.0, bph.k)
				qa = pr_q.ta.slerp(pr_q.pa, kk)
				qf = pr_q.tf.slerp(pr_q.pf, kk)
				qh = pr_q.th.slerp(pr_q.ph, kk)
			else:
				qa = q_arm.slerp(pr_q.ta, bph.r)
				qf = qf_abs.slerp(pr_q.tf, bph.r)
				qh = qf_abs.slerp(pr_q.th, bph.r)
			_arm_set(sk, S, qa, qf, qh)
			pr_now = [qa, qf, qh, out, fwd]
			continue
		_rot(sk, S + "Arm", up, 0.0, q_arm)
		_rot(sk, S + "ForeArm", up, 0.0, q_fore)
		_rot(sk, S + "Hand", up, 0.0)
	var hb := sk.find_bone("Hips")
	_rot(sk, "Hips", up, twist * sin(a0), Quaternion(fwd, deg_to_rad(2.0 * w * cos(a0))))
	var drop := bob * (0.5 + 0.5 * cos(2.0 * a0)) + 6.0 * j
	sk.set_bone_pose_position(hb, sk.get_bone_rest(hb).origin + up * (-drop * unit))
	var bsee: float = bph.r * (1.0 - bph.k)   # 소품을 내려다보는 정도
	var pside: float = (1.0 if PP.side == 0 else -1.0) if act != "" else 0.0   # 소품 쪽(캐릭터 왼쪽 +)
	var plean: float = float(PP.lean) * float(bph.k) + 2.0 * float(bph.push) if act != "" else 0.0
	var pbend: float = float(PP.see_side) * bsee * pside if act != "" else 0.0
	_rot(sk, "Spine02", lat, lean + 1.2 * breath * idle - 6.0 * j + 10.0 * leap + plean,
		Quaternion(fwd, deg_to_rad(-pbend)))
	_rot(sk, "Spine", up, -twist * 1.4 * sin(a0))
	var nod: float = (-2.0 + 1.5 * cos(2.0 * a0)) * w - lean * 0.5 + 1.0 * breath * idle - 2.0 * float(bph.k)
	var pcock := 0.0
	if act != "":
		nod += float(PP.see_nod) * bsee
		look += float(PP.see_look) * bsee * pside
		pcock = float(PP.show_cock) * float(bph.k) * -pside
	var tilt := -2.0 * w * cos(a0) + 2.5 * sin(t * TAU * 0.13) * idle + cock + pcock
	tilt = lerpf(tilt, GREET_TILT, greet)
	var turn := twist * 0.4 * sin(a0) + clampf(look, -LOOK_MAX, LOOK_MAX)
	_rot(sk, "Head", up, turn, Quaternion(lat, deg_to_rad(nod)) * Quaternion(fwd, deg_to_rad(tilt)))
	if bph.r > 0.0 or prop_on:
		_prop_update(sk, act if pr_now.size() > 0 else "", bph, pr_now)   # 끝난 뒤 한 번 더: 셰이더 값을 되돌림
	prop_on = bph.r > 0.0


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
