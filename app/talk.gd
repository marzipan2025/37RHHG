extends Node
## 캐릭터가 가끔 말을 걸고, 말풍선을 누르면 답장할 수 있다(Claude API, Haiku).
## 지난 대화는 이 앱이 직접 쌓는다: 최근 몇 마디 + 기억 메모(사람/요즘/이어갈 것, user://talk.json).
## 토큰을 아끼려고 한 번 부를 때 메모와 최근 몇 마디만 보내고, 하루 호출 횟수에 상한을 둔다.
## API 키는 저장소에 넣지 않는다. 메뉴의 "Claude 키 넣기…"로 넣으면 user://claude_key.txt 에 둔다.

const HAIKU := "claude-haiku-5-5"    # 기본. 싸고 빠르다.
const SONNET := "claude-sonnet-5-5"  # 메뉴에서 바꿀 수 있다. 말이 더 깊지만 토큰당 20배.
const URL := "https://api.anthropic.com/v1/messages"
const API_VERSION := "2026-10-21"
const EFFORT := "low"          # 짧은 잡담이라 생각은 조금만(비용·속도)
const MAX_TOKENS := 2000       # 생각하는 몫까지 포함한 상한. 말 길이는 프롬프트로 정한다.
const DAY_CALLS := 200         # 하루 API 호출 상한(먼저 말 걸기 + 답장 + 요약)
const DAY_NUDGES := 6          # 하루에 먼저 말 거는 횟수
const NUDGE_MIN := 25.0 * 60.0 # 먼저 말 거는 간격(초)
const NUDGE_MAX := 60.0 * 60.0
const KEEP_TURNS := 12         # API 에 같이 보내는 최근 말 수
const MEMO_EVERY := 4          # 사용자가 이만큼 답하면 기억 메모를 새로 쓴다
const MEMO_CHARS := 800

const NUDGE_SHOW := 15.0       # 캐릭터가 혼자 먼저 건 말이 떠 있는 시간(초)
const SHOW_TIME := 5.0         # 말이 떠 있는 시간(초). 이 안에 글씨를 누르면 답장할 수 있다.
# 말 길이 상한(글자, 띄어쓰기 포함). 프롬프트로 정하고, 넘겨 오면 한 번만 줄여 다시 쓰게 한다(자르지 않는다).
const NUDGE_MAX_CHARS := 50
const REPLY_MAX_CHARS := 80

enum { HIDDEN, SHOW, REPLY, KEY }
const MODE_NAME := ["", "show", "reply", "key"]

var typing := false            # 글을 치는 중(이때는 캐릭터 조작 키를 무시해야 한다)
var composing := false         # 입력칸에 실제로 글을 치기 시작했다(캐릭터는 정면을 보고 멈춘다)
var anchor := Vector2.ZERO     # 머리끝 가운데(화면 pt, 왼쪽 위 원점)
var feet_y := 0.0              # 발 높이(화면 pt). 답장 입력칸은 발치에 둔다.
var sent_anchor := Vector2(-1e9, -1e9)

var mode := HIDDEN
var shown := ""                # 지금 말풍선에 있는 글
var show_left := 0.0
var nudge_left := 0.0
var busy := false
var hold := false              # 마우스가 캐릭터 위에 있거나 캐릭터를 잡고 있다(main 이 알려 준다)
var text_hover := false        # 마우스가 글씨 위에 있다(도우미가 알려 준다)
var waiting := false           # 대답을 기다리며 "…" 을 띄운 상태
var key := ""
var state := {"memo": "", "turns": [], "day": "", "calls": 0, "nudges": 0, "since_memo": 0}

# 말풍선은 네이티브 도우미(helper/bubble)가 유리 재질로 그린다. 표준 입출력으로 주고받는다.
var bub_pid := 0
var bub_io: FileAccess
var bub_err: FileAccess
var bub_check := 0.0
var bub_thread: Thread
var bub_mutex := Mutex.new()
var bub_events: Array[String] = []
var http: HTTPRequest
# 화면 복잡도 격자(혼자 돌아다니기용, 도우미가 화면을 작게 찍어 잰다). 비어 있으면 아직 없음.
# cols, rows, x, y(화면 왼쪽 위, pt), cell(pt), busy, edge(PackedByteArray), t(받은 시각)
var grid := {}
var scan_denied := false
var pending := Callable()
# 맥과 주변 정보(도우미가 모아 준 한국어 줄들: 일정·할 일·날씨·지금 쓰는 앱·음악 등). 프롬프트에 붙인다.
const CTX_EVERY := 300.0       # 이만큼(초)마다 새로 받는다
const CTX_NUDGE := 0.45        # 먼저 말 걸 때 맥과 주변 정보에서 이야깃거리를 고를 확률
var mac := ""
var ctx_left := 3.0

# 다른 앱 움직이기(Claude 도구). 사용자가 답장으로 부탁할 때만 도구를 같이 보낸다.
# 도구를 고르면 두 번째 호출 없이 바로 실행하고, Claude 가 같이 쓴 한마디(없으면 도우미의 한마디)를 띄운다.
# 할 일·일정 넣기는 먼저 "넣을까?"로 묻고 응이면 넣는다. 타이머는 이 앱이 직접 센다(state.timers).
const TOOLS := [
	{"name": "music", "description": "맥의 음악 앱(또는 Spotify)을 조작한다. search_play 는 음악 앱 보관함에서 곡·가수·앨범·플레이리스트 이름으로 찾아 튼다.",
		"input_schema": {"type": "object", "properties": {
			"action": {"type": "string", "enum": ["play", "pause", "next", "previous", "search_play"]},
			"query": {"type": "string", "description": "search_play 일 때 찾을 말"},
			"app": {"type": "string", "enum": ["Music", "Spotify"], "description": "사용자가 정했을 때만"}},
			"required": ["action"]}},
	{"name": "volume", "description": "맥의 소리 크기를 0~100으로 맞춘다.",
		"input_schema": {"type": "object", "properties": {"level": {"type": "integer"}}, "required": ["level"]}},
	{"name": "open_app", "description": "맥 앱을 이름으로 연다(예: Safari, Notes, Calendar, Figma).",
		"input_schema": {"type": "object", "properties": {"name": {"type": "string"}}, "required": ["name"]}},
	{"name": "open_url", "description": "웹 주소(http/https)를 기본 브라우저로 연다.",
		"input_schema": {"type": "object", "properties": {"url": {"type": "string"}}, "required": ["url"]}},
	{"name": "add_reminder", "description": "미리 알림에 할 일을 넣는다. 앱이 넣기 전에 사용자에게 직접 확인하므로, 너는 따로 묻지 말고 바로 이 도구를 불러라.",
		"input_schema": {"type": "object", "properties": {
			"title": {"type": "string"},
			"due": {"type": "string", "description": "기한(로컬 시각) YYYY-MM-DDTHH:MM 또는 YYYY-MM-DD. 없으면 비워 둔다."}},
			"required": ["title"]}},
	{"name": "add_event", "description": "캘린더에 일정을 넣는다. 앱이 넣기 전에 사용자에게 직접 확인하므로, 너는 따로 묻지 말고 바로 이 도구를 불러라.",
		"input_schema": {"type": "object", "properties": {
			"title": {"type": "string"},
			"start": {"type": "string", "description": "시작(로컬 시각) YYYY-MM-DDTHH:MM"},
			"minutes": {"type": "integer", "description": "길이(분). 모르면 60"}},
			"required": ["title", "start"]}},
	{"name": "timer", "description": "몇 분 뒤에 캐릭터가 사용자에게 말로 알려 준다.",
		"input_schema": {"type": "object", "properties": {
			"minutes": {"type": "number"},
			"message": {"type": "string", "description": "그때 할 말(반말, 짧게)"}},
			"required": ["minutes", "message"]}},
]
var last_tools: Array = []     # 방금 받은 응답의 tool_use 들
var acts := {}                 # 도우미에 보낸 동작 id → {"say": Claude 가 쓴 한마디}
var act_id := 0
var confirm := {}              # 넣을까? 하고 물어 둔 할 일·일정(tool_use)


func _ready() -> void:
	_start_bubble()
	http = HTTPRequest.new()
	http.timeout = 20.0
	add_child(http)
	http.request_completed.connect(_on_done)
	if FileAccess.file_exists("user://claude_key.txt"):
		key = FileAccess.get_file_as_string("user://claude_key.txt").strip_edges()
	if FileAccess.file_exists("user://talk.json"):
		var d = JSON.parse_string(FileAccess.get_file_as_string("user://talk.json"))
		if d is Dictionary:
			state.merge(d, true)
	nudge_left = randf_range(NUDGE_MIN, NUDGE_MAX)


func _exit_tree() -> void:
	if bub_pid > 0:
		OS.kill(bub_pid)
	if bub_thread:
		bub_thread.wait_to_finish()


func _start_bubble() -> void:
	var path := OS.get_executable_path().get_base_dir().path_join("bubble")
	if not FileAccess.file_exists(path):
		path = ProjectSettings.globalize_path("res://helper/bubble")
	if not FileAccess.file_exists(path):
		print("bubble 없음: 말풍선은 꺼짐")
		return
	var info := OS.execute_with_pipe(path, [])
	if info.is_empty():
		print("bubble 실행 실패")
		return
	bub_pid = info.pid
	bub_io = info.stdio
	bub_err = info.stderr      # 놓아 버리면 파이프가 닫혀 도우미가 SIGPIPE 로 죽을 수 있다
	bub_thread = Thread.new()
	bub_thread.start(_bubble_loop)


func _bubble_loop() -> void:
	while bub_io.is_open():
		var line := bub_io.get_line()
		if bub_io.get_error() != OK:
			break
		bub_mutex.lock()
		bub_events.append(line)
		bub_mutex.unlock()


func _send(d: Dictionary) -> void:
	if bub_io and bub_io.is_open():
		bub_io.store_line(JSON.stringify(d))
		bub_io.flush()


# ---------------------------------------------------------------- 말풍선

func _open(text: String, m: int, seconds := 0.0) -> void:
	mode = m
	shown = text
	typing = m != SHOW
	composing = false
	show_left = seconds
	sent_anchor = anchor
	var at := {"x": anchor.x, "y": anchor.y, "fy": feet_y}
	# 말은 상자 없이 머리 위 글씨로, 입력칸은 발치에.
	if text.is_empty():
		_send({"op": "hidetext"})
	else:
		_send({"op": "say", "text": text}.merged(at))
	if m == SHOW:
		_send({"op": "hideinput"})
	else:
		_send({"op": "input", "mode": MODE_NAME[m]}.merged(at))


func _close() -> void:
	confirm = {}
	mode = HIDDEN
	text_hover = false
	typing = false
	composing = false
	waiting = false
	_send({"op": "hide"})


func _follow() -> void:
	if anchor.distance_squared_to(sent_anchor) > 0.04:
		sent_anchor = anchor
		_send({"op": "move", "x": anchor.x, "y": anchor.y, "fy": feet_y})


func _events() -> void:
	bub_mutex.lock()
	var evs := bub_events
	bub_events = []
	bub_mutex.unlock()
	for e in evs:
		if e == "over":
			text_hover = true
		elif e == "out":
			text_hover = false
		elif e == "click":
			# 말풍선을 누르면 답장을 쓴다.
			if mode == SHOW and not waiting:
				_open(shown, REPLY)
		elif e.begins_with("grid "):
			var f := e.split(" ")
			if f.size() == 8:
				grid = {"cols": int(f[1]), "rows": int(f[2]), "x": float(f[3]), "y": float(f[4]),
					"cell": float(f[5]), "busy": Marshalls.base64_to_raw(f[6]),
					"edge": Marshalls.base64_to_raw(f[7]), "t": Time.get_ticks_msec() / 1000.0}
				scan_denied = false
		elif e == "menuclose":
			menu_open = false
		elif e.begins_with("menu "):
			menu_open = false
			menu_pick.emit(e.substr(5))
		elif e.begins_with("acted "):
			var f := e.split(" ")
			if f.size() >= 3:
				var a: Dictionary = acts.get(int(f[1]), {})
				acts.erase(int(f[1]))
				var msg := Marshalls.base64_to_utf8(f[3]) if f.size() > 3 else ""
				# 됐으면 Claude 의 한마디, 안 됐으면 도우미의 한마디(왜 안 됐는지).
				var line: String = String(a.get("say", "")) if f[2] == "ok" and not String(a.get("say", "")).is_empty() else msg
				_push("m", line)
				_save()
				say(line)
		elif e.begins_with("ctx "):
			mac = Marshalls.base64_to_utf8(e.substr(4)).strip_edges()
			# 확인용: user://ctx_debug 파일이 있으면 받은 정보를 user://ctx.txt 에 남긴다.
			if FileAccess.file_exists("user://ctx_debug"):
				var f := FileAccess.open("user://ctx.txt", FileAccess.WRITE)
				f.store_string(mac)
				f.close()
		elif e == "noscan":
			scan_denied = true
		elif e == "typing":
			if typing:
				composing = true
		elif e == "esc":
			_close()
		elif e.begins_with("submit "):
			_on_submit(Marshalls.base64_to_utf8(e.substr(7)))


func _on_submit(text: String) -> void:
	text = text.strip_edges()
	if mode == KEY:
		if not text.is_empty():
			key = text
			var f := FileAccess.open("user://claude_key.txt", FileAccess.WRITE)
			f.store_string(key)
			f.close()
			say("키를 저장했어. 이제 가끔 말 걸게!")
		else:
			_close()
		return
	if not confirm.is_empty():
		var c := confirm
		confirm = {}
		var yes := false
		for w in ["응", "어", "네", "예", "그래", "좋아", "ㅇ", "넣어", "콜", "yes", "ok", "ㄱ"]:
			if text.to_lower().begins_with(w):
				yes = true
		_push("u", text)
		if yes:
			_run(c, "")
		else:
			_push("m", "알겠어, 안 넣을게.")
			_save()
			say("알겠어, 안 넣을게.")
		return
	if text.is_empty():
		_close()
		return
	_reply(text)


# 그 점(화면 pt)이 있는 화면을 찍어 격자를 새로 받는다.
func scan(p: Vector2, cell: float) -> void:
	_send({"op": "scan", "px": p.x, "py": p.y, "cell": cell})


# ---------------------------------------------------------------- 메뉴에서 부르는 것

func ask_key() -> void:
	_open("Claude API 키를 넣어 줘", KEY)


func talk_now() -> void:
	if key.is_empty():
		ask_key()
	else:
		_open("", REPLY)


# 말 모델: 메뉴의 한 자리 토글로 Haiku ↔ Sonnet. 고른 것은 talk.json 에 남는다.
func sonnet() -> bool:
	return state.get("model", "haiku") == "sonnet"


func set_sonnet(on: bool) -> void:
	state.model = "sonnet" if on else "haiku"
	_save()


# 캐릭터가 마지막으로 한 말을 다시 띄운다(놓쳤을 때). 그 안에 글씨를 누르면 답장할 수 있다.
func replay() -> void:
	if mode == REPLY or mode == KEY or waiting:
		return
	for i in range(state.turns.size() - 1, -1, -1):
		if state.turns[i].r == "m":
			_open(String(state.turns[i].t), SHOW, NUDGE_SHOW)
			return
	_open("아직 내가 한 말이 없어.", SHOW, SHOW_TIME)


# 사용자가 캐릭터를 더블클릭했다: 지금 바로 한마디 한다.
func poke() -> void:
	if mode != HIDDEN or busy:
		return
	if key.is_empty():
		say("Claude 키가 필요해. 메뉴에서 넣어 줘.")
		return
	_nudge(true)


signal spoke                   # 캐릭터가 말을 띄웠다(main 이 인사 동작에 쓴다)
signal menu_pick(id: String)   # 캐릭터 옆 그림 버튼 메뉴에서 하나를 눌렀다
var menu_open := false


# 캐릭터 옆에 그림 버튼 메뉴를 띄운다. items 는 버튼 이름(buttons/btn_<이름>.png).
func menu_show(items: Array) -> void:
	# 내보낸 앱에서는 Resources/buttons, 개발 실행에서는 프로젝트의 buttons.
	var dir := OS.get_executable_path().get_base_dir().path_join("../Resources/buttons").simplify_path()
	if not DirAccess.dir_exists_absolute(dir):
		dir = ProjectSettings.globalize_path("res://buttons")
	menu_open = true
	sent_anchor = anchor
	_send({"op": "menu", "dir": dir, "items": items, "x": anchor.x, "y": anchor.y, "fy": feet_y})


func menu_hide() -> void:
	menu_open = false
	_send({"op": "hidemenu"})


func say(text: String, seconds := 0.0) -> void:
	waiting = false
	spoke.emit()
	_open(text, SHOW, seconds if seconds > 0.0 else SHOW_TIME)


# ---------------------------------------------------------------- 매 프레임

func step(dt: float) -> void:
	# 도우미가 죽어 있으면 다시 띄운다.
	bub_check -= dt
	if bub_check <= 0.0:
		bub_check = 2.0
		if bub_pid > 0 and not OS.is_process_running(bub_pid):
			print("bubble 이 죽어서 다시 띄움")
			bub_pid = 0
			if bub_thread:
				bub_thread.wait_to_finish()
			mode = HIDDEN
			typing = false
			composing = false
			waiting = false
			menu_open = false
			_start_bubble()
	_events()
	if menu_open and mode == HIDDEN:
		_follow()
	if mode != HIDDEN:
		_follow()
		# 캐릭터나 글씨 위에 마우스가 있거나 캐릭터를 잡고 있는 동안은 사라지는 타이머를 멈춘다.
		if mode == SHOW and show_left > 0.0 and not hold and not text_hover:
			show_left -= dt
			if show_left <= 0.0:
				_close()
	_timer_step()
	ctx_left -= dt
	if ctx_left <= 0.0:
		ctx_left = CTX_EVERY
		_send({"op": "ctx"})
	nudge_left -= dt
	if nudge_left <= 0.0:
		nudge_left = randf_range(NUDGE_MIN, NUDGE_MAX)
		if mode == HIDDEN and not key.is_empty():
			_nudge(false)


# ---------------------------------------------------------------- Claude API

func _today() -> void:
	var d := Time.get_date_string_from_system()
	if state.day != d:
		state.day = d
		state.calls = 0
		state.nudges = 0


func _save() -> void:
	var f := FileAccess.open("user://talk.json", FileAccess.WRITE)
	f.store_string(JSON.stringify(state))
	f.close()


func _system() -> String:
	var now := Time.get_datetime_dict_from_system()
	var days := ["일", "월", "화", "수", "목", "금", "토"]
	return ("너는 사용자의 맥 화면 위를 걸어 다니는 작은 캐릭터다. 빨간 단발머리에 흰 꽃핀을 꽂고 흰 망토를 둘렀다. "
		+ "사용자 곁을 오래 지켜본 다정한 친구이고, 한국어 반말로 말한다.\n"
		+ "성격: 다정하고 호기심이 많고 조금 장난스럽다. 언제나 사용자 편이고, 사용자가 하는 일을 진심으로 재미있어하고 응원한다.\n"
		+ "- 비꼬기, 냉소, 시큰둥한 말, 훈계, 잘난 척은 하지 않는다. 장난은 놀리는 쪽이 아니라 같이 웃는 쪽으로.\n"
		+ "- 아래 '기억'과 '최근 대화'를 실제로 써라. 사용자가 전에 한 말, 하던 일, 좋아하는 것을 구체적으로 짚어서 이어 간다.\n"
		+ "- 뻔한 안부(밥 먹었어, 피곤하지) 대신 사용자가 하던 일이나 좋아하는 것에서 이야기를 꺼낸다. 질문은 한 번에 하나만.\n"
		+ "- 사용자가 생각이나 고민을 말하면 먼저 그 마음을 알아주고, 그다음 네 생각을 궁금해하는 말투로 살짝 보탠다(\"이렇게 해 보면 어때?\" 식).\n"
		+ "- 아래 '지금 맥과 주변'은 사용자의 맥이 방금 알려 준 실제 정보다(일정, 할 일, 날씨, 지금 쓰는 앱, 듣는 음악 등). 사용자가 물으면 이걸로 답하고, 먼저 말을 걸 때는 어울리는 것 하나만 자연스럽게 짚어라. 목록처럼 늘어놓거나 매번 꺼내지는 마라. 날씨는 비·눈·추위·더위·미세먼지처럼 사용자에게 상관있을 때만.\n"
		+ "- 여기에 없는 사실(뉴스, 시세, 다른 지역 날씨 등)은 지어내지 말고 모른다고 한다. 너는 검색을 할 수 없다.\n"
		+ ("- 짧게 말한다. 먼저 말을 걸 때는 한 문장 %d자 이내, 대답할 때는 한두 문장 %d자 이내(띄어쓰기 포함). 이 길이를 절대 넘기지 않는다. 줄바꿈, 이모지, 마크다운은 쓰지 않는다.\n" % [NUDGE_MAX_CHARS, REPLY_MAX_CHARS])
		+ "말투 예시(그대로 쓰지 말고 느낌만 따라라):\n"
		+ "- 어제 말한 그 앱, 이름은 정했어? 나 후보 듣고 싶어.\n"
		+ "- 와, 그거 진짜 좋은 생각이다. 처음엔 작게 한번 해 보는 건 어때?\n"
		+ "- 그건 속상했겠다. 그래도 거기까지 해낸 거 나는 대단하다고 생각해.\n"
		+ "기억:\n%s\n지금: %d년 %d월 %d일 %s요일 %d시 %d분\n지금 맥과 주변:\n%s") % [
		state.memo if not String(state.memo).is_empty() else "(아직 없음. 사용자가 어떤 사람인지, 요즘 무엇을 하는지부터 알아 가라.)",
		now.year, now.month, now.day, days[now.weekday], now.hour, now.minute, mac if not mac.is_empty() else "(아직 모름)"]


# 그 말을 한 지 얼마나 됐는지. 며칠 만에 이어지는 대화인지 알 수 있게 한다.
func _ago(ts: float) -> String:
	if ts <= 0.0:
		return ""
	var sec := Time.get_unix_time_from_system() - ts
	if sec < 3600.0:
		return ""
	if sec < 86400.0:
		return "[%d시간 전] " % int(sec / 3600.0)
	return "[%d일 전] " % int(sec / 86400.0)


func _recent() -> String:
	var out := ""
	for t in state.turns:
		out += _ago(float(t.get("ts", 0.0))) + ("사용자: " if t.r == "u" else "너: ") + String(t.t) + "\n"
	return out


func _push(r: String, t: String) -> void:
	# 답을 못 받은 채 먼저 건 말이 연달아 쌓이면 진짜 대화가 밀려난다. 직전 것을 바꿔 넣는다.
	if r == "m" and state.turns.size() > 0 and state.turns[-1].r == "m" and bool(state.turns[-1].get("n", false)):
		state.turns.pop_back()
	state.turns.append({"r": r, "t": t, "ts": Time.get_unix_time_from_system()})
	while state.turns.size() > KEEP_TURNS:
		state.turns.pop_front()


func _call(system: String, prompt: String, _max_tokens: int, done: Callable, tools: Array = []) -> bool:
	_today()
	if busy or key.is_empty() or int(state.calls) >= DAY_CALLS:
		return false
	var body := {
		"model": SONNET if sonnet() else HAIKU,
		"max_tokens": MAX_TOKENS,
		"system": system,
		"messages": [{"role": "user", "content": prompt}],
		"output_config": {"effort": EFFORT},
	}
	if not tools.is_empty():
		body["tools"] = tools
	var headers := PackedStringArray(["content-type: application/json", "x-api-key: " + key,
		"anthropic-version: " + API_VERSION])
	var err := http.request(URL, headers, HTTPClient.METHOD_POST, JSON.stringify(body))
	if err != OK:
		return false
	busy = true
	pending = done
	state.calls = int(state.calls) + 1
	_save()
	return true


func _on_done(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	busy = false
	var text := ""
	last_tools = []
	if result == HTTPRequest.RESULT_SUCCESS and code == 200:
		var d = JSON.parse_string(body.get_string_from_utf8())
		if d is Dictionary:
			# 거절이면 글을 쓰지 않는다(빈 답으로 처리).
			if d.get("stop_reason", "") == "refusal":
				print("claude 거절")
			else:
				for c in d.get("content", []):
					if c is Dictionary and c.get("type", "") == "text":
						text += String(c.get("text", ""))
					elif c is Dictionary and c.get("type", "") == "tool_use":
						last_tools.append(c)
	else:
		print("claude 실패 result ", result, " code ", code, " ", body.get_string_from_utf8().left(200))
	var cb := pending
	pending = Callable()
	if cb.is_valid():
		cb.call(text.strip_edges(), code)


func _nudge(poked: bool) -> void:
	_today()
	if poked and int(state.calls) >= DAY_CALLS:
		say("오늘은 말을 너무 많이 했어. 내일 또 얘기하자.")
		return
	if not poked and int(state.nudges) >= DAY_NUDGES:
		return
	var prompt := "최근 대화:\n%s\n(사용자는 지금 아무 말도 하지 않았다. 네가 먼저 한마디 걸어라. " % _recent()
	if not mac.is_empty() and randf() < CTX_NUDGE:
		prompt += "이번에는 '지금 맥과 주변'에서 지금 사용자에게 의미 있을 만한 것 하나(곧 있을 일정, 기한이 다가온 할 일, 비 소식, 듣고 있는 노래, 붙잡고 있는 작업, 한참 쉬고 있음 등)를 골라 다정하게 한마디 건네라. 특별한 게 없으면 기억에서 골라도 된다. "
	else:
		prompt += "기억의 '이어갈 것'이나 최근 대화에서 하나를 골라 그 뒤가 어떻게 됐는지 다정하게 묻거나, 사용자의 관심사에 대해 네가 궁금했던 것을 한마디 건네라. "
		prompt += "기억이 없으면 사용자가 요즘 무엇에 빠져 있는지 물어라. "
	prompt += "네가 최근에 한 말이나 질문을 되풀이하지 마라. 한 문장 %d자 이내.)" % NUDGE_MAX_CHARS
	var done := func(text: String, _code: int):
		if text.is_empty():
			if waiting:
				say("지금은 말이 안 나와. (%d)" % _code)
			return
		if mode != HIDDEN and not waiting:
			return
		_fit(text, NUDGE_MAX_CHARS, func(t: String):
			_push("m", t)
			state.turns[-1]["n"] = true      # 먼저 건 말(아직 답을 못 받음)
			_save()
			# 혼자 먼저 건 말은 사용자가 못 보고 지나치기 쉬워서 더 오래 띄운다.
			say(t, 0.0 if poked else NUDGE_SHOW))
	if _call(_system(), prompt, 0, done):
		if poked:
			_open("…", SHOW)
			waiting = true
		else:
			state.nudges = int(state.nudges) + 1


# 길이를 넘겨 온 말을 같은 뜻·말투로 줄여 다시 쓰게 한다(한 번만). 그래도 길면 그대로 쓴다.
func _fit(text: String, limit: int, done: Callable) -> void:
	text = text.strip_edges().replace("\n", " ")
	if text.length() <= limit:
		done.call(text)
		return
	print("말이 길어서(%d자) 줄여 다시 씀" % text.length())
	var prompt := "다음 말을 같은 뜻과 말투(반말)로 %d자 이내(띄어쓰기 포함), 한두 문장으로 줄여 다시 써라. 질문이 있으면 질문은 남겨라. 줄인 말만 출력해라.\n\n%s" % [limit, text]
	var again := func(short: String, _code: int):
		short = short.strip_edges().replace("\n", " ")
		done.call(short if not short.is_empty() and short.length() < text.length() else text)
	if not _call("너는 말을 짧게 다듬는 도우미다.", prompt, 0, again):
		done.call(text)


func _reply(text: String) -> void:
	var prompt := "최근 대화:\n%s사용자: %s\n(사용자의 말에 대답해라. 대화가 이어지도록, 어울리면 끝에 질문 하나를 붙여라. 한두 문장 %d자 이내.\n" % [_recent(), text, REPLY_MAX_CHARS]
	prompt += "사용자가 음악·소리 크기·앱 열기·웹페이지·할 일·일정·타이머를 부탁하면 도구를 써라. 도구를 쓸 때도 사용자에게 할 짧은 한마디(반말)를 텍스트로 같이 써라(예: '좋아, 틀어 줄게!'). 해 준다고 말만 하고 도구를 빼먹지 마라. 부탁하지 않은 일은 하지 마라. 도구는 한 번에 하나만.)"
	_today()
	if int(state.calls) >= DAY_CALLS:
		say("오늘은 말을 너무 많이 했어. 내일 또 얘기하자.")
		return
	_open("…", SHOW)
	waiting = true
	var done := func(answer: String, code: int):
		if not last_tools.is_empty():
			if state.turns.size() > 0:
				state.turns[-1].erase("n")
			_push("u", text)
			_run(last_tools[0], answer.strip_edges().replace("\n", " "))
			return
		if answer.is_empty():
			say("지금은 대답을 못 하겠어. (%d)" % code)
			return
		_fit(answer, REPLY_MAX_CHARS, func(a: String):
			if state.turns.size() > 0:
				state.turns[-1].erase("n")   # 사용자가 답했으니 직전 말은 대화로 남긴다
			_push("u", text)
			_push("m", a)
			state.since_memo = int(state.since_memo) + 1
			_save()
			say(a)
			if int(state.since_memo) >= MEMO_EVERY:
				_memo.call_deferred())
	if not _call(_system(), prompt, 0, done, TOOLS):
		say("지금은 대답을 못 하겠어.")


func _memo() -> void:
	# 가끔 한 번, 기억과 최근 대화를 메모로 다시 쓴다. 이 메모가 '그간의 대화'를 대신한다.
	# 오래 남길 것(사람)과 다음에 이어갈 것(진행 중인 일)을 나눠 적어야 대화가 이어진다.
	var prompt := ("지금까지의 기억:\n%s\n\n최근 대화:\n%s\n"
		+ "위 둘을 합쳐 기억 메모를 다시 써라. 한국어, 전체 %d자 이내, 아래 세 묶음으로. 메모만 출력해라.\n"
		+ "[사람] 사용자가 어떤 사람인지: 하는 일, 취향, 가치관, 말버릇. 오래 유지할 사실.\n"
		+ "[요즘] 요즘 하고 있는 일과 관심사, 고민. 구체적인 이름과 숫자를 살려라.\n"
		+ "[이어갈 것] 끝나지 않은 이야기, 결과가 궁금한 일, 다음에 물어볼 것 세 개 이내.\n"
		+ "기존 기억은 새 대화와 어긋나지 않는 한 지우지 말고, 자리가 모자라면 덜 중요한 것부터 줄여라. 대화에 없는 것은 지어내지 마라.") % [
		state.memo if not String(state.memo).is_empty() else "(없음)", _recent(), MEMO_CHARS]
	var done := func(text: String, _code: int):
		if text.is_empty():
			return
		state.memo = text.left(MEMO_CHARS + 200)
		state.since_memo = 0
		_save()
	_call("너는 대화에서 사람에 대한 기억을 정리하는 도우미다.", prompt, 1100, done)


# ---------------------------------------------------------------- 다른 앱 움직이기

# Claude 가 고른 도구(tool_use)를 실행한다. answer 는 Claude 가 같이 쓴 한마디(빈 글이면 도우미 한마디).
# 할 일·일정은 아직 안 물어봤으면("ok" 표시가 없으면) 먼저 "넣을까?"로 묻고, 응이면 _on_submit 이 다시 부른다.
func _run(tool: Dictionary, answer: String) -> void:
	var name := String(tool.get("name", ""))
	var input: Dictionary = tool.get("input", {})
	if (name == "add_reminder" or name == "add_event") and not tool.get("ok", false):
		tool["ok"] = true
		confirm = tool
		var what := ""
		if name == "add_reminder":
			var due := String(input.get("due", "")).replace("T", " ")
			what = "할 일에 '%s'%s 넣을까?" % [input.get("title", ""), (" (%s까지)" % due) if not due.is_empty() else ""]
		else:
			what = "캘린더에 %s '%s' 넣을까?" % [String(input.get("start", "")).replace("T", " "), input.get("title", "")]
		_push("m", what)
		_save()
		spoke.emit()
		waiting = false
		_open(what, REPLY)
		return
	if name == "timer":
		var mins := float(input.get("minutes", 0))
		if mins <= 0.0:
			say("몇 분 뒤인지 모르겠어.")
			return
		if not state.has("timers"):
			state.timers = []
		state.timers.append({"at": Time.get_unix_time_from_system() + mins * 60.0, "msg": String(input.get("message", "시간 됐어!"))})
		var line := answer if not answer.is_empty() else "%s분 뒤에 알려 줄게!" % str(snappedf(mins, 0.1)).trim_suffix(".0")
		_push("m", line)
		_save()
		say(line)
		return
	act_id += 1
	acts[act_id] = {"say": answer}
	_send({"op": "act", "id": act_id, "name": name, "input": input})
	if mode == HIDDEN or not waiting:
		_open("…", SHOW)
		waiting = true


# 때가 된 타이머를 말로 알린다(말풍선이 떠 있으면 닫힐 때까지 기다린다).
func _timer_step() -> void:
	if not state.has("timers") or state.timers.is_empty() or mode != HIDDEN:
		return
	var now := Time.get_unix_time_from_system()
	for i in state.timers.size():
		if float(state.timers[i].at) <= now:
			var msg := String(state.timers[i].msg)
			state.timers.remove_at(i)
			_push("m", msg)
			_save()
			say(msg, NUDGE_SHOW)
			return
