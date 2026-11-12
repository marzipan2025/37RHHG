# 37RHHG

2D 캐릭터 시트를 3D 모델로 바꾸고, 키보드로 걷고 뛰게 조작하는 캐릭터를 만드는 프로젝트.
맥 앱 또는 안드로이드 앱에서 쓸 예정이라 엔진은 Godot 4를 쓴다(GLB를 그대로 불러오고 두 플랫폼으로 내보낼 수 있음).
3D 생성과 리깅은 힉스필드 MCP(`higgsfield` 서버)로, 동작과 앱은 코드로 만든다.

## 지금 상태 (2026-11-12 기준)

- 3D 모델: Tripo P2 결과를 채택. 리깅까지 끝남 → `preview/p2f_walk.glb`
- 걷기: 참조 이미지(`reference/walk_reference.webp`)에 맞춰 코드로 직접 만든 걷기가 동작함 → `out/walk_custom.gif`
- 맥 메뉴바 앱: `app/` (Godot 4). 화면 위에 키 120pt 캐릭터가 떠서 키보드로 걷고 뛰고 점프함
- 표정: 셰이더로 얼굴에 덧그린 감은 눈(^ ^)과 벌린 입이 달리기·점프 때 가끔 나옴
- 아직 없는 것: 안드로이드 빌드, 가방 가중치 손보기

## 맥 메뉴바 앱 (`app/`)

- 180×210pt 투명·테두리 없는·항상 위 창 하나에 캐릭터를 그리고, 걸을 때 창 자체를 움직인다. 캐릭터 둘레 말고는 클릭이 아래 앱으로 통과한다(`HIT_RECT`).
- 조작: 방향키·WASD 이동(물리 키 기준이라 한글 입력 상태에서도 됨), Shift 달리기, Space 점프. 캐릭터를 클릭해야 키보드 포커스를 받는다. 끌어서 옮기기, 우클릭으로 메뉴.
- 메뉴바 아이콘: `DisplayServer.create_status_indicator` + `NativeMenu`. 생성은 확인했지만(로그 `status indicator 0 feature true`) 이 회사 맥에서는 노치·메뉴바 정리 앱 때문에 눈으로 보이지 않았다. 그래서 우클릭 메뉴를 같이 둔다.
- Dock 아이콘 숨김: `export_presets.cfg`의 `application/additional_plist_content`로 `LSUIElement` 넣음.
- 동작은 전부 `main.gd`의 `_pose(w, run, ph, t, j)` 하나로 만든다. 대기↔걷기↔달리기는 수치를 섞어서 끊김 없이 넘어가고, 걸음 주기는 실제 이동 속도로 정해서 발이 미끄러지지 않는다.
- 옆으로 걸을 때 완전한 옆모습이면 오른쪽 머리카락이 얼굴을 가려서 70도 정도만 돌린다.
- 혼자 돌아다니기(메뉴 맨 위 체크 항목): 걷기 2~6초(25%는 달리기)와 쉬기 1.5~5초를 랜덤하게 반복한다. 쉴 때 반쯤은 이쪽을 본다. 화면 가장자리에 막히면 방향을 바꾸고, 키를 누르면 그동안은 키 조작이 우선이다.
- 창 경계 멀리뛰기: `helper/winwatch`(Swift)가 0.25초마다 다른 앱 창 위치를 `CGWindowListCopyWindowInfo`로 읽어 한 줄로 보내고, 앱이 `OS.execute_with_pipe`로 받아 스레드에서 읽는다. 발 위치와 앞쪽 지점이 어떤 창 안팎으로 갈리면 그 방향으로 0.85초 동안 높이 58pt로 멀리뛴다(뛴 뒤 1초는 다시 안 뜀). 혼자 돌아다니기 중에만 동작한다.
- 좌표: CG 창 좌표는 주 화면 왼쪽 위가 원점인 pt. Godot 화면 좌표는 모든 화면을 합친 영역의 왼쪽 위가 원점인 px. 그래서 도우미가 합친 영역의 원점을 같이 보내고 `(cg - origin) * px_scale`로 바꾼다. 창 위치 읽기에는 화면 기록 권한이 필요 없다(창 이름만 필요).
- 캐릭터는 지금 있는 화면 안에서만 돌아다닌다. 다른 모니터로 보내려면 끌어서 옮긴다.
- 머리 두리번거리기: 서 있을 때 1.2~3.5초마다 좌우 ±30도(`LOOK_MAX`) 안에서 새 방향을 골라 천천히 돌린다. 걸으면 앞을 본다.

### 표정 (`app/face.gdshader`)

- 눈·입은 텍스처 그림이라 움직일 수 없고, 텍스처 아틀라스가 잘게 조각나 있어 바꿔 그린 텍스처를 끼우기도 어렵다. GL Compatibility라 Decal도 못 쓴다. 그래서 캐릭터 재질을 셰이더로 바꾸고, 머리 뼈 기준 좌표(cm, x 캐릭터 왼쪽·y 위·z 앞)로 앞에서 비추듯 원래 눈·입을 피부색으로 덮은 뒤 새 모양을 그린다. 머리 좌표는 `_face_update()`가 매 자세마다 `head_inv`로 넘긴다.
- 감은 눈: 사용자가 그린 그림을 따른 적갈색 초승달(가운데 두껍고 끝 둥글게, 바깥 끝이 높고 바깥 위 속눈썹). 입: 중간 크기로 벌린 입 하나(`mouth` 0.6)만 쓴다.
- 덮개 색은 단색이 아니라 아래로 볼터치 분홍이 번진다(`skin_at`). 눈을 감으면 덮개를 앞머리까지 위로 늘려 쌍꺼풀 선·속눈썹 그늘을 지운다.
- 머리카락 판정: 앞머리는 그리지 않도록 붉은색은 건너뛴다. 단 눈동자 아래쪽도 붉어서 눈 가운데 아래는 판정을 끄고, 눈 위쪽은 그늘진 어두운 머리카락까지 머리카락으로 보되 아주 어두운 속눈썹은 뺀다.
- 원래 눈 자리는 오목해서 안쪽 면이 옆·아래를 본다. 면 방향 조건(`hn.z`)을 좁게 두면 그 벽이 안 덮여 흔적이 남는다.
- 나오는 빈도: 서기·걷기는 원래 얼굴. 달리기는 눈·입 각각 3~8초마다 기회, 확률(`RUN_EYES` 0.25, `RUN_MOUTH` 0.35)로 0.5~1.3초. 점프는 뛸 때마다 따로(`JUMP_EYES` 0.25, `JUMP_MOUTH` 0.3) 그 점프 동안만.
- 확인: `--snapshot`이 `app/snap/face_*.png`로 얼굴 확대 컷을 찍는다. `face_grid`는 머리 좌표 1cm·5cm 격자(빨강 x=0, 초록 y=0)와 머리카락 판정(초록)을 보여 줘서 위치를 잴 때 쓴다.

```bash
app/build_mac.sh                                    # build/37RHHG.app 생성(임시 서명)
open build/37RHHG.app                               # 실행
open build/37RHHG.app --args -- --demo              # 자동으로 걷기·달리기·점프를 반복
build/37RHHG.app/Contents/MacOS/37RHHG -- --wander --screen 1   # 1번 화면에서 혼자 돌아다니기로 시작, 멀리뛰기 위치가 로그에 찍힘
cd app && godot --path . --quit-after 900 -- --snapshot   # 자세와 얼굴 확대 컷을 app/snap/에 PNG로
```

- 집 맥 빌드 환경: `brew install --cask godot`(4.7.2) + 같은 버전 내보내기 템플릿. 설치는 `app/build_mac.sh` 뒤 `/Applications`로 복사
- 내보내기에는 `textures/vram_compression/import_etc2_astc=true`가 필요하다(없으면 arm64/universal 내보내기 거부).
- 개발 실행(`godot --path app`)은 Godot 번들로 떠서 Dock에 Godot 아이콘이 보이고, 컴퓨터 사용 도구로 창을 잡을 수 없다. 화면 확인은 내보낸 .app으로 한다.
- 컴퓨터 사용 도구의 키 입력은 누르고 바로 떼서 걷기 시험이 안 된다. 움직임 확인은 `--demo`로.

## 폴더

| 경로 | 내용 |
|---|---|
| `reference/character_sheet.webp` | 원본 캐릭터 시트 |
| `reference/walk_reference.webp` | 사용자가 준 걷기 참조 이미지. 걷기 느낌의 기준 |
| `reference/views/` | 시트에서 잘라 3배로 키운 정면·측면·후면·3/4 후면 |
| `models/meshy_multi_image.glb` | Meshy 다중 이미지 결과. A-포즈지만 눈·리본이 메시에 새겨지고 그림자가 텍스처에 구워져서 탈락 |
| `models/tripo_h31_multiview.glb` | Tripo H3.1 결과. 꽃 장식이 두 개로 생겨서 탈락 |
| `models/tripo_p2_raw.glb` | Tripo P2 원본. 정면이 +X를 봄 |
| `models/tripo_p2_front.glb` | 위 모델을 정면이 +Z를 보도록 돌린 것. 리깅 입력으로 쓴 파일 |
| `preview/` | 렌더링 확인용 Godot 프로젝트. 리깅된 모델과 걷기 코드가 여기 있음 |
| `tools/rotate_glb.py` | GLB 꼭짓점을 Y축으로 90도 돌림(+X → +Z) |
| `tools/smooth_glb.py` | GLB 법선 재계산과 Taubin 스무딩. 반복 0이면 법선만 다시 계산 |
| `out/` | 비교 이미지와 걷기 GIF |

## 걷기 확인하는 법

```bash
cd preview
godot --path . -- custom   # 직접 만든 걷기, 24프레임을 gif/ 에 저장
python3 mkgif.py custom 36 # custom.gif 와 custom_sheet.png 생성 (Pillow 필요)
```

`-- canned`로 바꾸면 GLB에 든 힉스필드 기성 걷기(Casual_Walk)를 50프레임으로 찍는다(`mkgif.py canned 84`).
걷기 수치는 `preview/main.gd`의 `pose()`에 있다. 허벅지 흔들림 26도, 무릎 굽힘 42도, 팔 흔들림 20도, 골반 비틀림 5도.

## 알아둘 것

- **리깅 전에 정면을 +Z로 맞출 것.** 힉스필드 `3d_rigging`은 모델이 +Z를 본다고 가정한다. Tripo 결과는 +X를 봐서 그대로 넣으면 다리 관절이 앞뒤로 놓이고 상체가 숙여진다. `tools/rotate_glb.py`로 돌린 뒤 `media_upload`(.glb) → `media_confirm`(type file) → 반환된 `url`을 `model_url`로 넘긴다.
- **동작은 코드로 만든다.** 기성 동작은 사람 비율 기준이라 2등신 캐릭터에는 보폭과 자세가 맞지 않는다. 뼈를 캐릭터의 좌우 축 기준으로 돌리는 방식(`_rot`)이라 뼈의 로컬 축을 몰라도 된다.
- **뼈대:** 표준 사람형 24개(Hips, Spine02, Spine01, Spine, neck, Head, 좌우 Shoulder/Arm/ForeArm/Hand, 좌우 UpLeg/Leg/Foot/ToeBase). Armature 스케일이 0.01이라 뼈 좌표는 cm 단위.
- **재질:** Tripo 모델은 PBR 맵 때문에 머리카락이 번들거린다. `_matte()`처럼 metallic 0, roughness 1, 노멀맵 끔으로 덮어쓰면 참조 이미지에 가까워진다.
- **형태 스무딩은 쓰지 말 것.** 꼭짓점을 움직이면 UV가 밀려 눈·속눈썹 텍스처가 번진다. 법선 재계산(반복 0)만 안전하다.
- **남은 결함:** 가방이 팔 움직임에 끌려간다. 팔 관절 위치가 좌우로 조금 비대칭이다.

## 힉스필드 크레딧 (참고)

| 작업 | 모델 | 크레딧 |
|---|---|---|
| 다중 이미지 → 3D(텍스처) | `multi_image_to_3d` | 30 |
| 이미지 1장 → 3D, 조명 제거 | `tripo_p2_image_to_3d` (`delight: true`, `face_limit: 30000`) | 34 |
| 다중 시점 → 3D | `tripo_h3_1_multiview_to_3d` | 9 |
| 리깅만 / 리깅 + 기성 동작 1개 | `3d_rigging` | 5 / 8 |
| 이미지 편집 1장 | `gpt_image_2_6` | 0.25 |

지금까지 89크레딧 사용. 생성 전에는 `get_cost: true`로 비용을 먼저 확인하고 사용자에게 물어본 뒤 진행했다.

## 다음 할 일

1. 집 맥에서 메뉴바 아이콘이 보이는지 확인
2. Android 내보내기(터치 조작 필요)
3. 필요하면 가방 가중치 손보기
