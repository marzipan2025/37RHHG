extends Node3D
## 화면 위를 돌아다니는 캐릭터.
## 작은 투명 창 하나에 캐릭터를 그리고, 걸을 때는 창 자체를 움직인다.
## 길이 단위는 pt(포인트). 실제 픽셀 = pt * px_scale.

const WIN_W := 180.0
const WIN_H := 210.0
const FEET_Y := 192.0         # 창 안에서 발이 닿는 높이
const CHAR_H := 120.0         # 화면에 보이는 키
const MODEL_H := 1.7          # 모델 키(월드 단위)
const CAM_PITCH := 10.0       # 살짝 위에서 내려다보는 각도

const WALK_SPEED := 80.0      # pt/s
const RUN_SPEED := 210.0
const ACCEL := 700.0
const WALK_STRIDE := 48.0     # 한 주기(두 걸음)에 나아가는 거리
const RUN_STRIDE := 76.0
const JUMP_H := 44.0
const JUMP_TIME := 0.56

# 클릭을 받는 영역(창 안 pt). 나머지 투명한 곳은 클릭이 아래로 통과한다.
const HIT_RECT := Rect2(46, 20, 88, 178)

var px_scale := 1.0
var win_pos := Vector2.ZERO    # 창 왼쪽 위, 화면 픽셀
var move_dir := Vector2.DOWN
var speed := 0.0               # 입력이 원하는 속도
var anim_speed := 0.0          # 실제로 움직인 속도(벽에 막히면 줄어듦)
var yaw := 0.0
var target_yaw := 0.0
var phase := 0.0
var clock := 0.0
var jump_u := -1.0
var dragging := false
var drag_mouse := Vector2.ZERO
var drag_win := Vector2.ZERO
var popup_menu := RID()

var model: Node3D
var shadow: MeshInstance3D
var skel: Skeleton3D
var bones := {}
var lat := Vector3.RIGHT       # 캐릭터의 왼쪽 방향(골격 공간)
var fwd := Vector3.BACK        # 캐릭터의 앞 방향
var unit := 1.0                # 골격 공간의 1cm
var k := MODEL_H / CHAR_H      # pt → 월드 단위

var snapshot := false


func _ready() -> void:
	snapshot = "--snapshot" in OS.get_cmdline_user_args()
	demo = "--demo" in OS.get_cmdline_user_args()
	_build_scene()
	if snapshot:
		_take_snapshots()
		return
	_setup_window()
	_setup_menu()


# ---------------------------------------------------------------- 장면

func _build_scene() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_CLEAR_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color.WHITE
	env.ambient_light_energy = 0.85
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-40, 25, 0)
	sun.light_energy = 0.45
	add_child(sun)

	model = Node3D.new()
	add_child(model)
	var inst: Node3D = load("res://assets/character.glb").instantiate()
	model.add_child(inst)
	var ap := inst.find_children("*", "AnimationPlayer", true, false)
	for p in ap:
		p.queue_free()
	_matte(inst)
	skel = inst.find_children("*", "Skeleton3D", true, false)[0]
	_cache_bones()

	shadow = MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2(0.75, 0.75)
	shadow.mesh = quad
	shadow.rotation_degrees.x = -90
	shadow.position.y = 0.003
	var grad := Gradient.new()
	grad.set_color(0, Color(0, 0, 0, 0.26))
	grad.set_color(1, Color(0, 0, 0, 0))
	var tex := GradientTexture2D.new()
	tex.gradient = grad
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(1.0, 0.5)
	var sm := StandardMaterial3D.new()
	sm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	sm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	sm.albedo_texture = tex
	shadow.material_override = sm
	add_child(shadow)

	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = WIN_H * k
	var p := deg_to_rad(CAM_PITCH)
	var cam_fwd := Vector3(0, -sin(p), -cos(p))
	var cam_up := Vector3(0, cos(p), -sin(p))
	var target := cam_up * ((FEET_Y - WIN_H * 0.5) * k)
	cam.position = target - cam_fwd * 20.0
	add_child(cam)
	cam.look_at(target, Vector3.UP)


func _matte(n: Node) -> void:
	# Tripo 재질은 머리카락이 번들거려서 무광으로 바꾼다.
	if n is MeshInstance3D:
		for s in n.mesh.get_surface_count():
			var src: Material = n.mesh.surface_get_material(s)
			if src is BaseMaterial3D:
				var m: BaseMaterial3D = src.duplicate()
				m.metallic = 0.0
				m.metallic_texture = null
				m.roughness = 1.0
				m.roughness_texture = null
				m.normal_enabled = false
				n.set_surface_override_material(s, m)
	for c in n.get_children():
		_matte(c)


func _cache_bones() -> void:
	for b in skel.get_bone_count():
		bones[skel.get_bone_name(b)] = {
			"i": b,
			"rl": skel.get_bone_rest(b).basis.orthonormalized().get_rotation_quaternion(),
			"g": skel.get_bone_global_rest(b).basis.orthonormalized().get_rotation_quaternion(),
			"o": skel.get_bone_rest(b).origin,
		}
	var l := skel.get_bone_global_rest(bones["LeftUpLeg"].i).origin
	var r := skel.get_bone_global_rest(bones["RightUpLeg"].i).origin
	lat = l - r
	lat.y = 0
	lat = lat.normalized()
	fwd = lat.cross(Vector3.UP)
	unit = skel.get_bone_global_rest(bones["Head"].i).origin.y / 85.0


# ---------------------------------------------------------------- 창과 메뉴

func _setup_window() -> void:
	var screen := DisplayServer.window_get_current_screen()
	px_scale = DisplayServer.screen_get_scale(screen)
	var win := get_window()
	win.size = Vector2i(roundi(WIN_W * px_scale), roundi(WIN_H * px_scale))
	var hit := PackedVector2Array([
		HIT_RECT.position * px_scale,
		Vector2(HIT_RECT.end.x, HIT_RECT.position.y) * px_scale,
		HIT_RECT.end * px_scale,
		Vector2(HIT_RECT.position.x, HIT_RECT.end.y) * px_scale,
	])
	DisplayServer.window_set_mouse_passthrough(hit)
	_reset_position()
	print("screen ", screen, " scale ", px_scale, " usable ", DisplayServer.screen_get_usable_rect(screen), " window ", win.size)


func _reset_position() -> void:
	var r := DisplayServer.screen_get_usable_rect(DisplayServer.window_get_current_screen())
	win_pos = Vector2(r.position.x + r.size.x * 0.5 - WIN_W * px_scale * 0.5,
		r.end.y - FEET_Y * px_scale - 8.0 * px_scale)
	DisplayServer.window_set_position(Vector2i(win_pos.round()))


func _focus() -> void:
	DisplayServer.window_move_to_foreground()
	get_window().grab_focus()


func _setup_menu() -> void:
	var menu := NativeMenu.create_menu()
	NativeMenu.add_item(menu, "키보드로 조작하기", func(_tag): _focus())
	NativeMenu.add_item(menu, "화면 아래 가운데로", func(_tag): _reset_position())
	NativeMenu.add_separator(menu)
	var hint := NativeMenu.add_item(menu, "방향키·WASD 이동  Shift 달리기  Space 점프", Callable())
	NativeMenu.set_item_disabled(menu, hint, true)
	var hint2 := NativeMenu.add_item(menu, "캐릭터 클릭: 조작  끌기: 옮기기  우클릭: 이 메뉴", Callable())
	NativeMenu.set_item_disabled(menu, hint2, true)
	NativeMenu.add_separator(menu)
	NativeMenu.add_item(menu, "종료", func(_tag): get_tree().quit())
	popup_menu = menu
	var ind := DisplayServer.create_status_indicator(_menu_icon(), "37RHHG", func(_b, _p): pass)
	DisplayServer.status_indicator_set_menu(ind, menu)
	print("status indicator ", ind, " feature ", DisplayServer.has_feature(DisplayServer.FEATURE_STATUS_INDICATOR))


func _menu_icon() -> Texture2D:
	# 빨간 머리에 흰 꽃을 단 작은 얼굴
	var n := 36
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	var hair := Color(0.87, 0.27, 0.32)
	var skin := Color(1.0, 0.9, 0.84)
	for y in n:
		for x in n:
			var p := Vector2(x + 0.5, y + 0.5)
			var c := Color(0, 0, 0, 0)
			var dh := p.distance_to(Vector2(18, 18))
			c = c.blend(Color(hair, clampf(16.0 - dh, 0, 1)))
			var face := Vector2((p.x - 18) / 10.5, (p.y - 22.5) / 9.0).length()
			if p.y > 15:
				c = c.blend(Color(skin, clampf((1.0 - face) * 9.0, 0, 1)))
			for e in [Vector2(14, 23), Vector2(22, 23)]:
				var de := Vector2((p.x - e.x) / 1.6, (p.y - e.y) / 2.4).length()
				c = c.blend(Color(Color(0.35, 0.12, 0.12), clampf((1.0 - de) * 3.0, 0, 1)))
			var fc := Vector2(27, 9)
			var df := 99.0
			for i in 5:
				var a := TAU * i / 5.0 - PI * 0.5
				df = minf(df, p.distance_to(fc + Vector2(cos(a), sin(a)) * 3.2))
			c = c.blend(Color(Color(1, 0.98, 0.92), clampf(2.6 - df, 0, 1)))
			c = c.blend(Color(Color(1, 0.78, 0.25), clampf(1.8 - p.distance_to(fc), 0, 1)))
			img.set_pixel(x, y, c)
	return ImageTexture.create_from_image(img)


# ---------------------------------------------------------------- 입력과 이동

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.physical_keycode == KEY_SPACE and jump_u < 0.0:
			jump_u = 0.0
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
		# 메뉴바 아이콘이 노치나 메뉴바 정리 앱에 가려져도 같은 메뉴를 쓸 수 있게
		NativeMenu.popup(popup_menu, DisplayServer.mouse_get_position())
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		dragging = event.pressed
		drag_mouse = Vector2(DisplayServer.mouse_get_position())
		drag_win = win_pos
	elif event is InputEventMouseMotion:
		# 버튼을 뗀 이벤트를 놓쳐도 끌기가 남지 않도록 실제 버튼 상태를 본다.
		dragging = dragging and (event.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0
		if dragging:
			# 창이 움직이면 창 안 좌표가 흔들리므로 화면 좌표로 계산한다.
			win_pos = drag_win + Vector2(DisplayServer.mouse_get_position()) - drag_mouse
			DisplayServer.window_set_position(Vector2i(win_pos.round()))


func _key(a: Key, b: Key) -> float:
	return 1.0 if Input.is_physical_key_pressed(a) or Input.is_physical_key_pressed(b) or a in demo_keys else 0.0


# 확인용 자동 조작: 실행 인자 -- --demo
const DEMO := [
	[2.5, [KEY_RIGHT]], [1.5, [KEY_RIGHT, KEY_SHIFT]], [0.4, []], [0.8, [KEY_SPACE]],
	[2.5, [KEY_LEFT]], [1.5, [KEY_UP]], [1.5, [KEY_DOWN, KEY_SHIFT]], [1.0, []],
]
var demo := false
var demo_keys: Array = []


func _demo_step() -> void:
	var total := 0.0
	for s in DEMO:
		total += s[0]
	var tt := fmod(clock, total)
	for s in DEMO:
		if tt < s[0]:
			var was_space := KEY_SPACE in demo_keys
			demo_keys = s[1]
			if KEY_SPACE in demo_keys and not was_space and jump_u < 0.0:
				jump_u = 0.0
			return
		tt -= s[0]


func _process(dt: float) -> void:
	if snapshot:
		return
	clock += dt
	if dragging and not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		dragging = false
	if demo:
		_demo_step()
	var d :=Vector2(_key(KEY_RIGHT, KEY_D) - _key(KEY_LEFT, KEY_A),
		_key(KEY_DOWN, KEY_S) - _key(KEY_UP, KEY_W))
	var target_speed := 0.0
	if d != Vector2.ZERO and not dragging:
		move_dir = d.normalized()
		# 옆으로 걸을 때 완전한 옆모습이면 머리카락이 얼굴을 가려서 70도 정도만 돌린다.
		target_yaw = atan2(move_dir.x, move_dir.y + 0.35 * absf(move_dir.x))
		var shift := Input.is_physical_key_pressed(KEY_SHIFT) or KEY_SHIFT in demo_keys
		target_speed = RUN_SPEED if shift else WALK_SPEED
	speed = move_toward(speed, target_speed, ACCEL * dt)

	var before := win_pos
	win_pos += move_dir * speed * px_scale * dt
	var r := Rect2(DisplayServer.screen_get_usable_rect(DisplayServer.window_get_current_screen()))
	win_pos.x = clampf(win_pos.x, r.position.x - HIT_RECT.position.x * px_scale, r.end.x - HIT_RECT.end.x * px_scale)
	win_pos.y = clampf(win_pos.y, r.position.y, r.end.y - FEET_Y * px_scale - 4.0 * px_scale)
	if win_pos != before:
		DisplayServer.window_set_position(Vector2i(win_pos.round()))
	var moved := (win_pos - before).length() / px_scale / maxf(dt, 0.0001)
	anim_speed = lerpf(anim_speed, moved if not dragging else 0.0, 1.0 - exp(-15.0 * dt))

	yaw = lerp_angle(yaw, target_yaw, 1.0 - exp(-10.0 * dt))
	model.rotation.y = yaw

	var j := 0.0
	if jump_u >= 0.0:
		jump_u += dt / JUMP_TIME
		if jump_u >= 1.0:
			jump_u = -1.0
		else:
			j = sin(PI * jump_u)
	var lift := JUMP_H * k * 4.0 * maxf(jump_u, 0.0) * (1.0 - maxf(jump_u, 0.0))
	model.position.y = lift
	shadow.scale = Vector3.ONE * (1.0 - 0.35 * j)

	var w := clampf(anim_speed / WALK_SPEED, 0.0, 1.0)
	var run := clampf((anim_speed - WALK_SPEED) / (RUN_SPEED - WALK_SPEED), 0.0, 1.0)
	phase = fposmod(phase + anim_speed / lerpf(WALK_STRIDE, RUN_STRIDE, run) * dt, 1.0)
	_pose(w, run, phase, clock, j)


# ---------------------------------------------------------------- 동작

func _rot(name: String, axis: Vector3, deg: float, extra := Quaternion.IDENTITY) -> void:
	# 캐릭터 기준 축으로 뼈를 돌린다. 뼈마다 로컬 축이 달라도 같은 식으로 쓸 수 있다.
	var b: Dictionary = bones[name]
	var q := Quaternion(axis, deg_to_rad(deg)) * extra
	skel.set_bone_pose_rotation(b.i, b.rl * (b.g.inverse() * q * b.g))


## w: 걷기 비중(0 대기 ~ 1 걷기), run: 달리기 비중, ph: 걸음 주기(0~1), t: 시간, j: 점프 웅크림(0~1)
func _pose(w: float, run: float, ph: float, t: float, j: float) -> void:
	var a0 := TAU * ph
	var idle := 1.0 - w
	var breath := sin(t * TAU * 0.35)

	var thigh_a := lerpf(26.0, 40.0, run) * w
	var knee_a := lerpf(42.0, 75.0, run) * w
	var knee_base := lerpf(3.0, lerpf(4.0, 12.0, run), w)
	var arm_a := lerpf(20.0, 36.0, run) * w
	var fore_base := lerpf(-8.0, lerpf(-14.0, -62.0, run), w)
	var lean := lerpf(1.0, lerpf(3.0, 12.0, run), w)
	var twist := lerpf(5.0, 8.0, run) * w
	var bob := lerpf(1.6, 3.5, run) * w

	for side in 2:
		var s := "Left" if side == 0 else "Right"
		var out_sign := 1.0 if side == 0 else -1.0
		var a := a0 + (0.0 if side == 0 else PI)
		var thigh := thigh_a * sin(a) - 6.0 * w - 40.0 * j
		var knee := knee_base + knee_a * maxf(0.0, -cos(a)) + 72.0 * j
		var foot := -0.6 * (thigh + knee) - 8.0 * w * maxf(0.0, sin(a - 0.6)) + 18.0 * j
		_rot(s + "UpLeg", lat, thigh)
		_rot(s + "Leg", lat, knee)
		_rot(s + "Foot", lat, foot)
		var arm := -arm_a * sin(a) + 4.0 * w - 30.0 * j
		var arm_out := (3.0 + 1.5 * breath) * idle + 4.0 * w + 55.0 * j
		var fore := fore_base - 8.0 * w * maxf(0.0, -sin(a)) - 25.0 * j
		_rot(s + "Arm", lat, arm, Quaternion(fwd, deg_to_rad(arm_out * out_sign)))
		_rot(s + "ForeArm", lat, fore)

	var hb: Dictionary = bones["Hips"]
	_rot("Hips", Vector3.UP, twist * sin(a0), Quaternion(fwd, deg_to_rad(2.0 * w * cos(a0))))
	var drop := bob * (0.5 + 0.5 * cos(2.0 * a0)) + 6.0 * j
	skel.set_bone_pose_position(hb.i, hb.o + Vector3.UP * (-drop * unit))
	_rot("Spine02", lat, lean + 1.2 * breath * idle - 6.0 * j)
	_rot("Spine", Vector3.UP, -twist * 1.4 * sin(a0))
	var nod := (-2.0 + 1.5 * cos(2.0 * a0)) * w - lean * 0.5 + 1.0 * breath * idle
	var tilt := -2.0 * w * cos(a0) + 2.5 * sin(t * TAU * 0.13) * idle
	_rot("Head", Vector3.UP, twist * 0.4 * sin(a0), Quaternion(lat, deg_to_rad(nod)) * Quaternion(fwd, deg_to_rad(tilt)))


# ---------------------------------------------------------------- 확인용 스냅샷

func _take_snapshots() -> void:
	# godot --path . -- --snapshot : 자세 몇 개를 PNG로 저장하고 끝낸다.
	get_window().size = Vector2i(roundi(WIN_W * 2), roundi(WIN_H * 2))
	var shots := [
		["idle_front", 0.0, 0.0, 0.0, 0.0, 0.0],
		["walk_side_a", PI * 0.5, 1.0, 0.0, 0.0, 0.0],
		["walk_side_b", PI * 0.5, 1.0, 0.0, 0.25, 0.0],
		["walk_front", 0.0, 1.0, 0.0, 0.25, 0.0],
		["run_side_a", PI * 0.5, 1.0, 1.0, 0.0, 0.0],
		["run_side_b", PI * 0.5, 1.0, 1.0, 0.25, 0.0],
		["walk_back", PI, 1.0, 0.0, 0.0, 0.0],
		["jump_front", -0.4, 0.0, 0.0, 0.0, 1.0],
	]
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://snap"))
	for s in shots:
		model.rotation.y = s[1]
		model.position.y = JUMP_H * k * s[5]
		_pose(s[2], s[3], s[4], 0.0, s[5])
		await get_tree().process_frame
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("res://snap/%s.png" % s[0])
	get_tree().quit()
