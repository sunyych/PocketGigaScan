#!/usr/bin/env python3
"""Generate deterministic overlapping RGB PNG tiles without third-party packages."""
import json, os, struct, sys, zlib
def write(path,w,h,ox,oy,blank=False):
    rows=[]
    for y in range(h): rows.append(b"\0"+bytes((0 if blank else ((x+ox)*17+(y+oy)*11+(((x+ox)//8)^((y+oy)//8))*29)&255) for x in range(w) for _ in range(3)))
    def chunk(k,d): return struct.pack(">I",len(d))+k+d+struct.pack(">I",zlib.crc32(k+d)&0xffffffff)
    data=b"\x89PNG\r\n\x1a\n"+chunk(b"IHDR",struct.pack(">IIBBBBB",w,h,8,2,0,0,0))+chunk(b"IDAT",zlib.compress(b"".join(rows),9))+chunk(b"IEND",b"")
    open(path,"wb").write(data)
out=sys.argv[1] if len(sys.argv)>1 else "fixtures/generated"; os.makedirs(out,exist_ok=True)
def manifest(name,rows,cols):
    tiles=[]
    for r in range(rows):
        for c in range(cols):
            filename=f"tile_{r}_{c}.png"; write(os.path.join(out,filename),256,192,c*128,r*96); tiles.append({"row":r,"column":c,"path":filename})
    with open(os.path.join(out,name),"w",encoding="utf-8") as f: json.dump({"rows":rows,"columns":cols,"overlapX":0.5,"overlapY":0.5,"tiles":tiles},f,indent=2)
manifest("manifest-2.json",1,2); manifest("manifest-3x3.json",3,3); manifest("manifest-4x5.json",4,5)
write(os.path.join(out,"blank.png"),256,192,0,0,True)
with open(os.path.join(out,"corrupt.png"),"wb") as f: f.write(b"not-an-image")
with open(os.path.join(out,"manifest-blank.json"),"w",encoding="utf-8") as f: json.dump({"rows":1,"columns":1,"tiles":[{"row":0,"column":0,"path":"blank.png"}]},f,indent=2)
with open(os.path.join(out,"manifest-corrupt.json"),"w",encoding="utf-8") as f: json.dump({"rows":1,"columns":1,"tiles":[{"row":0,"column":0,"path":"corrupt.png"}]},f,indent=2)
