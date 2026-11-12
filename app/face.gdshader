// 캐릭터 재질 + 얼굴 덧그리기(눈 깜빡임, 웃는 눈, 입 벌리기).
// 눈·입은 텍스처에 그려져 있어서 움직일 수 없다. 그래서 머리 뼈 기준 좌표(cm)로
// 앞에서 비추듯 피부색으로 원래 그림을 덮고 그 위에 새 모양을 그린다.
// 좌표: x = 캐릭터의 왼쪽, y = 위, z = 앞. 원점은 머리 뼈.
shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform vec4 albedo_col : source_color = vec4(1.0);
uniform mat4 head_inv;            // 월드 → 머리 좌표(m)

uniform float blink = 0.0;        // 0 뜬 눈 ~ 1 감은 눈
uniform float happy = 0.0;        // 0 보통 ~ 1 웃는 눈(^ ^)
uniform float mouth = 0.0;        // 0 원래 입 ~ 1 크게 벌린 입

uniform vec3 skin : source_color = vec3(0.98, 0.886, 0.792);
uniform vec3 ink : source_color = vec3(0.28, 0.13, 0.12);
uniform vec3 blush : source_color = vec3(0.97, 0.70, 0.625);
uniform vec2 blush_off = vec2(0.0, -10.5);   // 눈 중심에서 볼터치 중심까지(cm)
uniform vec2 blush_r = vec2(7.5, 5.5);
uniform vec3 eye_dark : source_color = vec3(0.32, 0.14, 0.14);
uniform vec3 eye_light : source_color = vec3(0.56, 0.27, 0.27);
uniform vec3 mouth_in : source_color = vec3(0.62, 0.16, 0.20);
uniform vec3 tongue : source_color = vec3(0.98, 0.56, 0.56);
uniform vec2 eye_c = vec2(14.5, 13.4);      // 왼쪽 눈 중심(오른쪽 눈은 x 반대)
uniform vec2 eye_s = vec2(6.8, 7.2);       // 눈 반지름
uniform vec2 mouth_c = vec2(0.0, 3.9);
uniform float mouth_dark = 0.6;           // 평소 입을 진하게 하는 정도
uniform vec2 mouth_s = vec2(3.6, 4.2);     // 다 벌렸을 때 반지름
uniform float line_w = 1.3;                // 선 두께(cm)
uniform vec3 head_c = vec3(0.0, 14.0, -12.0);   // 얼굴을 공으로 볼 때 중심(cm)
uniform float face_z = 0.0;                // 이보다 앞에 있는 면만 그린다
uniform bool debug = false;

varying vec3 hp;
varying vec3 hn;

void vertex() {
	vec4 w = MODEL_MATRIX * vec4(VERTEX, 1.0);
	hp = (head_inv * w).xyz * 100.0;
	hn = normalize(mat3(head_inv) * (mat3(MODEL_MATRIX) * NORMAL));
}

float cover(float d) {
	// d < 0 이 안쪽. 화면 픽셀 하나 폭으로 부드럽게.
	float f = max(fwidth(d), 1e-4);
	return clamp(0.5 - d / f, 0.0, 1.0);
}

float seg(vec2 p, vec2 a, vec2 b) {
	vec2 pa = p - a, ba = b - a;
	return length(pa - ba * clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0));
}

// 웃으며 꼭 감은 눈. 사용자가 그린 그림을 따른다: 두툼한 초승달, 가운데가 두껍고
// 양 끝은 둥글게 가늘다. 바깥 끝이 안쪽 끝보다 높고, 바깥 위에 작은 속눈썹 하나.
// 색은 적갈색, 가운데가 진하고 끝으로 갈수록 밝다.
// side 는 바깥쪽 방향(+1/-1). q 는 눈 반지름 단위. 돌려주는 값: (덮기, 밝기 0~1).
vec2 happy_eye(vec2 q, float side) {
	vec2 p = q * eye_s;                       // cm
	p.x *= side;                              // +x 가 바깥쪽
	p.y -= 0.72;                              // 곡선 가운데 높이(덮개 중심 근처)
	float w = eye_s.x * 0.86;                 // 반폭
	float x = clamp(p.x, -w, w);
	float u = x / w;
	float fy = w * (-0.36 * u * u + 0.10 * u);
	float slope = -0.72 * u + 0.10;
	float th = w * (0.09 + 0.16 * (1.0 - u * u));   // 반두께
	float d = length(vec2(p.x - x, (p.y - fy) / sqrt(1.0 + slope * slope))) - th;
	float arc = cover(d);
	// 바깥 위 속눈썹: 위쪽 가장자리에서 바깥 위로 뾰족하게.
	float ua = 0.6;
	vec2 a = vec2(ua * w, w * (-0.36 * ua * ua + 0.10 * ua) + w * 0.09 * 0.9 + w * 0.16 * (1.0 - ua * ua) * 0.9);
	vec2 b = a + vec2(w * 0.34, w * 0.13);
	vec2 pa = p - a, ba = b - a;
	float k = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
	float lash = cover(length(pa - ba * k) - w * mix(0.07, 0.015, k));
	float shade = clamp(u * u * 0.8 + (fy - p.y) / th * 0.15, 0.0, 1.0);
	return vec2(max(arc, lash), shade);
}

// 눈을 덮는 피부색. 둘레 피부와 이어지도록 눈 아래쪽은 볼터치 분홍으로 번진다.
vec3 skin_at(vec2 p, vec2 c) {
	float b = 1.0 - smoothstep(0.0, 1.0, length((p - c - blush_off) / blush_r));
	return mix(skin, blush, b);
}

// 눈 하나. 원래 눈을 덮을 비율, 선, 선 밝기를 돌려준다.
vec3 eye(vec2 p, vec2 c) {
	vec2 q = (p - c) / eye_s;
	float e = max(blink, happy);
	// 감기는 눈꺼풀: 위에서 내려와 아래쪽 곡선에서 멈춘다.
	float lid0 = mix(1.25, -0.25, e);
	float bend = mix(0.35, -1.05, happy);          // + 는 ∪, - 는 ∩
	float lid = lid0 + bend * q.x * q.x - mix(0.0, 0.25, happy) * e + happy * 0.55;
	float inside = 1.0 - smoothstep(1.0, 1.4, length(q * vec2(mix(1.0, 0.78, happy), mix(0.92, 0.84, happy))));
	// 눈을 감으면 눈 위쪽 쌍꺼풀 선·속눈썹 그늘이 앞머리 사이로 보이므로 덮개를 위로 늘린다.
	// 머리카락 색에는 그리지 않으니 앞머리는 그대로 남는다.
	float up = (1.0 - smoothstep(1.15, 1.45, abs(q.x) * 0.78)) * smoothstep(-0.2, 0.3, q.y) * (1.0 - smoothstep(2.6, 3.0, q.y));
	inside = max(inside, up * happy);
	// 눈꺼풀 위쪽은 덮고, 다 감기면 아래쪽 남은 눈동자까지 덮는다.
	float shut = step(0.02, e) * inside * max(cover((lid - q.y) * eye_s.y), smoothstep(0.8, 1.0, e));
	float wide = cover((abs(q.x) - 1.0) * eye_s.x);
	float line = step(0.02, blink) * (1.0 - step(0.5, happy)) * wide * cover(abs(q.y - lid) * eye_s.y - line_w * 0.5);
	float shade = 0.0;
	if (happy > 0.5) {
		vec2 h = happy_eye(q, sign(c.x));
		line = h.x;
		shade = h.y;
	}
	return vec3(shut, line, shade);
}

void fragment() {
	vec4 t = texture(albedo_tex, UV) * albedo_col;
	vec3 c = t.rgb;
	// 앞머리가 눈 위로 내려와 있으므로 머리카락 색에는 그리지 않는다.
	// 입 둘레에는 머리카락이 없고 원래 입이 붉어서 이 판정을 끈다.
	// 눈동자 아래쪽도 붉어서 머리카락으로 잘못 보이므로, 눈 가운데보다 아래는 판정하지 않는다.
	// 단, 눈 바깥 옆으로 내려온 머리카락은 그대로 머리카락으로 본다.
	bool under_eye = hp.y < eye_c.y + 1.0 && abs(abs(hp.x) - eye_c.x) < eye_s.x * 0.9;
	bool hair = c.r > 0.72 && c.g < 0.6 * c.r && hp.y > mouth_c.y + 4.0 && !under_eye;
	// 눈 위쪽에서는 그늘진 어두운 머리카락도 머리카락으로 본다(덮개가 앞머리 끝을 칠하지 않게).
	hair = hair || (c.r > 0.5 && c.g < 0.55 * c.r && hp.y > eye_c.y + eye_s.y * 0.95);
	// 눈 자리는 오목해서 안쪽 면이 옆·아래를 본다. 그래서 면 방향 조건을 넉넉히 둔다.
	bool front = hn.z > -0.35 && hp.z > face_z;
	if (debug && front && hair) {
		c = mix(c, vec3(0.0, 1.0, 0.0), 0.6);
	}
	if (front && !hair) {
		vec2 p = hp.xy;
		if (debug) {
			vec2 g = abs(fract(p + 0.5) - 0.5) / fwidth(p);
			float gl = 1.0 - clamp(min(g.x, g.y), 0.0, 1.0);
			vec2 g5 = abs(fract(p / 5.0 + 0.5) - 0.5) * 5.0 / fwidth(p);
			float g5l = 1.0 - clamp(min(g5.x, g5.y) - 0.5, 0.0, 1.0);
			c = mix(c, vec3(0.2, 0.5, 1.0), gl * 0.5);
			c = mix(c, vec3(0.0, 0.0, 0.9), g5l);
			c = mix(c, vec3(1.0, 0.0, 0.0), 1.0 - clamp(abs(p.x) / fwidth(p.x) - 0.5, 0.0, 1.0));
			c = mix(c, vec3(0.0, 0.7, 0.0), 1.0 - clamp(abs(p.y) / fwidth(p.y) - 0.5, 0.0, 1.0));
		} else {
			vec3 a = eye(p, eye_c);
			vec3 b = eye(p, vec2(-eye_c.x, eye_c.y));
			vec3 sk = a.x > b.x ? skin_at(p, eye_c) : skin_at(p, vec2(-eye_c.x, eye_c.y));
			c = mix(c, sk, max(a.x, b.x));
			float sh = a.y > b.y ? a.z : b.z;
			vec3 lc = happy > 0.5 ? mix(eye_dark, eye_light, sh) : ink;
			c = mix(c, lc, max(a.y, b.y));
			// 눈을 감으면 원래 눈 자리의 오목한 굴곡이 그늘로 남는다.
			// 그 둘레만 머리를 둥근 공으로 보고 그 법선으로 빛을 받게 해서 매끈하게 만든다.
			if (happy > 0.01) {
				vec2 qa = (p - eye_c) / eye_s;
				vec2 qb = (p - vec2(-eye_c.x, eye_c.y)) / eye_s;
				float r = min(length(qa * vec2(0.8, 0.9)), length(qb * vec2(0.8, 0.9)));
				float smooth_n = happy * (1.0 - smoothstep(1.1, 1.6, r));
				vec3 nh = normalize(hp - head_c);
				vec3 nw = transpose(mat3(head_inv)) * nh;
				vec3 nv = normalize((VIEW_MATRIX * vec4(nw, 0.0)).xyz);
				NORMAL = normalize(mix(NORMAL, nv, smooth_n));
			}
			// 평소 입: 원래 그림이 흐릿해서 선만 조금 더 진하게 한다(피부보다 어두운 곳만).
			float mzone = cover((length((p - mouth_c) / vec2(mouth_s.x * 1.05, 1.4)) - 1.0) * 1.2);
			float dl = dot(skin - c, vec3(0.3, 0.5, 0.2));
			c = mix(c, ink, mzone * smoothstep(0.02, 0.2, dl) * mouth_dark * (1.0 - min(mouth * 4.0, 1.0)));
			if (mouth > 0.01) {
				// 원래 작은 입을 덮고, 위는 살짝 둥글고 아래는 큰 반원인 벌린 입을 그린다.
				vec2 ms = mouth_s * vec2(mix(0.7, 1.0, mouth), mouth);
				vec2 q = (p - mouth_c) / ms;
				float hide = cover((length((p - mouth_c) / vec2(mouth_s.x * 1.05, 1.4)) - 1.0) * 1.2);
				c = mix(c, skin, hide * min(mouth * 4.0, 1.0));
				float top = 0.25 - 0.18 * q.x * q.x;
				float d = max(length(q) - 1.0, q.y - top) * ms.y;
				float fill = cover(d);
				float edge = cover(abs(d) - line_w * 0.35);
				float tq = length((q - vec2(0.0, -0.78)) / vec2(0.62, 0.5)) - 1.0;
				vec3 inner = mix(mouth_in, tongue, cover(tq * ms.y * 0.5));
				c = mix(c, inner, fill);
				c = mix(c, ink, edge * min(mouth * 3.0, 1.0));
			}
		}
	}
	ALBEDO = c;
	ROUGHNESS = 1.0;
	METALLIC = 0.0;
}
