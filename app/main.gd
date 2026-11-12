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
const FACE_Y := 70.0          # 얼굴 확대 스냅샷의 중심 높이(발에서 pt)

const WALK_SPEED := 80.0      # pt/s
const RUN_SPEED := 210.0
const ACCEL := 700.0
const WALK_STRIDE := 48.0     # 한 주기(두 걸음)에 나아가는 거리
const RUN_STRIDE := 76.0
const JUMP_H := 44.0
const JUMP_TIME := 0.56
const LEAP_H := 58.0          # 창 경계를 넘는 멀리뛰기
const LEAP_TIME := 0.85
const LEAP_SPEED := 170.0

# 클릭을 받는 영역(창 안 pt). 나머지 투명한 곳은 클릭이 아래로 통과한다.
const HIT_RECT := Rect2(46, 20, 88, 178)

var px_scale := 1.0            # 창 크기용 배율 = screen_scale * zoom
var screen_scale := 1.0        # 화면 자체 배율(pt → 화면 픽셀)
const BASE_ZOOM := 160.0 / CHAR_H   # 기본 캐릭터 키 160pt
var zoom := BASE_ZOOM           # 점검용: z 를 누르고 있는 동안만 2배. 나중에 지울 것.
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
var jump_long := false
var jump_cool := 0.0

# 서 있을 때 머리를 좌우로 돌려 두리번거린다(±LOOK_MAX 도).
const LOOK_MAX := 30.0
var look := 0.0                # 지금 머리 좌우 각도(도, +가 캐릭터 왼쪽)
var look_target := 0.0
var look_timer := 1.0

# 혼자 돌아다니기
var wander := false
var wander_idx := -1
var w_walking := false
var w_timer := 0.0
var w_dir := Vector2.RIGHT
var w_run := false
var w_stuck := 0.0

# 다른 앱 창 경계(화면 픽셀). helper/winwatch 가 0.25초마다 알려준다.
var rects: Array[Rect2] = []
var watch_pid := -1
var watch_io: FileAccess
var watch_thread: Thread
var watch_mutex := Mutex.new()
var watch_line := ""
var origin := Vector2.ZERO     # 모든 화면을 합친 영역의 왼쪽 위(pt)

var model: Node3D
var shadow: MeshInstance3D

# 마우스를 광원으로: 빛이 마우스 쪽에서 오고, 가까울수록 음영이 짙다. 형태보다 분위기만.
# 끄려면 MOUSE_LIGHT 를 false 로(예전 고정 조명으로 돌아간다).
const MOUSE_LIGHT := true
const LIGHT_DEPTH := 140.0     # 빛이 화면 앞으로 떠 있는 거리(pt). 클수록 정면광에 가깝다.
const LIGHT_NEAR := 120.0      # 이보다 가까우면 가장 짙게(pt)
const LIGHT_FAR := 900.0       # 이보다 멀면 가장 옅게
# 밝은 쪽 밝기(주변광 + 방향광)는 늘 LIGHT_PEAK 로 같다. 가까울수록 그늘 쪽만 조금 내려간다.
const LIGHT_PEAK := 1.15
const SUN_FAR := 0.06          # 방향광 세기(멀 때 / 가까울 때). 멀면 음영이 거의 없다.
const SUN_NEAR := 0.30
const AMB_TINT := Color(1.0, 0.90, 0.93)   # 그늘이 회색으로 죽지 않게 주변광에 섞는 분홍(가까울 때)
const SUN_TINT := Color(1.0, 0.97, 0.96)
const SHADOW_COL := Color(0.36, 0.12, 0.19, 0.30)   # 발밑 그림자(어두운 장밋빛)
const SHADOW_SHIFT := 0.16     # 발밑 그림자가 빛 반대쪽으로 밀리는 양(월드 단위)
var sun: DirectionalLight3D
var env: Environment
var light_dir := Vector3(0.3, 0.6, 0.74)   # 카메라 기준, 빛이 있는 쪽
var light_near := 0.0
var skel: Skeleton3D
var bones := {}
var lat := Vector3.RIGHT       # 캐릭터의 왼쪽 방향(골격 공간)
var fwd := Vector3.BACK        # 캐릭터의 앞 방향
var unit := 1.0                # 골격 공간의 1cm
var k := MODEL_H / CHAR_H      # pt → 월드 단위
# macOS 는 창을 메뉴바 위로 못 올린다. 그래서 화면 위쪽에서는 창을 멈추고 캐릭터를 창 안에서 올려 그린다.
var lift := 0.0                # 창 안에서 캐릭터를 올려 그리는 양(화면 픽셀)
var cam_base := Vector3.ZERO
var cam_lift_dir := Vector3.UP

var snapshot := false
var cam: Camera3D

# 얼굴 덧그리기(face.gdshader). 서기·걷기는 원래 얼굴.
# 달리기·점프 때는 감은 눈(^ ^)과 벌린 입이 각각 따로, 가끔 잠깐씩만 나온다.
var face_mat: ShaderMaterial
var face_act := 0              # 0 서기·걷기, 1 달리기, 2 점프
var eyes_left := 0.0           # 감은 눈이 남은 시간
var mouth_left := 0.0          # 벌린 입이 남은 시간
var eyes_next := 3.0           # 달리는 중 다음 감은 눈 기회까지
var mouth_next := 3.0
var blink_next := 2.0          # 서 있을 때 다음 깜빡임까지
var blink_left := 0.0          # 깜빡이며 감고 있는 남은 시간


func _ready() -> void:
	snapshot = "--snapshot" in OS.get_cmdline_user_args()
	demo = "--demo" in OS.get_cmdline_user_args()
	_build_scene()
	if snapshot:
		_take_snapshots()
		return
	_setup_window()
	_setup_menu()
	_start_watch()
	var args := OS.get_cmdline_user_args()
	var si := args.find("--screen")
	if si >= 0 and si + 1 < args.size():
		# 확인용: 원하는 화면에서 시작
		DisplayServer.window_set_current_screen(int(args[si + 1]))
		_reset_position()
	if "--wander" in args:
		_toggle_wander()


func _exit_tree() -> void:
	if watch_pid > 0:
		OS.kill(watch_pid)
	if watch_thread:
		watch_thread.wait_to_finish()


# ---------------------------------------------------------------- 다른 앱 창 위치

func _start_watch() -> void:
	var path := OS.get_executable_path().get_base_dir().path_join("winwatch")
	if not FileAccess.file_exists(path):
		path = ProjectSettings.globalize_path("res://helper/winwatch")
	if not FileAccess.file_exists(path):
		print("winwatch 없음: 창 경계 점프는 꺼짐")
		return
	var info := OS.execute_with_pipe(path, [str(OS.get_process_id())])
	if info.is_empty():
		print("winwatch 실행 실패")
		return
	watch_pid = info.pid
	watch_io = info.stdio
	watch_thread = Thread.new()
	watch_thread.start(_watch_loop)


func _watch_loop() -> void:
	while watch_io.is_open():
		var line := watch_io.get_line()
		if watch_io.get_error() != OK:
			break
		watch_mutex.lock()
		watch_line = line
		watch_mutex.unlock()


func _update_rects() -> void:
	watch_mutex.lock()
	var line := watch_line
	watch_line = ""
	watch_mutex.unlock()
	if line.is_empty():
		return
	var parts := line.split("|")
	if parts.size() != 2:
		return
	var o := parts[0].split(",")
	origin = Vector2(float(o[0]), float(o[1]))
	rects.clear()
	for s in parts[1].split(";", false):
		var v := s.split(",")
		if v.size() == 4:
			var p := (Vector2(float(v[0]), float(v[1])) - origin) * screen_scale
			rects.append(Rect2(p, Vector2(float(v[2]), float(v[3])) * screen_scale))


# ---------------------------------------------------------------- 장면

func _build_scene() -> void:
	env = Environment.new()
	env.background_mode = Environment.BG_CLEAR_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color.WHITE
	env.ambient_light_energy = 0.85
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	sun = DirectionalLight3D.new()
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
	grad.set_color(0, SHADOW_COL if MOUSE_LIGHT else Color(0, 0, 0, 0.26))
	grad.set_color(1, Color(SHADOW_COL, 0.0) if MOUSE_LIGHT else Color(0, 0, 0, 0))
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

	cam = Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = WIN_H * k
	var p := deg_to_rad(CAM_PITCH)
	var cam_fwd := Vector3(0, -sin(p), -cos(p))
	var cam_up := Vector3(0, cos(p), -sin(p))
	var target := cam_up * ((FEET_Y - WIN_H * 0.5) * k)
	cam.position = target - cam_fwd * 20.0
	cam_base = cam.position
	cam_lift_dir = cam_up
	add_child(cam)
	cam.look_at(target, Vector3.UP)


# v: 캐릭터 가슴에서 마우스까지(pt, 화면 좌표라 y 는 아래가 +). blend 1 이면 바로 적용.
func _light_set(v: Vector2, blend: float) -> void:
	var d := v.length()
	# 마우스가 아래에 있어도 빛이 턱 밑에서 올라오면 무서워 보여서 아래쪽은 덜 반영한다.
	var want := Vector3(v.x, -v.y if v.y < 0.0 else -v.y * 0.35, maxf(LIGHT_DEPTH, d * 0.45)).normalized()
	light_dir = light_dir.lerp(want, blend).normalized()
	light_near = lerpf(light_near, 1.0 - smoothstep(LIGHT_NEAR, LIGHT_FAR, d), blend)
	var lw := cam.global_basis * light_dir
	sun.look_at_from_position(Vector3.ZERO, -lw, Vector3.UP if absf(lw.y) < 0.98 else Vector3.RIGHT)
	sun.light_energy = lerpf(SUN_FAR, SUN_NEAR, light_near)
	sun.light_color = SUN_TINT
	env.ambient_light_energy = LIGHT_PEAK - sun.light_energy
	env.ambient_light_color = Color.WHITE.lerp(AMB_TINT, light_near)
	# 발밑 그림자는 빛 반대쪽으로 조금 밀린다.
	var off := Vector2(-lw.x, -lw.z) / maxf(lw.y, 0.45) * SHADOW_SHIFT * lerpf(0.3, 1.0, light_near)
	shadow.position.x = off.x
	shadow.position.z = off.y


func _light_step(dt: float) -> void:
	var chest := _feet() - Vector2(0, lift + CHAR_H * 0.55 * px_scale)
	_light_set((Vector2(DisplayServer.mouse_get_position()) - chest) / px_scale, 1.0 - exp(-8.0 * dt))


func _matte(n: Node) -> void:
	# Tripo 재질은 머리카락이 번들거려서 무광으로 바꾼다.
	if n is MeshInstance3D:
		for s in n.mesh.get_surface_count():
			var src: Material = n.mesh.surface_get_material(s)
			if src is BaseMaterial3D:
				# 무광 + 얼굴 덧그리기를 셰이더 하나로 한다.
				var m := ShaderMaterial.new()
				m.shader = load("res://face.gdshader")
				m.set_shader_parameter("albedo_tex", src.albedo_texture)
				m.set_shader_parameter("albedo_col", src.albedo_color)
				n.set_surface_override_material(s, m)
				face_mat = m
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
	screen_scale = DisplayServer.screen_get_scale(screen)
	px_scale = screen_scale * zoom
	_apply_size()
	_reset_position()
	print("screen ", screen, " scale ", px_scale, " usable ", DisplayServer.screen_get_usable_rect(screen), " window ", get_window().size)


func _apply_size() -> void:
	var win := get_window()
	win.size = Vector2i(roundi(WIN_W * px_scale), roundi(WIN_H * px_scale))
	_apply_hit()


func _apply_hit() -> void:
	var a := HIT_RECT.position * px_scale - Vector2(0, lift)
	var b := HIT_RECT.end * px_scale - Vector2(0, lift)
	a.y = maxf(a.y, 0.0)
	DisplayServer.window_set_mouse_passthrough(PackedVector2Array([a, Vector2(b.x, a.y), b, Vector2(a.x, b.y)]))


# 창을 win_pos 에 둔다. 메뉴바 위로 올라가야 하면 창은 맨 위에 두고 모자란 만큼 캐릭터를 올려 그린다.
func _place() -> void:
	var top := _usable().position.y
	var y := maxf(win_pos.y, top)
	var l := minf(y - win_pos.y, (FEET_Y - CHAR_H) * px_scale)
	DisplayServer.window_set_position(Vector2i(roundi(win_pos.x), roundi(y)))
	if absf(l - lift) > 0.01:
		lift = l
		_apply_hit()
	if cam:
		cam.position = cam_base - cam_lift_dir * (lift / px_scale * k)


# 점검용(나중에 지울 것): z 를 누르고 있는 동안만 캐릭터를 2배로. 발 위치는 그대로 둔다.
func _set_zoom(z: float) -> void:
	if z == zoom:
		return
	var feet := _feet()
	zoom = z
	px_scale = screen_scale * zoom
	_apply_size()
	win_pos = feet - Vector2(WIN_W * 0.5, FEET_Y) * px_scale
	_place()


func _reset_position() -> void:
	var r := DisplayServer.screen_get_usable_rect(DisplayServer.window_get_current_screen())
	win_pos = Vector2(r.position.x + r.size.x * 0.5 - WIN_W * px_scale * 0.5,
		r.end.y - FEET_Y * px_scale - 8.0 * px_scale)
	_place()


func _focus() -> void:
	DisplayServer.window_move_to_foreground()
	get_window().grab_focus()


func _setup_menu() -> void:
	var menu := NativeMenu.create_menu()
	popup_menu = menu
	wander_idx = NativeMenu.add_check_item(menu, "혼자 돌아다니기", func(_tag): _toggle_wander())
	NativeMenu.add_separator(menu)
	NativeMenu.add_item(menu, "키보드로 조작하기", func(_tag): _focus())
	NativeMenu.add_item(menu, "화면 아래 가운데로", func(_tag): _reset_position())
	NativeMenu.add_separator(menu)
	NativeMenu.add_item(menu, "종료", func(_tag): get_tree().quit())
	var ind := DisplayServer.create_status_indicator(_menu_icon(), "37RHHG", func(_b, _p): pass)
	DisplayServer.status_indicator_set_menu(ind, menu)
	print("status indicator ", ind, " feature ", DisplayServer.has_feature(DisplayServer.FEATURE_STATUS_INDICATOR))


func _toggle_wander() -> void:
	wander = not wander
	NativeMenu.set_item_checked(popup_menu, wander_idx, wander)
	w_walking = false
	w_timer = 0.4
	print("wander ", wander)


# ---------------------------------------------------------------- 혼자 돌아다니기

func _usable() -> Rect2:
	return Rect2(DisplayServer.screen_get_usable_rect(DisplayServer.window_get_current_screen()))


func _feet() -> Vector2:
	return win_pos + Vector2(WIN_W * 0.5, FEET_Y) * px_scale


func _pick_dir() -> Vector2:
	# 대체로 옆으로, 가끔 위아래로. 화면 가장자리 가까우면 안쪽으로.
	var r := _usable()
	var rel := (_feet() - r.position) / r.size
	var sx := -1.0 if randf() < 0.5 else 1.0
	if rel.x < 0.2:
		sx = 1.0
	elif rel.x > 0.8:
		sx = -1.0
	var ang := randf_range(-0.55, 0.55)
	if rel.y < 0.35:
		ang = absf(ang)
	elif rel.y > 0.9:
		ang = -absf(ang)
	if randf() < 0.15:
		return Vector2(0, 1.0 if rel.y < 0.6 else -1.0)
	return Vector2(cos(ang) * sx, sin(ang))


func _wander_step(dt: float) -> void:
	w_timer -= dt
	if w_timer > 0.0:
		return
	if w_walking and randf() < 0.7:
		# 쉬기. 반쯤은 이쪽을 바라본다.
		w_walking = false
		w_timer = randf_range(1.5, 5.0)
		if randf() < 0.5:
			target_yaw = 0.0
	else:
		w_walking = true
		w_timer = randf_range(2.0, 6.0)
		w_run = randf() < 0.25
		w_dir = _pick_dir()


func _start_jump(long: bool) -> void:
	jump_u = 0.0
	jump_long = long


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
			_start_jump(false)
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
			_place()


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
				_start_jump(false)
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
	_set_zoom(BASE_ZOOM * (2.0 if Input.is_physical_key_pressed(KEY_Z) else 1.0))
	_update_rects()
	var leaping := jump_u >= 0.0 and jump_long
	var d := Vector2(_key(KEY_RIGHT, KEY_D) - _key(KEY_LEFT, KEY_A),
		_key(KEY_DOWN, KEY_S) - _key(KEY_UP, KEY_W))
	var shift := Input.is_physical_key_pressed(KEY_SHIFT) or KEY_SHIFT in demo_keys
	if d == Vector2.ZERO and wander and not dragging:
		_wander_step(dt)
		if w_walking:
			d = w_dir
			shift = w_run
	var target_speed := 0.0
	if leaping:
		# 멀리뛰기 중에는 방향을 바꾸지 않고 앞으로 쭉 나간다.
		target_speed = LEAP_SPEED
	elif d != Vector2.ZERO and not dragging:
		move_dir = d.normalized()
		# 옆으로 걸을 때 완전한 옆모습이면 머리카락이 얼굴을 가려서 70도 정도만 돌린다.
		target_yaw = atan2(move_dir.x, move_dir.y + 0.35 * absf(move_dir.x))
		target_speed = RUN_SPEED if shift else WALK_SPEED
	speed = move_toward(speed, target_speed, ACCEL * 2.0 * dt if leaping else ACCEL * dt)

	# 혼자 돌아다니다 다른 앱 창의 경계를 넘게 되면 멀리뛰기로 넘는다.
	jump_cool -= dt
	if wander and jump_u < 0.0 and jump_cool <= 0.0 and speed > 30.0 and not dragging:
		var feet := _feet()
		var ahead := feet + move_dir * (24.0 + speed * 0.12) * px_scale
		for rc in rects:
			if rc.has_point(feet) != rc.has_point(ahead):
				print("leap at ", (feet / screen_scale + origin).round(), " edge of ", Rect2(rc.position / screen_scale + origin, rc.size / screen_scale))
				_start_jump(true)
				break

	var before := win_pos
	win_pos += move_dir * speed * px_scale * dt
	var r := _usable()
	win_pos.x = clampf(win_pos.x, r.position.x - HIT_RECT.position.x * px_scale, r.end.x - HIT_RECT.end.x * px_scale)
	# 창 위쪽은 점프할 자리로 비어 있으므로, 머리끝이 화면 위(메뉴바 바로 아래)에 닿을 때까지 올라가게 한다.
	win_pos.y = clampf(win_pos.y, r.position.y - (FEET_Y - CHAR_H) * px_scale, r.end.y - FEET_Y * px_scale - 4.0 * px_scale)
	if win_pos != before:
		_place()
	var moved := (win_pos - before).length() / px_scale / maxf(dt, 0.0001)
	anim_speed = lerpf(anim_speed, moved if not dragging else 0.0, 1.0 - exp(-15.0 * dt))

	# 화면 가장자리에 막히면 방향을 바꾼다.
	if wander and w_walking and speed > 30.0 and moved < speed * 0.3:
		w_stuck += dt
		if w_stuck > 0.25:
			w_stuck = 0.0
			w_dir = (-w_dir).rotated(randf_range(-0.6, 0.6))
	else:
		w_stuck = 0.0

	yaw = lerp_angle(yaw, target_yaw, 1.0 - exp(-10.0 * dt))
	model.rotation.y = yaw

	var j := 0.0
	var leap := 0.0
	var jh := JUMP_H
	if jump_u >= 0.0:
		jump_u += dt / (LEAP_TIME if jump_long else JUMP_TIME)
		if jump_u >= 1.0:
			jump_u = -1.0
			if jump_long:
				jump_cool = 1.0
				speed = minf(speed, RUN_SPEED if (w_run and wander) else WALK_SPEED)
		elif jump_long:
			leap = sin(PI * jump_u)
			jh = LEAP_H
		else:
			j = sin(PI * jump_u)
	var u := maxf(jump_u, 0.0)
	model.position.y = jh * k * 4.0 * u * (1.0 - u)
	shadow.scale = Vector3.ONE * (1.0 - 0.4 * maxf(j, leap))

	var air := maxf(j, leap)
	var w := clampf(anim_speed / WALK_SPEED, 0.0, 1.0) * (1.0 - air)
	var run := clampf((anim_speed - WALK_SPEED) / (RUN_SPEED - WALK_SPEED), 0.0, 1.0)
	if jump_u < 0.0:
		phase = fposmod(phase + anim_speed / lerpf(WALK_STRIDE, RUN_STRIDE, run) * dt, 1.0)

	# 두리번거리기: 몇 초마다 새 방향을 고르고 천천히 돌린다. 걸을 때는 앞을 본다.
	look_timer -= dt
	if look_timer <= 0.0:
		look_timer = randf_range(1.2, 3.5)
		look_target = 0.0 if randf() < 0.35 else randf_range(-LOOK_MAX, LOOK_MAX)
	look = lerpf(look, look_target * (1.0 - w), 1.0 - exp(-4.0 * dt))
	if MOUSE_LIGHT:
		_light_step(dt)
	_face_step(dt, 2 if jump_u >= 0.0 else (1 if run > 0.5 else 0), w < 0.15)
	_pose(w, run, phase, clock, j, leap)


# ---------------------------------------------------------------- 표정

# 감은 눈과 벌린 입은 따로 정한다. 서 있을 때는 감은 눈으로 자주 깜빡이고, 서 있거나 걸을 때 16~40초마다 0.6~1.4초 입을 벌린다.
# 달리는 동안: 각자 3~8초마다 한 번씩 기회가 오고, 그때 확률로 0.5~1.3초 동안만 나온다.
# 점프: 뛸 때마다 따로 확률을 굴려 그 점프 동안만 나온다.
const RUN_EYES := 0.25
const RUN_MOUTH := 0.35
const JUMP_EYES := 0.25
const JUMP_MOUTH := 0.3
const IDLE_MOUTH_MIN := 16.0     # 서 있거나 걸을 때 입을 벌리는 간격(초)
const IDLE_MOUTH_MAX := 40.0


func _face_step(dt: float, act: int, idle: bool) -> void:
	eyes_left -= dt
	mouth_left -= dt
	# 서 있을 때는 3.5~8초마다 감은 눈으로 0.06~0.09초 짧게 깜빡인다. 가끔 두 번 연달아.
	# 걸을 때는 3배 드물게(10.5~24초). 달리기·점프 중에는 깜빡이지 않는다.
	blink_left -= dt
	if act == 0:
		blink_next -= dt / (1.0 if idle else 3.0)
		if blink_next <= 0.0:
			blink_left = randf_range(0.06, 0.09)
			blink_next = blink_left + (0.14 if randf() < 0.1 else randf_range(3.5, 8.0))
	else:
		blink_left = 0.0
		blink_next = randf_range(0.8, 2.0)
	if act != face_act:
		if face_act == 2:
			# 점프 표정은 착지하면 끝낸다.
			eyes_left = 0.0
			mouth_left = 0.0
		face_act = act
		if act == 2:
			var dur := LEAP_TIME if jump_long else JUMP_TIME
			if randf() < JUMP_EYES:
				eyes_left = dur
			if randf() < JUMP_MOUTH:
				mouth_left = dur
		elif act == 0:
			eyes_left = 0.0
			mouth_left = 0.0
			mouth_next = randf_range(IDLE_MOUTH_MIN, IDLE_MOUTH_MAX)
	if act == 0:
		# 서 있거나 걸을 때도 가끔 입을 벌린다.
		mouth_next -= dt
		if mouth_next <= 0.0:
			mouth_next = randf_range(IDLE_MOUTH_MIN, IDLE_MOUTH_MAX)
			mouth_left = randf_range(0.6, 1.4)
	if act == 1:
		eyes_next -= dt
		mouth_next -= dt
		if eyes_next <= 0.0:
			eyes_next = randf_range(3.0, 8.0)
			if randf() < RUN_EYES:
				eyes_left = randf_range(0.5, 1.3)
		if mouth_next <= 0.0:
			mouth_next = randf_range(3.0, 8.0)
			if randf() < RUN_MOUTH:
				mouth_left = randf_range(0.5, 1.3)
	_face_set(0.0, 1.0 if (eyes_left > 0.0 or blink_left > 0.0) else 0.0, 0.6 if mouth_left > 0.0 else 0.0)


func _face_set(bl: float, hap: float, mo: float) -> void:
	if face_mat:
		face_mat.set_shader_parameter("blink", bl)
		face_mat.set_shader_parameter("happy", hap)
		face_mat.set_shader_parameter("mouth", mo)


# ---------------------------------------------------------------- 동작

func _rot(name: String, axis: Vector3, deg: float, extra := Quaternion.IDENTITY) -> void:
	# 캐릭터 기준 축으로 뼈를 돌린다. 뼈마다 로컬 축이 달라도 같은 식으로 쓸 수 있다.
	var b: Dictionary = bones[name]
	var q := Quaternion(axis, deg_to_rad(deg)) * extra
	skel.set_bone_pose_rotation(b.i, b.rl * (b.g.inverse() * q * b.g))


## w: 걷기 비중(0 대기 ~ 1 걷기), run: 달리기 비중, ph: 걸음 주기(0~1), t: 시간,
## j: 제자리 점프 웅크림(0~1), leap: 멀리뛰기 다리 벌림(0~1)
func _pose(w: float, run: float, ph: float, t: float, j: float, leap := 0.0) -> void:
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
		var lead := side == 0  # 멀리뛰기에서 앞으로 뻗는 다리
		var thigh := thigh_a * sin(a) - 6.0 * w - 40.0 * j + (-48.0 if lead else 34.0) * leap
		var knee := knee_base + knee_a * maxf(0.0, -cos(a)) + 72.0 * j + (18.0 if lead else 70.0) * leap
		var foot := -0.6 * (thigh + knee) - 8.0 * w * maxf(0.0, sin(a - 0.6)) + 18.0 * j
		_rot(s + "UpLeg", lat, thigh)
		_rot(s + "Leg", lat, knee)
		_rot(s + "Foot", lat, foot)
		var arm := -arm_a * sin(a) + 4.0 * w - 30.0 * j + (25.0 if lead else -70.0) * leap
		var arm_out := (3.0 + 1.5 * breath) * idle + 4.0 * w + 55.0 * j + 22.0 * leap
		var fore := fore_base - 8.0 * w * maxf(0.0, -sin(a)) - 25.0 * j
		_rot(s + "Arm", lat, arm, Quaternion(fwd, deg_to_rad(arm_out * out_sign)))
		_rot(s + "ForeArm", lat, fore)

	var hb: Dictionary = bones["Hips"]
	_rot("Hips", Vector3.UP, twist * sin(a0), Quaternion(fwd, deg_to_rad(2.0 * w * cos(a0))))
	var drop := bob * (0.5 + 0.5 * cos(2.0 * a0)) + 6.0 * j
	skel.set_bone_pose_position(hb.i, hb.o + Vector3.UP * (-drop * unit))
	_rot("Spine02", lat, lean + 1.2 * breath * idle - 6.0 * j + 10.0 * leap)
	_rot("Spine", Vector3.UP, -twist * 1.4 * sin(a0))
	var nod := (-2.0 + 1.5 * cos(2.0 * a0)) * w - lean * 0.5 + 1.0 * breath * idle
	var tilt := -2.0 * w * cos(a0) + 2.5 * sin(t * TAU * 0.13) * idle
	var turn := twist * 0.4 * sin(a0) + clampf(look, -LOOK_MAX, LOOK_MAX)
	_rot("Head", Vector3.UP, turn, Quaternion(lat, deg_to_rad(nod)) * Quaternion(fwd, deg_to_rad(tilt)))
	_face_update()


func _face_update() -> void:
	# 셰이더가 쓰는 머리 좌표계: 원점은 머리 뼈, 축은 캐릭터의 왼쪽·위·앞.
	if face_mat == null:
		return
	var hi: int = bones["Head"].i
	var gp := skel.get_bone_global_pose(hi)
	var rot := gp.basis.orthonormalized() * skel.get_bone_global_rest(hi).basis.orthonormalized().inverse()
	var sk := skel.global_transform
	var b := sk.basis.orthonormalized() * rot
	var frame := Transform3D(Basis(b * lat, b * Vector3.UP, b * fwd), sk * gp.origin)
	face_mat.set_shader_parameter("head_inv", Projection(frame.affine_inverse()))


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
		["leap_side", PI * 0.4, 0.0, 0.0, 0.0, -1.0],
		["look_left", 0.0, 0.0, 0.0, 0.0, 0.0, LOOK_MAX],
		["look_right", 0.0, 0.0, 0.0, 0.0, 0.0, -LOOK_MAX],
	]
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://snap"))
	for s in shots:
		model.rotation.y = s[1]
		model.position.y = JUMP_H * k * absf(s[5])
		look = s[6] if s.size() > 6 else 0.0
		if s[5] < 0.0:
			_pose(s[2], s[3], s[4], 0.0, 0.0, 1.0)
		else:
			_pose(s[2], s[3], s[4], 0.0, s[5])
		await get_tree().process_frame
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("res://snap/%s.png" % s[0])
	# 얼굴 확대: 좌표 격자(debug)와 표정 몇 개
	model.rotation.y = 0.0
	model.position.y = 0.0
	look = 0.0
	_pose(0.0, 0.0, 0.0, 0.0, 0.0)
	var full := cam.size
	cam.size = 46.0 * k
	cam.position += Vector3.UP * (FACE_Y - (FEET_Y - WIN_H * 0.5)) * k
	var faces := [
		["face_idle", 0.0, 0.0, 0.0, false],
		["face_run", 0.0, 0.0, 0.6, false],
		["face_jump", 0.0, 1.0, 0.6, false],
		["face_eyes_only", 0.0, 1.0, 0.0, false],
		["face_grid", 0.0, 1.0, 0.6, true],
	]
	for f in faces:
		face_mat.set_shader_parameter("debug", f[4])
		_face_set(f[1], f[2], f[3])
		await get_tree().process_frame
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("res://snap/%s.png" % f[0])
	# 마우스 조명: 마우스 위치(가슴 기준 pt)별 전신과 얼굴
	var lights := [["l_near_left", Vector2(-140, -60)], ["l_near_right", Vector2(140, -60)], ["l_top", Vector2(20, -220)],
		["l_below", Vector2(60, 200)], ["l_far", Vector2(-1200, -300)], ["l_on", Vector2(0, 0)]]
	face_mat.set_shader_parameter("debug", false)
	_face_set(0.0, 0.0, 0.0)
	for l in lights:
		_light_set(l[1], 1.0)
		await get_tree().process_frame
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("res://snap/face_%s.png" % l[0])
	cam.size = full
	cam.position = cam_base
	for l in lights:
		_light_set(l[1], 1.0)
		await get_tree().process_frame
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("res://snap/body_%s.png" % l[0])
	get_tree().quit()
