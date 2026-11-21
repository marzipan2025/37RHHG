// 개구리 마법사(37FRHG) 재질. 소녀의 face.gdshader 와 따로 두되, main.gd 가 넘기는 값 이름은 같다
// (head_inv·blink·happy·tint·bloom). 입(mouth)은 개구리에 없어서 받아도 쓰지 않는다.
// - 눈 깜빡임: 개구리 눈은 머리 위로 튀어나온 공이라 눈알 공 위에 위·아래 눈꺼풀을 칠한다.
//   소녀의 웃는 눈(happy)도 감은 눈으로 대신한다.
// - tint(말 모델이 Sonnet): 의상(모자·로브) 보라 → 핑크.
// - bloom(목소리 켬): 옆구리 유리병 물약 → 노랑. 병 자리는 frog.gd 가 정점 색 파랑 0 으로 표시해 둔다.
// 머리 좌표: main.gd _face_update 의 틀(머리 뼈 원점, 캐릭터 왼쪽·위·앞, 월드 단위)을 unit_scale 로 모델 단위로 바꿔 cm 로 쓴다.
shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx, cull_disabled;

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform vec4 albedo_col : source_color = vec4(1.0);
uniform mat4 head_inv;                 // 월드 → 머리 좌표
uniform float unit_scale = 1.0;        // 월드 단위 → 모델 단위(개구리를 키운 배율의 역수)

uniform float blink = 0.0;             // 0 뜬 눈 ~ 1 감은 눈
uniform float happy = 0.0;             // 소녀의 웃는 눈. 개구리는 감은 눈으로
uniform vec3 eye_c = vec3(8.2, 10.7, 11.0);   // 왼쪽 눈알 중심 cm(오른쪽은 x 반대). 37FRHG measure.gd 로 구 맞춤.
uniform float eye_r = 3.7;
uniform float seam = -0.15;            // 다 감았을 때 위·아래 눈꺼풀이 만나는 높이(반지름 단위)
uniform vec3 lid : source_color = vec3(0.45, 0.55, 0.14);       // 눈 둘레 초록
uniform vec3 lid_line : source_color = vec3(0.17, 0.24, 0.05);  // 눈꺼풀 끝 선
uniform float line_w = 0.28;           // cm
uniform bool debug = false;            // 눈알 판정 자리를 빨강으로

// 의상 색: 색상(hue)을 돌려 음영은 남기고, 보이는 밝기는 처음과 끝 사이로 곧게.
// 의상은 색상 0.68~0.80·명도 0.5 이하. 물약 병은 같은 보라~분홍이지만 명도 0.6 이상이라 빠진다.
uniform float tint = 0.0;
uniform vec3 tint_from : source_color = vec3(0.24, 0.17, 0.42);   // 의상 보라(색상 0.73)
uniform vec3 tint_to : source_color = vec3(0.86, 0.30, 0.62);     // 핑크
uniform bool tint_debug = false;

// 유리병 물약 색: 원래 하늘색~보라~분홍 그라데이션을 노랑 쪽으로 모으되 색상 차이를 bloom_spread 만큼 남긴다.
uniform float bloom = 0.0;
uniform float bloom_from_h = 0.72;
uniform vec3 bloom_to : source_color = vec3(0.98, 0.80, 0.16);    // 노랑
uniform float bloom_spread = 0.12;
uniform bool bloom_debug = false;

// 마우스 조명(main.gd _light_set 이 방향광 방향·세기를 바꾼다): 개구리 의상은 어두운 보라라 같은 빛에도
// 명암 차이가 소녀의 절반쯤만 보였다(왼쪽·오른쪽 빛 스냅샷의 밝기 차이 0.031 대 0.057).
// 방향광만 light_gain 배로 대비를 키운다: 밝은 쪽은 더 밝게, 그늘 쪽은 더 어둡게(평균은 그대로).
uniform float light_gain = 2.0;

varying vec3 hp;

void vertex() {
	vec4 w = MODEL_MATRIX * vec4(VERTEX, 1.0);
	hp = (head_inv * w).xyz * 100.0 * unit_scale;
}

vec3 rgb2hsv(vec3 c) {
	vec4 K = vec4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
	vec4 p = mix(vec4(c.bg, K.wz), vec4(c.gb, K.xy), step(c.b, c.g));
	vec4 q = mix(vec4(p.xyw, c.r), vec4(c.r, p.yzx), step(p.x, c.r));
	float d = q.x - min(q.w, q.y);
	return vec3(abs(q.z + (q.w - q.y) / (6.0 * d + 1e-10)), d / (q.x + 1e-10), q.x);
}

vec3 hsv2rgb(vec3 c) {
	vec3 p = abs(fract(c.xxx + vec3(1.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0);
	return c.z * mix(vec3(1.0), clamp(p - 1.0, 0.0, 1.0), c.y);
}

float hue_diff(float a, float b) {
	return fract(a - b + 0.5) - 0.5;
}

float cover(float d) {
	float f = max(fwidth(d), 1e-4);
	return clamp(0.5 - d / f, 0.0, 1.0);
}

void fragment() {
	vec3 c = (texture(albedo_tex, UV) * albedo_col).rgb;
	if ((bloom > 0.001 || bloom_debug) && COLOR.b < 0.5) {
		vec3 h = rgb2hsv(c);
		vec3 ht = rgb2hsv(bloom_to);
		float w = smoothstep(0.22, 0.32, h.z) * smoothstep(0.12, 0.22, h.y);
		if (bloom_debug) {
			c = mix(c, vec3(0.0, 1.0, 0.0), w * 0.8);
		} else {
			float nh = fract(ht.x + hue_diff(h.x, bloom_from_h) * bloom_spread);
			vec3 end = hsv2rgb(vec3(nh, clamp(mix(h.y, ht.y, 0.5), 0.0, 1.0), clamp(h.z * 1.1, 0.0, 1.0)));
			c = mix(c, mix(c, end, bloom), w);
		}
	}
	if (tint > 0.001 || tint_debug) {
		vec3 h = rgb2hsv(c);
		vec3 hf = rgb2hsv(tint_from);
		vec3 ht = rgb2hsv(tint_to);
		float w = (1.0 - smoothstep(0.06, 0.09, abs(hue_diff(h.x, hf.x))))
			* smoothstep(0.18, 0.28, h.y) * (1.0 - smoothstep(0.5, 0.6, h.z));
		if (tint_debug) {
			c = mix(c, vec3(0.0, 1.0, 0.0), w * 0.8);
		} else {
			float dh = hue_diff(ht.x, hf.x);
			vec3 end = hsv2rgb(vec3(fract(h.x + dh), clamp(ht.y + (h.y - hf.y) * 0.5, 0.0, 1.0), h.z * ht.z / hf.z));
			vec3 oc = hsv2rgb(vec3(fract(h.x + dh * tint), mix(h.y, clamp(ht.y + (h.y - hf.y) * 0.5, 0.0, 1.0), tint), h.z * mix(1.0, ht.z / hf.z, tint)));
			vec3 lw = vec3(0.299, 0.587, 0.114);
			float want = mix(dot(c, lw), dot(end, lw), tint);
			oc *= want / max(dot(oc, lw), 1e-4);
			float top = max(oc.r, max(oc.g, oc.b));
			if (top > 1.0) oc = mix(vec3(want), oc, (1.0 - want) / max(top - want, 1e-4));
			c = mix(c, oc, w);
		}
	}
	vec3 e = vec3(eye_c.x * sign(hp.x), eye_c.yz);
	vec3 q = hp - e;
	float dist = length(q);
	float lids = max(blink, happy);
	if (dist < eye_r + 0.5 && q.z > -eye_r * 0.6) {
		if (debug) c = mix(c, vec3(1.0, 0.0, 0.0), 0.5);
		if (lids > 0.001) {
			float y = q.y / max(dist, 1e-3);
			// 눈꺼풀 끝은 가운데가 조금 더 내려온 호(옆으로 갈수록 위로). 위·아래가 같은 호라 다 감으면 빈틈 없이 만난다.
			float bx = q.x * sign(hp.x) / eye_r;
			float bend = 0.18 * bx * bx;
			float up_t = mix(1.05, seam, lids) + bend * lids;
			float lo_t = mix(-1.05, seam, lids) + bend * lids;
			float du = (up_t - y) * eye_r;
			float dl = (y - lo_t) * eye_r;
			c = mix(c, lid, max(cover(du), cover(dl)));
			float ln = max(cover(abs(du) - line_w), cover(abs(dl) - line_w * 0.7));
			c = mix(c, lid_line, ln * step(dist, eye_r + 0.25));
		}
	}
	ALBEDO = c;
	ROUGHNESS = 1.0;
	METALLIC = 0.0;
}

void light() {
	float lambert = max(dot(NORMAL, LIGHT), 0.0);
	DIFFUSE_LIGHT += LIGHT_COLOR * ATTENUATION * (lambert * light_gain - (light_gain - 1.0) * 0.5) / PI;
}
