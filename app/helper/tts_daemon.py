"""캐릭터 목소리: Supertonic 3 로 한 줄씩 wav 를 만든다(말 도우미 bubble 이 띄우고 재생한다).

22SUTO 가 깔아 둔 파이썬 환경(~/Library/Application Support/22SUTO/venv)과 모델(~/.cache/supertonic3)을
빌려 쓴다. 없으면 시작하자마자 "noengine" 을 내고 끝난다.

표준 입력(한 줄에 JSON 하나): {"id": n, "text": "…", "out": "/경로.wav"}
표준 출력(한 줄씩): "ready" | "ok <id>" | "err <id>" | "noengine"
표준 입력이 닫히면(도우미가 끝나면) 같이 끝난다.
"""
import json
import os
import re
import sys
import wave

VOICE = "F1"
STEPS = 8
SPEED = 1.05


def say(s):
    sys.stdout.write(s + "\n")
    sys.stdout.flush()


try:
    import numpy as np
    from supertonic import TTS

    # 스레드를 안 정하면 코어를 다 써서(460%) 같이 틀어 둔 음악이 끊겼다. 2개면 속도는 같고(한 줄 1.1초) 190%.
    # 우선순위도 낮춰서 다른 앱(음악)이 먼저 CPU 를 받게 한다.
    os.nice(10)
    tts = TTS(auto_download=False, intra_op_num_threads=2, inter_op_num_threads=1)
    style = tts.get_voice_style(voice_name=VOICE)
    rate = getattr(tts, "sample_rate", None) or 44100
except Exception:
    say("noengine")
    sys.exit(0)

say("ready")


def synth(text):
    # 엔진이 못 읽는 글자(이모지 등)는 그 글자만 빼고 다시 해 본다.
    for _ in range(3):
        try:
            wav, _ = tts.synthesize(text, voice_style=style, total_steps=STEPS, speed=SPEED, lang="ko")
            return np.asarray(wav, dtype=np.float32).squeeze()
        except ValueError as e:
            bad = re.findall(r"'(.+?)'", str(e))
            if "unsupported character" not in str(e) or not bad:
                raise
            for c in bad:
                text = text.replace(c, " ")
            if not text.strip():
                raise
    raise ValueError("too many unsupported characters")


for line in sys.stdin:
    try:
        j = json.loads(line)
    except Exception:
        continue
    jid = j.get("id", 0)
    try:
        w = synth(str(j.get("text", "")))
        with wave.open(j["out"], "wb") as f:
            f.setnchannels(1)
            f.setsampwidth(2)
            f.setframerate(rate)
            f.writeframes((np.clip(w, -1, 1) * 32767).astype(np.int16).tobytes())
        say("ok %s" % jid)
    except Exception:
        say("err %s" % jid)
