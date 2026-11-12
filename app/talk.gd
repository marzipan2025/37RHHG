extends Node
## 캐릭터가 가끔 말을 걸고, 말풍선을 누르면 답장할 수 있다(Gemini API 무료 등급).
## 지난 대화는 이 앱이 직접 쌓는다: 최근 몇 마디 + 기억 메모(사람/요즘/이어갈 것, user://talk.json).
## 토큰을 아끼려고 한 번 부를 때 메모와 최근 몇 마디만 보내고, 하루 호출 횟수에 상한을 둔다.
## API 키는 저장소에 넣지 않는다. 메뉴의 "Gemini 키 넣기…"로 넣으면 user://gemini_key.txt 에 둔다.

const MODEL := "gemini-flash-lite-latest"
const URL := "https://generativelanguage.googleapis.com/v1beta/models/%s:generateContent"
const DAY_CALLS := 24          # 하루 API 호출 상한(먼저 말 걸기 + 답장 + 요약)
const DAY_NUDGES := 6          # 하루에 먼저 말 거는 횟수
const NUDGE_MIN := 25.0 * 60.0 # 먼저 말 거는 간격(초)
const NUDGE_MAX := 60.0 * 60.0
const KEEP_TURNS := 12         # API 에 같이 보내는 최근 말 수
const MEMO_EVERY := 4          # 사용자가 이만큼 답하면 기억 메모를 새로 쓴다
const MEMO_CHARS := 800
const OUT_TOKENS := 320

const NUDGE_SHOW := 15.0       # 캐릭터가 혼자 먼저 건 말이 떠 있는 시간(초)
const SHOW_TIME := 5.0         # 말이 떠 있는 시간(초). 이 안에 글씨를 누르면 답장할 수 있다.

enum { HIDDEN, SHOW, REPLY, KEY }
const MODE_NAME := ["", "show", "reply", "key"]

var typing := false            # 글을 치는 중(이때는 캐릭터 조작 키를 무시해야 한다)
var anchor := Vector2.ZERO     # 머리끝 가운데(화면 pt, 왼쪽 위 원점)
var feet_y := 0.0              # 발 높이(화면 pt). 답장 입력칸은 발치에 둔다.
var sent_anchor := Vector2(-1e9, -1e9)

var mode := HIDDEN
var shown := ""                # 지금 말풍선에 있는 글
var show_left := 0.0
var nudge_left := 0.0
var busy := false
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
var pending := Callable()


func _ready() -> void:
	_start_bubble()
	http = HTTPRequest.new()
	http.timeout = 20.0
	add_child(http)
	http.request_completed.connect(_on_done)
	if FileAccess.file_exists("user://gemini_key.txt"):
		key = FileAccess.get_file_as_string("user://gemini_key.txt").strip_edges()
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
	mode = HIDDEN
	typing = false
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
		if e == "click":
			# 말풍선을 누르면 답장을 쓴다.
			if mode == SHOW and not waiting:
				_open(shown, REPLY)
		elif e == "esc":
			_close()
		elif e.begins_with("submit "):
			_on_submit(Marshalls.base64_to_utf8(e.substr(7)))


func _on_submit(text: String) -> void:
	text = text.strip_edges()
	if mode == KEY:
		if not text.is_empty():
			key = text
			var f := FileAccess.open("user://gemini_key.txt", FileAccess.WRITE)
			f.store_string(key)
			f.close()
			say("키를 저장했어. 이제 가끔 말 걸게!")
		else:
			_close()
		return
	if text.is_empty():
		_close()
		return
	_reply(text)


# ---------------------------------------------------------------- 메뉴에서 부르는 것

func ask_key() -> void:
	_open("Gemini 키를 넣어 줘", KEY)


func talk_now() -> void:
	if key.is_empty():
		ask_key()
	else:
		_open("", REPLY)


# 사용자가 캐릭터를 건드렸다(마우스 지그재그): 지금 바로 한마디 한다.
func poke() -> void:
	if mode != HIDDEN or busy:
		return
	if key.is_empty():
		say("Gemini 키가 필요해. 메뉴에서 넣어 줘.")
		return
	_nudge(true)


func say(text: String, seconds := 0.0) -> void:
	waiting = false
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
			waiting = false
			_start_bubble()
	_events()
	if mode != HIDDEN:
		_follow()
		if mode == SHOW and show_left > 0.0:
			show_left -= dt
			if show_left <= 0.0:
				_close()
	nudge_left -= dt
	if nudge_left <= 0.0:
		nudge_left = randf_range(NUDGE_MIN, NUDGE_MAX)
		if mode == HIDDEN and not key.is_empty():
			_nudge(false)


# ---------------------------------------------------------------- Gemini

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
	return ("너는 사용자의 맥 화면 위를 걸어 다니는 작은 캐릭터이고, 사용자를 오래 지켜본 친한 친구다. 한국어 반말로 말한다.\n"
		+ "- 아래 '기억'과 '최근 대화'를 실제로 써라. 사용자가 전에 한 말, 하던 일, 좋아하는 것을 구체적으로 짚어서 이어 간다.\n"
		+ "- 뻔한 안부(날씨, 밥, 피곤하지)는 피한다. 사용자의 일과 생각에 진짜로 궁금해하고, 한 번에 질문은 하나만 한다.\n"
		+ "- 사용자가 생각이나 고민을 말하면 맞장구만 치지 말고 네 의견이나 다른 시각을 짧게 보탠다.\n"
		+ "- 너는 화면 밖 세상을 볼 수 없다. 날씨·뉴스·시세처럼 모르는 사실은 지어내지 말고 모른다고 한다.\n"
		+ "- 먼저 말을 걸 때는 한두 문장 70자 이내. 질문에 답할 때는 필요하면 세 문장 140자까지. 이모지와 마크다운은 쓰지 않는다.\n"
		+ "기억:\n%s\n지금: %d월 %d일 %s요일 %d시") % [
		state.memo if not String(state.memo).is_empty() else "(아직 없음. 사용자가 어떤 사람인지, 요즘 무엇을 하는지부터 알아 가라.)",
		now.month, now.day, days[now.weekday], now.hour]


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


func _call(system: String, prompt: String, max_tokens: int, done: Callable) -> bool:
	_today()
	if busy or key.is_empty() or int(state.calls) >= DAY_CALLS:
		return false
	var body := {
		"system_instruction": {"parts": [{"text": system}]},
		"contents": [{"role": "user", "parts": [{"text": prompt}]}],
		"generationConfig": {"maxOutputTokens": max_tokens, "temperature": 1.0},
	}
	var err := http.request(URL % MODEL, PackedStringArray(["Content-Type: application/json", "x-goog-api-key: " + key]),
		HTTPClient.METHOD_POST, JSON.stringify(body))
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
	if result == HTTPRequest.RESULT_SUCCESS and code == 200:
		var d = JSON.parse_string(body.get_string_from_utf8())
		if d is Dictionary and d.get("candidates", []).size() > 0:
			for p in d.candidates[0].get("content", {}).get("parts", []):
				text += String(p.get("text", ""))
	else:
		print("gemini 실패 result ", result, " code ", code, " ", body.get_string_from_utf8().left(200))
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
	prompt += "기억의 '이어갈 것'이나 최근 대화에서 하나를 골라 그 뒤가 어떻게 됐는지 묻거나, 사용자의 관심사에 대해 네 생각을 한마디 던져라. "
	prompt += "기억이 없으면 사용자가 요즘 무엇에 빠져 있는지 물어라. 네가 최근에 한 말이나 질문을 되풀이하지 마라.)"
	var done := func(text: String, _code: int):
		if text.is_empty():
			if waiting:
				say("지금은 말이 안 나와. (%d)" % _code)
			return
		if mode != HIDDEN and not waiting:
			return
		_push("m", text)
		state.turns[-1]["n"] = true      # 먼저 건 말(아직 답을 못 받음)
		_save()
		# 혼자 먼저 건 말은 사용자가 못 보고 지나치기 쉬워서 더 오래 띄운다.
		say(text, 0.0 if poked else NUDGE_SHOW)
	if _call(_system(), prompt, OUT_TOKENS, done):
		if poked:
			_open("…", SHOW)
			waiting = true
		else:
			state.nudges = int(state.nudges) + 1


func _reply(text: String) -> void:
	var prompt := "최근 대화:\n%s사용자: %s\n(사용자의 말에 대답해라. 대화가 이어지도록, 어울리면 끝에 질문 하나를 붙여라.)" % [_recent(), text]
	_today()
	if int(state.calls) >= DAY_CALLS:
		say("오늘은 말을 너무 많이 했어. 내일 또 얘기하자.")
		return
	_open("…", SHOW)
	waiting = true
	var done := func(answer: String, code: int):
		if answer.is_empty():
			say("지금은 대답을 못 하겠어. (%d)" % code)
			return
		if state.turns.size() > 0:
			state.turns[-1].erase("n")   # 사용자가 답했으니 직전 말은 대화로 남긴다
		_push("u", text)
		_push("m", answer)
		state.since_memo = int(state.since_memo) + 1
		_save()
		say(answer)
		if int(state.since_memo) >= MEMO_EVERY:
			_memo.call_deferred()
	if not _call(_system(), prompt, OUT_TOKENS, done):
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
