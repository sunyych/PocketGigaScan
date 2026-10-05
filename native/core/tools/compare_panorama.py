#!/usr/bin/env python3
"""Compare two panorama PNGs and optionally measure producer commands.

The report is JSON so CI can retain numeric regressions. PNG decoding is
stdlib-only for 8-bit RGB/RGBA images; Pillow is used when installed for other
formats. Seam locations are pixel columns in the output image.
"""
from __future__ import annotations
import argparse, json, os, shlex, struct, subprocess, sys, time, zlib

def png(path):
    b = open(path, "rb").read()
    if b[:8] != b"\x89PNG\r\n\x1a\n": raise ValueError("only PNG is supported without Pillow")
    p, w, h, bit, typ = 8, None, None, None, None
    raw = b""
    while p < len(b):
        n = struct.unpack(">I", b[p:p+4])[0]; kind = b[p+4:p+8]; data = b[p+8:p+8+n]; p += 12+n
        if kind == b"IHDR": w,h,bit,typ,comp,flt,inter = struct.unpack(">IIBBBBB", data)
        elif kind == b"IDAT": raw += data
        elif kind == b"IEND": break
    if bit != 8 or typ not in (2,6) or inter != 0: raise ValueError("requires non-interlaced 8-bit RGB/RGBA PNG")
    channels = 3 if typ == 2 else 4; stride = w*channels
    scan = zlib.decompress(raw); rows=[]; prev=bytearray(stride); q=0
    for _ in range(h):
        f=scan[q]; q+=1; cur=bytearray(scan[q:q+stride]); q+=stride
        for i in range(stride):
            a=cur[i-channels] if i>=channels else 0; b=prev[i]; c=prev[i-channels] if i>=channels else 0
            if f==1: cur[i]=(cur[i]+a)&255
            elif f==2: cur[i]=(cur[i]+b)&255
            elif f==3: cur[i]=(cur[i]+((a+b)//2))&255
            elif f==4:
                x=a+b-c; pa=abs(x-a); pb=abs(x-b); pc=abs(x-c); cur[i]=(cur[i]+(a if pa<=pb and pa<=pc else b if pb<=pc else c))&255
            elif f!=0: raise ValueError(f"unsupported PNG filter {f}")
        rows.append(bytes(cur)); prev=cur
    return w,h,channels,rows

def metric(a, b, seams):
    wa,ha,ca,ra=a; wb,hb,cb,rb=b
    out={"old":{"width":wa,"height":ha},"new":{"width":wb,"height":hb},"dimensionsMatch":(wa,ha)==(wb,hb)}
    n=min(wa,wb)*min(ha,hb); total=changed=0; maxd=0
    for y in range(min(ha,hb)):
        for x in range(min(wa,wb)):
            pa=ra[y][x*ca:x*ca+3]; pb=rb[y][x*cb:x*cb+3]; d=sum(abs(u-v) for u,v in zip(pa,pb)); total+=d; maxd=max(maxd,d); changed += d>0
    out.update(mean_abs_rgb=(total/(n*3) if n else 0), changed_pixel_fraction=(changed/n if n else 0), max_pixel_abs_sum=maxd)
    errs=[]
    for x in seams:
        if x<=0 or x>=min(wa,wb): continue
        vals=[]; new_vals=[]
        for y in range(min(ha,hb)):
            l=ra[y][(x-1)*ca:(x-1)*ca+3]; r=ra[y][x*ca:x*ca+3]; vals.append(sum(abs(u-v) for u,v in zip(l,r))/3)
            l=rb[y][(x-1)*cb:(x-1)*cb+3]; r=rb[y][x*cb:x*cb+3]; new_vals.append(sum(abs(u-v) for u,v in zip(l,r))/3)
        old_error=sum(vals)/len(vals) if vals else 0; new_error=sum(new_vals)/len(new_vals) if new_vals else 0
        errs.append({"x":x,"old_mean_boundary_abs_rgb":old_error,"new_mean_boundary_abs_rgb":new_error,"new_minus_old":new_error-old_error})
    out["seams"]=errs
    return out

def run(command):
    t=time.perf_counter(); p=subprocess.run(shlex.split(command), shell=False); return {"exitCode":p.returncode,"elapsedSeconds":time.perf_counter()-t,"peakRssBytes":None}

def main():
    ap=argparse.ArgumentParser(); ap.add_argument("--old",required=True); ap.add_argument("--new",required=True); ap.add_argument("--seams",default=""); ap.add_argument("--old-command"); ap.add_argument("--new-command"); ap.add_argument("--out",default="-"); ap.add_argument("--max-mean-abs-rgb",type=float); ap.add_argument("--max-seam-increase",type=float); a=ap.parse_args()
    report={"oldRun":run(a.old_command) if a.old_command else None,"newRun":run(a.new_command) if a.new_command else None,"comparison":metric(png(a.old),png(a.new),[int(x) for x in a.seams.split(",") if x])}
    text=json.dumps(report,indent=2)+"\n"
    failures=[]
    if not report["comparison"]["dimensionsMatch"]: failures.append("dimensionsMismatch")
    if a.max_mean_abs_rgb is not None and report["comparison"]["mean_abs_rgb"] > a.max_mean_abs_rgb: failures.append("meanAbsRgbThreshold")
    if a.max_seam_increase is not None and any(x["new_minus_old"] > a.max_seam_increase for x in report["comparison"]["seams"]): failures.append("seamIncreaseThreshold")
    report["failures"]=failures; text=json.dumps(report,indent=2)+"\n"
    if a.out=="-": print(text,end="")
    else: open(a.out,"w",encoding="utf-8").write(text)
    if failures: raise SystemExit(1)
if __name__ == "__main__": main()
