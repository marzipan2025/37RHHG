# 37RHHG

2D 캐릭터 시트를 3D 모델로 바꾸고, 키보드로 걷고 뛰게 조작하는 캐릭터를 만드는 프로젝트.
맥 앱 또는 안드로이드 앱에서 쓸 예정이라 엔진은 Godot 4를 쓴다(GLB를 그대로 불러오고 두 플랫폼으로 내보낼 수 있음).
3D 생성과 리깅은 힉스필드 MCP(`higgsfield` 서버)로, 동작과 앱은 코드로 만든다.

## 지금 상태 (2026-11-12 기준)

- 3D 모델: Tripo P2 결과를 채택. 리깅까지 끝남 → `preview/p2f_walk.glb`
- 걷기: 참조 이미지(`reference/walk_reference.webp`)에 맞춰 코드로 직접 만든 걷기가 동작함 → `out/walk_custom.gif`
- 아직 없는 것: 대기·달리기·점프 동작, 키보드 조작, 실제 앱 프로젝트

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
- **남은 결함:** 가방이 팔 움직임에 끌려간다. 팔 관절 위치가 좌우로 조금 비대칭이다. 표정은 텍스처라 바뀌지 않는다.

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

1. 대기·달리기·점프 동작을 걷기와 같은 방식으로 작성
2. Godot 앱 프로젝트 구성: 방향키 이동, Shift 달리기, Space 점프, 동작 사이 전환
3. macOS 내보내기 확인 후 Android 내보내기
4. 필요하면 가방 가중치 손보기
