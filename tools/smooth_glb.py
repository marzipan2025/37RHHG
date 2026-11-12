import json,struct,sys,numpy as np
src,dst,iters=sys.argv[1],sys.argv[2],int(sys.argv[3])
d=open(src,"rb").read()
clen=struct.unpack_from("<I",d,12)[0]; j=json.loads(d[20:20+clen]); boff=20+clen+8; blen=struct.unpack_from("<I",d,20+clen)[0]
b=bytearray(d[boff:boff+blen])
p=j["meshes"][0]["primitives"][0]
def acc(i,dt,n):
    a=j["accessors"][i]; bv=j["bufferViews"][a["bufferView"]]; o=bv.get("byteOffset",0)+a.get("byteOffset",0)
    assert "byteStride" not in bv or bv["byteStride"]==np.dtype(dt).itemsize*n
    return a,o,np.frombuffer(b,dt,a["count"]*n,o).reshape(-1,n).copy()
pa,po,P=acc(p["attributes"]["POSITION"],"<f4",3); na,no,N=acc(p["attributes"]["NORMAL"],"<f4",3)
ia=j["accessors"][p["indices"]]; idt={5123:"<u2",5125:"<u4"}[ia["componentType"]]
_,_,I=acc(p["indices"],idt,1); F=I.reshape(-1,3).astype(np.int64)
# weld by position
_,inv=np.unique(np.round(P,5),axis=0,return_inverse=True); inv=inv.ravel(); nw=inv.max()+1
W=np.zeros((nw,3)); cnt=np.zeros(nw); np.add.at(W,inv,P); np.add.at(cnt,inv,1); W/=cnt[:,None]
Fw=inv[F]; E=np.concatenate([Fw[:,[0,1]],Fw[:,[1,2]],Fw[:,[2,0]]]); E=np.unique(np.sort(E,1),axis=0)
deg=np.zeros(nw); np.add.at(deg,E[:,0],1); np.add.at(deg,E[:,1],1); deg[deg==0]=1
def lap(X):
    S=np.zeros_like(X); np.add.at(S,E[:,0],X[E[:,1]]); np.add.at(S,E[:,1],X[E[:,0]]); return S/deg[:,None]-X
for _ in range(iters):
    W=W+0.5*lap(W); W=W-0.53*lap(W)
fn=np.cross(W[Fw[:,1]]-W[Fw[:,0]],W[Fw[:,2]]-W[Fw[:,0]])
VN=np.zeros((nw,3)); 
for k in range(3): np.add.at(VN,Fw[:,k],fn)
VN/=np.maximum(np.linalg.norm(VN,axis=1,keepdims=True),1e-12)
P2=W[inv].astype("<f4"); N2=VN[inv].astype("<f4")
b[po:po+P2.nbytes]=P2.tobytes(); b[no:no+N2.nbytes]=N2.tobytes()
pa["min"]=P2.min(0).tolist(); pa["max"]=P2.max(0).tolist()
js=json.dumps(j,separators=(",",":")).encode(); js+=b" "*((4-len(js)%4)%4)
out=struct.pack("<4sII",b"glTF",2,12+8+len(js)+8+len(b))+struct.pack("<II",len(js),0x4E4F534A)+js+struct.pack("<II",len(b),0x004E4942)+bytes(b)
open(dst,"wb").write(out); print(dst,"verts",len(P),"welded",nw,"tris",len(F))
