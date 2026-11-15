"""팔 든 메시 만들기: app/assets/arm_mesh.bin (인사·점프 때 쓰는 메시).

원래 모델은 팔이 몸에 붙은 한 덩어리 껍질이다. 단면을 잘라 보면 오른팔은 대부분 몸과 떨어진 원통이고
(어깨와 손목 근처만 붙음), 왼팔은 어깨부터 손목까지 몸과 목처럼 이어져 있다. 그런데 리깅 가중치는 팔 안쪽
점들을 몸 뼈에 묶어 놓아서, 팔을 들면 안쪽 면이 뒤처져 줄무늬처럼 접히고 구멍이 보였다.

여기서는 가중치를 믿지 않고 형태로 다시 만든다.
 1. 팔 점 고르기: 팔 뼈 축 둘레에서, 면이 축 바깥을 보는 점을 바깥쪽 씨앗에서부터 이어 붙여 고른다.
 2. 팔 점은 축 위 위치(어깨→팔꿈치→손목)로만 뼈를 정한다(원통이 통째로 움직인다). 어깨 쪽 몇 cm 는 원래 가중치와 섞는다.
 3. 팔이 아닌 점에서는 그 팔 뼈의 영향을 덜어 낸다(가방·치마·옷자락이 끌려가지 않게).
 4. 팔 점과 몸 점을 잇던 삼각형은 지우고, 생긴 구멍을 팔 쪽·몸 쪽 따로 면으로 막는다.
 5. 쉴 때 몸에 가려 있던 팔 안쪽 면은 텍스처가 엉망이라(가려진 곳은 생성기가 대충 칠함) 같은 높이의
    바깥쪽 소매 색으로 덮는다. 막은 면도 같은 색. 색은 꼭짓점 색(rgb = 덮을 색, a = 텍스처를 남길 비율)에 담고
    face.gdshader 가 섞는다. 법선·조명은 건드리지 않는다.

재료: godot --headless --path app -- --dump-mesh  (user://arm_src.bin·json·png)
실행: "$HOME/Library/Application Support/22SUTO/venv/bin/python" tools/arm_mesh.py   (numpy, Pillow 필요)
"""
import json
import os
import struct
import sys
from collections import defaultdict, deque

import numpy as np
from PIL import Image

USER = os.path.expanduser("~/Library/Application Support/Godot/app_userdata/37RHHG/")
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "../app/assets/arm_mesh.bin")

RAMP = (0.015, 0.075)   # 어깨 관절에서 이 거리(m) 사이에 원래 가중치 → 원통 가중치로 넘어간다
CUT_S = 0.5             # 팔 점의 섞임 비율이 이보다 큰 곳에서만 몸과 잇는 삼각형을 지운다
ELBOW = 0.03            # 팔꿈치·손목에서 뼈가 섞이는 반폭(m)
WRIST = 0.02
HAND_LEN = 0.09
HAND_R = 0.085          # 손목 너머에서 손으로 볼 거리(m)
HAND_LUM = 0.44         # 손·소매 끝으로 볼 밝기(치마·가방은 이보다 어둡다)


def smooth(a, b, x):
    t = np.clip((x - a) / (b - a), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def load():
    b = open(USER + "arm_src.bin", "rb").read()
    nv, ni, per = struct.unpack_from("<3I", b, 0)
    o = 12
    V = np.frombuffer(b, "<f4", nv * 3, o).reshape(-1, 3).copy(); o += nv * 12
    N = np.frombuffer(b, "<f4", nv * 3, o).reshape(-1, 3).copy(); o += nv * 12
    UV = np.frombuffer(b, "<f4", nv * 2, o).reshape(-1, 2).copy(); o += nv * 8
    I = np.frombuffer(b, "<i4", ni, o).reshape(-1, 3).copy(); o += ni * 4
    B = np.frombuffer(b, "<i4", nv * per, o).reshape(-1, per).copy(); o += nv * per * 4
    W = np.frombuffer(b, "<f4", nv * per, o).reshape(-1, per).copy()
    assert per == 4
    J = json.load(open(USER + "arm_src.json"))
    tex = np.asarray(Image.open(USER + "arm_src.png").convert("RGB")).astype(np.float32) / 255.0
    return V, N, UV, I, B, W, J["binds"], {k: np.array(v) for k, v in J["rest"].items()}, tex


def param(pts, poly):
    """축(꺾은선) 위 가장 가까운 점: 호 길이 t, 거리, 축에서 바깥으로 향하는 단위 벡터."""
    bd = np.full(len(pts), 1e9); bt = np.zeros(len(pts)); bc = np.zeros((len(pts), 3)); acc = 0.0
    for a, b in zip(poly[:-1], poly[1:]):
        ab = b - a; l = np.linalg.norm(ab)
        k = np.clip(((pts - a) @ ab) / (l * l), 0, 1); c = a + k[:, None] * ab
        dd = np.linalg.norm(pts - c, axis=1); m = dd < bd
        bd[m] = dd[m]; bt[m] = acc + k[m] * l; bc[m] = c[m]; acc += l
    # 어깨 관절보다 앞(몸 쪽)은 첫 마디를 늘려 음수 t 로
    a, b = poly[0], poly[1]; u = (b - a) / np.linalg.norm(b - a); t0 = (pts - a) @ u
    bt = np.where(bt <= 1e-6, np.minimum(t0, 0.0), bt)
    return bt, bd, (pts - bc) / (bd[:, None] + 1e-9)


def main():
    V, N, UV, I, B, W, binds, rest, tex = load()
    nv = len(V)
    # 위치가 같은 점(UV 이음매로 갈라진 것)을 하나로 본다.
    _, first, inv = np.unique(np.round(V * 1e5).astype(np.int64), axis=0, return_index=True, return_inverse=True)
    inv = inv.reshape(-1)
    nw = inv.max() + 1
    P = V[first]
    NN = np.zeros((nw, 3)); np.add.at(NN, inv, N); NN /= np.linalg.norm(NN, axis=1, keepdims=True) + 1e-9
    T = inv[I]
    px = np.clip((UV[:, 0] % 1.0 * tex.shape[1]).astype(int), 0, tex.shape[1] - 1)
    py = np.clip((UV[:, 1] % 1.0 * tex.shape[0]).astype(int), 0, tex.shape[0] - 1)
    col = tex[py, px]
    C = np.zeros((nw, 3)); cnt = np.zeros(nw); np.add.at(C, inv, col); np.add.at(cnt, inv, 1); C /= cnt[:, None]
    L = C @ np.array([0.299, 0.587, 0.114])
    adj = defaultdict(set)
    for t in T:
        for e in range(3):
            adj[t[e]].add(t[(e + 1) % 3]); adj[t[(e + 1) % 3]].add(t[e])
    # 가중치는 welded 점마다 dict 로
    wts = [dict() for _ in range(nw)]
    for w_id, v_id in enumerate(first):
        for c in range(4):
            if W[v_id, c] > 0:
                wts[w_id][int(B[v_id, c])] = wts[w_id].get(int(B[v_id, c]), 0.0) + float(W[v_id, c])
    spine = binds.index("Spine02")
    body_center = rest["Spine02"]

    arm_of = np.zeros(nw, np.int8)          # 0 몸, 1 오른팔, 2 왼팔
    S = np.zeros(nw)                        # 원통 가중치로 넘어간 비율
    TT = np.zeros(nw)
    over = np.zeros((nw, 4)); over[:, :3] = 1.0; over[:, 3] = 1.0     # 꼭짓점 색(rgb 덮을 색, a 텍스처 비율)
    side_info = {}

    for code, (side, sx) in enumerate([("Right", -1.0), ("Left", 1.0)], start=1):
        A, F, H = rest[side + "Arm"], rest[side + "ForeArm"], rest[side + "Hand"]
        poly = [A, F, H, H + (H - F) / np.linalg.norm(H - F) * HAND_LEN]
        L1 = np.linalg.norm(F - A); L2 = np.linalg.norm(H - F)
        ids = [binds.index(side + n) for n in ("Arm", "ForeArm", "Hand")]

        def axis_at(tv, poly=poly):
            """뼈 축 위 호 길이 tv 인 점과 그 마디 방향."""
            acc = 0.0
            for a_, b_ in zip(poly[:-1], poly[1:]):
                l = np.linalg.norm(b_ - a_)
                if tv <= acc + l or b_ is poly[-1]:
                    return a_ + (b_ - a_) * ((tv - acc) / l), (b_ - a_) / l
                acc += l

        def frame(u, sx=sx):
            """축에 수직인 두 방향: e1 은 몸 바깥쪽(±x), e2 = u × e1."""
            e1 = np.array([sx, 0.0, 0.0]); e1 = e1 - (e1 @ u) * u; e1 /= np.linalg.norm(e1)
            return e1, np.cross(u, e1)

        # 1) 뼈 축 둘레에서 면이 바깥을 보는 점을 바깥쪽 씨앗에서 이어 붙인다(겉껍질만 확실하게).
        t, d, r = param(P, poly)
        nr = (NN * r).sum(1)
        seeds = np.where((r[:, 0] * sx > 0.6) & (d < 0.11) & (t > 0.10) & (t < 0.30) & (nr > 0.6) & (L > 0.55))[0]
        R0 = np.percentile(d[seeds], 90) * 1.35
        ok = (d < R0) & (nr > 0.1) & (t > RAMP[0])
        shell = np.zeros(nw, bool); shell[seeds] = True; q = deque(seeds)
        while q:
            u_ = q.popleft()
            for w in adj[u_]:
                if not shell[w] and ok[w]:
                    shell[w] = True; q.append(w)
        # 2) 겉껍질에 원을 맞춰(높이 칸마다) 원통의 진짜 가운데와 반지름을 구한다. 뼈는 가운데에서 벗어나 있고,
        #    몸에 묻힌 팔(왼팔)은 껍질이 반쪽뿐이라 평균으로는 가운데를 못 구한다.
        t_end = L1 + L2 + HAND_LEN
        NB = 12
        edges_b = np.linspace(RAMP[0], t_end, NB + 1); mids = (edges_b[:-1] + edges_b[1:]) / 2
        cen = np.zeros((NB, 3)); rad = np.zeros(NB); good = np.zeros(NB, bool)
        for bi_ in range(NB):
            m = shell & (t >= edges_b[bi_] - 0.01) & (t < edges_b[bi_ + 1] + 0.01)
            a0, u = axis_at(mids[bi_]); e1, e2 = frame(u)
            cen[bi_] = a0; rad[bi_] = R0 / 1.35
            if m.sum() >= 8:
                qv = P[m] - a0; x = qv @ e1; y = qv @ e2
                Amat = np.c_[2 * x, 2 * y, np.ones(len(x))]
                sol, *_ = np.linalg.lstsq(Amat, x * x + y * y, rcond=None)
                rr = np.sqrt(max(sol[2] + sol[0] ** 2 + sol[1] ** 2, 1e-8))
                if 0.03 < rr < 0.11 and np.hypot(sol[0], sol[1]) < 0.06:
                    cen[bi_] = a0 + sol[0] * e1 + sol[1] * e2; rad[bi_] = rr; good[bi_] = True
        for bi_ in range(NB):
            if not good[bi_]:
                near = min((abs(bi_ - k), k) for k in range(NB) if good[k])[1]
                a0, _ = axis_at(mids[bi_]); an, _ = axis_at(mids[near])
                cen[bi_] = a0 + (cen[near] - an); rad[bi_] = rad[near]
        # 칸 사이를 부드럽게
        cen = np.array([cen[max(0, k - 1):k + 2].mean(0) for k in range(NB)])
        rad = np.array([rad[max(0, k - 1):k + 2].mean() for k in range(NB)])
        print(f"  {side} 원통: 반지름 {rad.round(3).tolist()} (맞춘 칸 {good.sum()}/{NB})")

        def cyl(tv, cen=cen, rad=rad, mids=mids, NB=NB):
            """뼈 축 t 에서의 원통 가운데·반지름(칸 사이 선형 보간)."""
            x = np.clip((np.asarray(tv) - mids[0]) / (mids[1] - mids[0]), 0, NB - 1)
            i0 = np.floor(x).astype(int); i1 = np.minimum(i0 + 1, NB - 1); f = x - i0
            return cen[i0] * (1 - f)[..., None] + cen[i1] * f[..., None], rad[i0] * (1 - f) + rad[i1] * f

        cc, rc_ = cyl(t)
        # 가운데 축에서의 거리: 축 방향 성분은 빼고 잰다.
        udir = np.array([axis_at(float(np.clip(tv, 0, t_end)))[1] for tv in mids])
        xi = np.clip(((t - mids[0]) / (mids[1] - mids[0])).round().astype(int), 0, NB - 1)
        qv = P - cc; qv = qv - (qv * udir[xi]).sum(1)[:, None] * udir[xi]
        dc = np.linalg.norm(qv, axis=1)
        rdir = qv / (dc[:, None] + 1e-9)
        # 3) 원통 안(반지름 조금 넉넉히)에 있는 점을 씨앗에서 이어 붙인다 = 팔.
        ok = (dc < rc_ * 1.16 + 0.004) & (t > RAMP[0]) & (t < t_end + 0.03) & ((NN * rdir).sum(1) > -0.35)
        # 손(주먹)은 원통이 아니다. 손목 너머는 뼈 둘레의 밝은 점(피부·소매 끝)이면 다 받는다(치마·가방은 어두워서 빠진다).
        hand_zone = (t > L1 + L2 - 0.015) & (d < HAND_R) & (L > HAND_LUM)
        ok |= hand_zone
        arm = np.zeros(nw, bool); arm[seeds] = True; q = deque(seeds)
        while q:
            u_ = q.popleft()
            for w in adj[u_]:
                if not arm[w] and ok[w]:
                    arm[w] = True; q.append(w)
        print(f"  {side} 겉껍질 {shell.sum()} → 원통 안 {arm.sum()}")
        r = rdir          # 아래에서 안쪽/바깥쪽을 가를 때 가운데 축 기준으로
        # 손 둘레에 남은 피부색 점(가방·치마에 닿아 이어 붙이기에서 빠진 손 조각)도 손이다.
        hand_px = arm & (t > L1 + L2)
        if hand_px.sum() >= 5:
            skin = np.median(C[hand_px], axis=0)
            extra = ~arm & (t > L1 + L2 - 0.01) & (d < 0.10) & (np.abs(C - skin).max(1) < 0.14)
            print(f"  {side} 손 둘레 피부색 조각 {extra.sum()}점 추가 (피부색 {skin.round(2)})")
            arm |= extra
        # 팔 점으로만 둘러싸인 몸 점(작은 섬)은 팔로 넣는다.
        for _ in range(2):
            for u_ in np.where(~arm & (t > RAMP[1]))[0]:
                nb = list(adj[u_])
                if nb and sum(arm[w] for w in nb) >= max(3, int(len(nb) * 0.75)):
                    arm[u_] = True
        arm &= arm_of == 0
        arm_of[arm] = code
        s = smooth(RAMP[0], RAMP[1], t) * arm
        S[arm] = s[arm]; TT[arm] = t[arm]
        # 원통 가중치
        wh = smooth(L1 + L2 - WRIST, L1 + L2 + WRIST, t)
        wf = smooth(L1 - ELBOW, L1 + ELBOW, t) * (1 - wh)
        wa = 1 - wf - wh
        def rigid_at(tv, ids=ids, L1=L1, L2=L2):
            h = float(smooth(L1 + L2 - WRIST, L1 + L2 + WRIST, tv)); f_ = float(smooth(L1 - ELBOW, L1 + ELBOW, tv)) * (1 - h)
            return {ids[0]: 1 - f_ - h, ids[1]: f_, ids[2]: h}

        for u in np.where(arm)[0]:
            rigid = {ids[0]: wa[u], ids[1]: wf[u], ids[2]: wh[u]}
            mix = defaultdict(float)
            for b_, w_ in wts[u].items():
                mix[b_] += w_ * (1 - s[u])
            for b_, w_ in rigid.items():
                mix[b_] += w_ * s[u]
            wts[u] = dict(mix)
        # 팔이 아닌 점: 이 팔 뼈 영향을 덜어 낸다(어깨 쪽은 그대로).
        tb, db, _ = param(P, poly)
        sb = smooth(RAMP[0], RAMP[1], tb)
        dropped = 0
        for u in np.where(~arm & (arm_of == 0) & (sb > 0))[0]:
            w_arm = sum(wts[u].get(i, 0.0) for i in ids)
            if w_arm <= 0:
                continue
            keep = {b_: w_ for b_, w_ in wts[u].items() if b_ not in ids}
            for i in ids:
                if i in wts[u]:
                    keep[i] = wts[u][i] * (1 - sb[u])
            lost = w_arm * sb[u]
            others = {b_: w_ for b_, w_ in keep.items() if b_ not in ids and w_ > 0}
            if others:
                tot = sum(others.values())
                for b_ in others:
                    keep[b_] += lost * others[b_] / tot
            else:
                keep[spine] = keep.get(spine, 0.0) + lost
            wts[u] = keep; dropped += 1
        # 소매·손 색: 바깥쪽(몸 반대편) 밝은 점들의 높이별 평균
        to_body = body_center - np.array([0, 0, 0]);
        t_c, d_c, r_c = t, d, r
        inward = -(r[:, 0] * sx)                      # +1 이면 몸 쪽을 보는 면
        nbins = 14; edges = np.linspace(RAMP[0], L1 + L2 + HAND_LEN, nbins + 1)
        clean = np.zeros((nbins, 3)); have = np.zeros(nbins, bool)
        for bi_ in range(nbins):
            m = arm & (t >= edges[bi_]) & (t < edges[bi_ + 1]) & (inward < -0.3)
            if m.sum() >= 4:
                # 얼룩을 피하려고 밝은 쪽 절반의 평균
                clean[bi_] = np.median(C[m], axis=0); have[bi_] = True
        for bi_ in range(nbins):            # 빈 칸은 가까운 칸으로
            if not have[bi_]:
                near = min((abs(bi_ - k), k) for k in range(nbins) if have[k])[1]
                clean[bi_] = clean[near]
        def clean_at(tv, edges=edges, clean=clean, nbins=nbins):
            x = np.clip((tv - edges[0]) / (edges[-1] - edges[0]) * nbins - 0.5, 0, nbins - 1)
            i0 = np.floor(x).astype(int); i1 = np.minimum(i0 + 1, nbins - 1); f = (x - i0)[..., None]
            return clean[i0] * (1 - f) + clean[i1] * f
        # 안쪽 면 덮기: 몸 쪽을 볼수록, 그리고 어깨에서 멀수록
        strength = smooth(-0.15, 0.45, inward) * smooth(RAMP[0], RAMP[1] + 0.03, t) * arm
        idx = np.where(strength > 0.01)[0]
        over[idx, :3] = clean_at(t[idx]); over[idx, 3] = 1 - strength[idx]
        side_info[code] = dict(sx=sx, clean_at=clean_at, t=t, poly=poly, ids=ids, cyl=cyl, axis_at=axis_at, frame=frame,
                               rdir=rdir, dc=dc, arm=arm.copy(), L1=L1, L2=L2, t_end=t_end, rigid_at=rigid_at)
        print(f"{side}: 팔 점 {arm.sum()}, 팔 뼈 영향 덜어 낸 몸 점 {dropped}, 안쪽 덮는 점 {len(idx)}, "
              f"소매색 {clean[nbins // 3].round(2)} 손색 {clean[-1].round(2)}")

    ARM_IDS = {i for info in side_info.values() for i in info["ids"]}
    # ---- 팔과 몸을 잇는 삼각형 지우기
    cls = arm_of[T]
    mixed = (cls.max(1) > 0) & (cls.min(1) == 0)
    smax = np.where(cls > 0, S[T], 0).max(1)
    cut = mixed & (smax > CUT_S)
    # 두 팔이 한 삼각형에 섞이는 일은 없어야 한다.
    assert not ((cls == 1).any(1) & (cls == 2).any(1)).any()
    keep_tri = ~cut
    print(f"지운 삼각형 {cut.sum()} (팔-몸 섞인 것 {mixed.sum()})")

    # ---- 구멍 막기
    edge_cnt = defaultdict(int)
    for t in T[keep_tri]:
        for e in range(3):
            a, b = int(t[e]), int(t[(e + 1) % 3]); edge_cnt[(min(a, b), max(a, b))] += 1
    bedges = set()
    for t in T[cut]:
        for e in range(3):
            a, b = int(t[e]), int(t[(e + 1) % 3]); k = (min(a, b), max(a, b))
            if edge_cnt.get(k, 0) == 1:
                bedges.add(k)
    new_V, new_N, new_UV, new_C, new_W = [], [], [], [], []
    new_tris = []

    def add_vert(u, normal, color):
        if DBG:
            color = [0.0, 0.8, 1.0] if arm_of[u] else [1.0, 0.9, 0.0]
        new_V.append(P[u]); new_N.append(normal); new_UV.append(UV[first[u]]); new_C.append([*color, 0.0]); new_W.append(wts[u])
        return nv + len(new_V) - 1

    DBG = bool(os.environ.get("ARM_COLORS"))     # 확인용: 새로 넣은 면을 종류별 원색으로

    def add_raw(pos, normal, color, wdict):
        if DBG:
            color = [1.0, 0.0, 1.0] if wdict is not None and len(wdict) and max(wdict, key=wdict.get) in ARM_IDS else [0.0, 0.9, 0.0]
        new_V.append(pos); new_N.append(normal); new_UV.append([0.0, 0.0]); new_C.append([*color, 0.0]); new_W.append(wdict)
        return nv + len(new_V) - 1

    def arcs(code, info):
        """몸에 묻혀 있어 겉면이 없던 팔 안쪽을 원통 조각으로 만들어 넣는다. 고리(축을 따라 1.2cm 마다)마다
        팔 점들이 비운 각도 틈을 찾아, 틈 양끝 점의 반지름을 이어 호를 그린다. 이웃 고리끼리 띠로 잇는다."""
        tv = info["t"]; arm = arm_of == code
        STEP = 0.012; K = 10; MARGIN = np.radians(16.0)        # 껍질 가장자리 밑으로 넉넉히 들어가야 틈이 안 보인다
        # 구멍(지운 삼각형) 가장자리에 있는 팔 점. 이게 있는 높이에서만 안쪽 면을 만든다.
        rim = np.zeros(nw, bool)
        for a_, b_ in bedges:
            for u_ in (a_, b_):
                if arm_of[u_] == code:
                    rim[u_] = True
        rings = []
        for ti in np.arange(RAMP[1], info["t_end"], STEP):
            m = np.where(arm & (np.abs(tv - ti) < STEP * 1.5))[0]
            if not (rim & (np.abs(tv - ti) < STEP * 1.5)).any():
                rings.append(None); continue
            a0, u = info["axis_at"](float(ti)); e1, e2 = info["frame"](u)
            c, rfit = info["cyl"](np.array([ti])); c = c[0]; rfit = float(rfit[0])
            if len(m) < 5:
                rings.append(None); continue
            qv = P[m] - c; th = np.arctan2(qv @ e2, qv @ e1); rr = np.hypot(qv @ e1, qv @ e2)
            o = np.argsort(th); th = th[o]; rr = rr[o]
            gaps = np.diff(np.r_[th, th[0] + 2 * np.pi]); g = int(np.argmax(gaps))
            mid = th[g] + gaps[g] / 2
            if os.environ.get("ARM_DEBUG"):
                print(f"    고리 t={ti:.3f} 점 {len(m)} 틈 {np.degrees(gaps[g]):.0f}° 가운데 {np.degrees(mid) % 360:.0f}°")
            # 점 사이 간격만으로도 20~25° 틈은 흔하다. 30° 넘게 몸 쪽으로 비어 있을 때만. 손(주먹)은 원통이 아니라 뺀다.
            if gaps[g] < np.radians(30.0) or np.cos(mid) > 0.35 or ti > info["L1"] + info["L2"] + 0.01:      # 틈이 작거나 몸 쪽이 아니면 건너뛴다
                rings.append(None); continue
            a_th = th[g] % (2 * np.pi)                                 # 틈은 θ=π(몸 쪽) 둘레라 0~2π 로 맞추면 고리끼리 값이 이어진다
            rings.append(dict(t=float(ti), c=c, e1=e1, e2=e2, a=a_th, b=a_th + gaps[g], ra=rr[g], rb=rr[(g + 1) % len(rr)], rfit=rfit))
        # 이어진 구간 안에서 각도·반지름을 다듬는다.
        for key in ("a", "b", "ra", "rb"):
            vals = [r_[key] if r_ else None for r_ in rings]
            for i_, r_ in enumerate(rings):
                if r_:
                    nb = [vals[k] for k in (i_ - 1, i_, i_ + 1) if 0 <= k < len(rings) and vals[k] is not None]
                    r_[key] = float(np.mean(nb))
        # 구간 양 끝을 고리 하나씩 더 늘린다(끝에서 틈이 좁아지며 남는 구멍을 덮는다).
        ext = list(rings)
        for i_, r_ in enumerate(rings):
            if r_ is None:
                for j_ in (i_ - 1, i_ + 1):
                    if 0 <= j_ < len(rings) and rings[j_] is not None:
                        ti = RAMP[1] + i_ * STEP
                        a0, u = info["axis_at"](float(ti)); e1, e2 = info["frame"](u)
                        c, rfit = info["cyl"](np.array([ti]))
                        ext[i_] = dict(rings[j_], t=float(ti), c=c[0], e1=e1, e2=e2, rfit=float(rfit[0]))
                        break
        rings = ext
        # 몸 쪽 구멍 가장자리 점(팔이 박혀 있던 홈의 테두리). 홈 면의 뼈 영향과 색은 가장 가까운 테두리 점에서 가져온다.
        brim = np.array(sorted({u_ for a_, b_ in bedges for u_ in (a_, b_)
                                if arm_of[u_] == 0 and any(arm_of[w] == code for w in adj[u_])}), dtype=int)
        n = 0
        # which: 0 = 팔 안쪽 면(팔 뼈를 따른다, 면이 바깥을 본다), 1 = 몸에 남는 홈(몸을 따른다, 면이 홈 안쪽=축을 본다).
        for which in (0, 1):
            if which == 1 and (len(brim) == 0 or os.environ.get("NO_BODYCAP")):
                break
            prev = None
            for r_ in rings:
                if r_ is None:
                    prev = None; continue
                ids_ = []
                grow = MARGIN if which == 0 else np.radians(14.0)          # 홈은 테두리 밑으로 넉넉히 들어가게
                for k in range(K):
                    f = k / (K - 1); th = (r_["a"] - grow) * (1 - f) + (r_["b"] + grow) * f
                    rad_ = min((r_["ra"] * (1 - f) + r_["rb"] * f), r_["rfit"] * 1.05) * (0.955 if which == 0 else 1.0)
                    nrm = np.cos(th) * r_["e1"] + np.sin(th) * r_["e2"]
                    pos = r_["c"] + rad_ * nrm
                    if which == 0:
                        ids_.append(add_raw(pos, nrm, info["clean_at"](np.array([r_["t"]]))[0], info["rigid_at"](r_["t"])))
                    else:
                        near = brim[np.argmin(((P[brim] - pos) ** 2).sum(1))]
                        ids_.append(add_raw(pos, -nrm, C[near], wts[near]))
                if prev is not None:
                    for k in range(K - 1):
                        for tri in ((prev[k], ids_[k], ids_[k + 1]), (prev[k], ids_[k + 1], prev[k + 1])):
                            pa, pb, pc = (np.array(new_V[x - nv]) for x in tri)
                            want = np.array(new_N[tri[0] - nv])
                            if np.cross(pb - pa, pc - pa) @ want < 0:
                                tri = (tri[0], tri[2], tri[1])
                            new_tris.append(tri); n += 1
                prev = ids_
        info["arc_t"] = [r_["t"] for r_ in rings if r_]
        return n, sum(1 for r_ in rings if r_)

    def chains(edges):
        g = defaultdict(list)
        for a, b in edges:
            g[a].append(b); g[b].append(a)
        seen = set(); out = []
        for start in sorted(g, key=lambda u: len(g[u])):      # 끝점(이웃 하나)부터
            if start in seen:
                continue
            path = [start]; seen.add(start); cur = start
            while True:
                nxt = [w for w in g[cur] if w not in seen]
                if not nxt:
                    break
                cur = nxt[0]; path.append(cur); seen.add(cur)
            closed = len(path) > 2 and path[0] in g[path[-1]]
            out.append((path, closed))
        return out

    def zipper(Achain, Bchain, tv):
        tris = []; i = j = 0
        while i < len(Achain) - 1 or j < len(Bchain) - 1:
            step_a = j >= len(Bchain) - 1 or (i < len(Achain) - 1 and tv[Achain[i + 1]] <= tv[Bchain[j + 1]])
            if step_a:
                tri = (Achain[i], Bchain[j], Achain[i + 1]); i += 1
            else:
                tri = (Achain[i], Bchain[j], Bchain[j + 1]); j += 1
            if len(set(tri)) == 3:
                tris.append(tri)
        return tris

    def patch(path, closed, tv, want_dir, color_of, label, skip=None):
        if len(path) < 3:
            return 0
        if closed:
            lo = int(np.argmin(tv[path])); path = path[lo:] + path[:lo]
            hi = int(np.argmax(tv[path]))
            Ach = path[:hi + 1]; Bch = [path[0]] + path[:hi - 1:-1]
        else:
            hi = int(np.argmax(tv[path]))
            Ach = path[:hi + 1]; Bch = path[:hi - 1:-1] if hi > 0 else path[::-1]
            if len(Ach) < 2 or len(Bch) < 2:
                return 0
        tris = zipper(Ach, Bch, tv)
        if not tris:
            return 0
        vn = defaultdict(lambda: np.zeros(3))
        fixed = []
        for a, b, c in tris:
            if skip is not None and skip(float(np.mean([tv[a], tv[b], tv[c]]))):
                continue
            n = np.cross(P[b] - P[a], P[c] - P[a])
            if n @ want_dir(P[[a, b, c]].mean(0)) < 0:
                b, c = c, b; n = -n
            for u in (a, b, c):
                vn[u] += n
            fixed.append((a, b, c))
        # 납작한 면이라 법선 하나로(점마다 다르면 삼각형마다 밝기가 달라 부채꼴 줄무늬가 보인다).
        flat_n = sum(vn.values()); flat_n = flat_n / (np.linalg.norm(flat_n) + 1e-12)
        vid = {}
        for u in vn:
            vid[u] = add_vert(u, flat_n, color_of(u))
        for a, b, c in fixed:
            new_tris.append((vid[a], vid[b], vid[c]))
        return len(fixed)

    def in_arcs(info):
        ts = np.array(info.get("arc_t", []))
        return (lambda tv: bool(len(ts)) and bool((np.abs(ts - tv) < 0.014).any()))

    # 원래 메시의 앞면 방향(감는 순서)을 잰다: cross(b-a, c-a) 가 법선과 같은 쪽인지.
    tp = P[T[:2000]]; gn = np.cross(tp[:, 1] - tp[:, 0], tp[:, 2] - tp[:, 0])
    same = ((gn * NN[T[:2000, 0]]).sum(1) > 0).mean()
    flip = same < 0.5
    print(f"감는 순서: cross(b-a,c-a)·법선 > 0 비율 {same:.2f} → {'뒤집어 넣음' if flip else '그대로'}")

    for code, info in side_info.items():
        sx = info["sx"]; tv = info["t"]
        arm_e = [(a, b) for a, b in bedges if arm_of[a] == code and arm_of[b] == code]
        body_e = [(a, b) for a, b in bedges if arm_of[a] == 0 and arm_of[b] == 0
                  and any(arm_of[w] == code for w in adj[a] | adj[b])]
        axis_pts = np.array(info["poly"])

        def toward_body(p, sx=sx):
            return np.array([-sx, 0.0, 0.0])

        def away_body(p, sx=sx):
            return np.array([sx, 0.0, 0.0])

        n_arm = n_body = 0
        n_arm, n_rings = (0, 0) if os.environ.get("NO_ARCS") else arcs(code, info)
        # 좁은 틈(원통 조각을 만들 만큼 벌어지지 않은 곳)은 가장자리끼리 바로 이어 막는다. 넓은 곳에서는 이 면이 원통 조각 안에 숨는다.
        n_flat = 0
        for path, closed in chains(arm_e):
            n_flat += patch(path, closed, tv, toward_body, lambda u, info=info, tv=tv: info["clean_at"](np.array([tv[u]]))[0], "arm",
                            skip=in_arcs(info))
        n_arm += n_flat
        tb, _, _ = param(P, info["poly"])
        for path, closed in ([] if os.environ.get("NO_BODYCAP") else chains(body_e)):
            n_body += patch(path, closed, tb, away_body, lambda u: C[u], "body", skip=in_arcs(info))
        print(f"  {['', 'Right', 'Left'][code]}: 구멍 가장자리 팔 {len(arm_e)} 몸 {len(body_e)} → 팔 안쪽 원통 조각 {n_arm}(고리 {n_rings}), 몸 쪽 막은 삼각형 {n_body}")

    if os.environ.get("ARM_DEBUG"):
        # 확인용: 높이별 단면(위에서 본 모습, 위가 앞). 빨강 오른팔, 파랑 왼팔, 검정 몸, 초록 지운 삼각형, 주황 새로 넣은 면.
        from PIL import ImageDraw
        ys = [0.74, 0.70, 0.66, 0.62, 0.58, 0.56, 0.54, 0.52, 0.50, 0.48, 0.46, 0.44]
        sc = 1500; W_ = 640; H_ = 440
        img = Image.new("RGB", (W_ * 4, H_ * 3), "white"); dr = ImageDraw.Draw(img)
        allP = np.vstack([P, np.array(new_V).reshape(-1, 3)]) if new_V else P
        tris = [(T[k], "cut" if cut[k] else "old") for k in range(len(T))]
        remap = lambda x: x if x < nv else nw + (x - nv)
        ntl = [(np.array([remap(a) if a >= nv else inv[a] for a in tri]), "new") for tri in new_tris]
        for n_, y in enumerate(ys):
            ox = (n_ % 4) * W_ + W_ // 2; oy = (n_ // 4) * H_ + H_ // 2
            dr.text((ox - W_ // 2 + 6, oy - H_ // 2 + 4), f"y={y}", fill="black")
            for tri, kind in tris + ntl:
                tp = allP[tri]; sdist = tp[:, 1] - y
                if sdist.min() >= 0 or sdist.max() < 0:
                    continue
                pts = []
                for e in range(3):
                    a, b = tp[e], tp[(e + 1) % 3]; da, db = a[1] - y, b[1] - y
                    if (da < 0) != (db < 0):
                        k = da / (da - db); p_ = a + (b - a) * k; pts.append((ox + p_[0] * sc * 0.55, oy - p_[2] * sc * 0.55))
                if len(pts) != 2:
                    continue
                if kind == "new":
                    c_ = (255, 140, 0)
                elif kind == "cut":
                    c_ = (0, 170, 0)
                else:
                    cl = arm_of[tri]
                    c_ = (220, 0, 0) if (cl == 1).all() else (0, 0, 230) if (cl == 2).all() else (0, 0, 0) if (cl == 0).all() else (150, 150, 150)
                dr.line(pts, fill=c_, width=2 if c_ != (0, 0, 0) else 1)
        img.save(os.environ["ARM_DEBUG"])

    # ---- 내보내기
    def top4(dct):
        items = sorted(((w, b) for b, w in dct.items() if w > 1e-5), reverse=True)[:4]
        tot = sum(w for w, _ in items) or 1.0
        bs = [b for _, b in items] + [0] * (4 - len(items)); ws = [w / tot for w, _ in items] + [0.0] * (4 - len(items))
        return bs, ws

    oB = np.zeros((nv + len(new_V), 4), np.int32); oW = np.zeros((nv + len(new_V), 4), np.float32)
    cache = {}
    for v_id in range(nv):
        u = int(inv[v_id])
        if u not in cache:
            cache[u] = top4(wts[u])
        oB[v_id], oW[v_id] = cache[u]
    for k, dct in enumerate(new_W):
        oB[nv + k], oW[nv + k] = top4(dct)
    oV = np.vstack([V, np.array(new_V).reshape(-1, 3)]).astype(np.float32)
    oN = np.vstack([N, np.array(new_N).reshape(-1, 3)]).astype(np.float32)
    oUV = np.vstack([UV, np.array(new_UV).reshape(-1, 2)]).astype(np.float32)
    oC = np.vstack([over[inv], np.array(new_C).reshape(-1, 4)]).astype(np.float32)
    nt = np.array(new_tris, np.int32).reshape(-1, 3)
    if flip and len(nt):
        nt = nt[:, [0, 2, 1]]
    oI = np.vstack([I[keep_tri], nt]).astype(np.int32)
    with open(OUT, "wb") as f:
        f.write(struct.pack("<2I", len(oV), oI.size))
        for arr in (oV, oN, oUV, oC, oB, oW, oI):
            f.write(arr.tobytes())
    print(f"→ {os.path.normpath(OUT)}: 점 {len(oV)} (새 점 {len(new_V)}), 삼각형 {len(oI)}")


if __name__ == "__main__":
    main()
