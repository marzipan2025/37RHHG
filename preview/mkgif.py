import sys,glob
from PIL import Image
mode,dur=sys.argv[1],int(sys.argv[2])
fs=sorted(glob.glob(f"gif/{mode}[0-9][0-9].png"))
ims=[Image.open(f).convert("RGB").resize((720,448)).quantize(128) for f in fs]
ims[0].save(f"{mode}.gif",save_all=True,append_images=ims[1:],duration=dur,loop=0)
idx=[int(len(fs)*i/8) for i in range(8)]
o=Image.new("RGB",(900*2,560*4))
for i,k in enumerate(idx): o.paste(Image.open(fs[k]).convert("RGB"),((i%2)*900,(i//2)*560))
o.resize((1350,1680)).save(f"{mode}_sheet.png"); print(len(fs),"frames")
