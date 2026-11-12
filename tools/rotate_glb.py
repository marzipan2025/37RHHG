import json,struct,sys,numpy as np
src,dst=sys.argv[1],sys.argv[2]
d=open(src,"rb").read(); clen=struct.unpack_from("<I",d,12)[0]; j=json.loads(d[20:20+clen]); boff=20+clen+8; blen=struct.unpack_from("<I",d,20+clen)[0]
b=bytearray(d[boff:boff+blen])
print("nodes",j["nodes"])
R=np.array([[0,0,-1],[0,1,0],[1,0,0]],"<f4")  # +X -> +Z
for m in j["meshes"]:
    for p in m["primitives"]:
        for k in ("POSITION","NORMAL"):
            a=j["accessors"][p["attributes"][k]]; bv=j["bufferViews"][a["bufferView"]]; assert "byteStride" not in bv or bv["byteStride"]==12
            o=bv.get("byteOffset",0)+a.get("byteOffset",0)
            V=np.frombuffer(b,"<f4",a["count"]*3,o).reshape(-1,3)@R.T
            V=np.ascontiguousarray(V,"<f4"); b[o:o+V.nbytes]=V.tobytes()
            if k=="POSITION": a["min"]=V.min(0).tolist(); a["max"]=V.max(0).tolist(); print("bounds",a["min"],a["max"])
js=json.dumps(j,separators=(",",":")).encode(); js+=b" "*((4-len(js)%4)%4)
open(dst,"wb").write(struct.pack("<4sII",b"glTF",2,28+len(js)+len(b))+struct.pack("<II",len(js),0x4E4F534A)+js+struct.pack("<II",len(b),0x004E4942)+bytes(b))
