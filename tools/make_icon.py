# Renders the awake. app icon (white squircle, notch, 'awake.' with a green dot).
# Usage: python3 make_icon.py [font.otf]  -> icon-1024.png + AppIcon.icns
import sys
from PIL import Image, ImageDraw, ImageFilter, ImageFont
S=1024; SS=3; W=S*SS
def render(fontfile, out, green_dot=True):
    img = Image.new("RGBA",(W,W),(0,0,0,0))
    inset=int(W*0.1); size=W-2*inset; r=int(size*0.225)
    sh = Image.new("RGBA",(W,W),(0,0,0,0))
    ImageDraw.Draw(sh).rounded_rectangle((inset,inset+W*0.012,W-inset,W-inset+W*0.012),r,fill=(0,0,0,90))
    img.alpha_composite(sh.filter(ImageFilter.GaussianBlur(W*0.012)))
    mask = Image.new("L",(W,W),0); ImageDraw.Draw(mask).rounded_rectangle((inset,inset,W-inset,W-inset),r,fill=255)
    bg = Image.new("RGBA",(W,W))
    gd = ImageDraw.Draw(bg)
    for y in range(W):
        c = int(255 - 14*(y/W)); gd.line([(0,y),(W,y)], fill=(c,c,c,255))
    img.paste(bg,(0,0),mask)
    lay = Image.new("RGBA",(W,W),(0,0,0,0)); d = ImageDraw.Draw(lay)
    cx = W/2
    # notch
    nw,nh = size*0.36,size*0.095; rb=nh*0.6
    d.rounded_rectangle((cx-nw/2,inset-rb*2,cx+nw/2,inset+nh),rb,fill=(0,0,0,255))
    cam=nh*0.26; d.ellipse((cx-cam/2,inset+nh*0.5-cam/2,cx+cam/2,inset+nh*0.5+cam/2),fill=(26,30,44,255))
    # wordmark
    text="awake"
    fs = int(size*0.36)
    font = ImageFont.truetype(fontfile, fs)
    while True:
        bb = d.textbbox((0,0),text+".",font=font)
        if bb[2]-bb[0] <= size*0.88: break
        fs -= 8; font = ImageFont.truetype(fontfile, fs)
    tw = bb[2]-bb[0]; th = bb[3]-bb[1]
    x = cx - tw/2 - bb[0]; y = W/2 + size*0.04 - th/2 - bb[1]
    d.text((x,y), text, font=font, fill=(14,14,16,255))
    wb = d.textbbox((x,y), text, font=font)
    # the dot: green, sits on baseline like a period
    pb = d.textbbox((wb[2], y), ".", font=font)
    if green_dot:
        d.text((wb[2], y), ".", font=font, fill=(52, 199, 89, 255))
    else:
        d.text((wb[2], y), ".", font=font, fill=(14,14,16,255))
    clip = Image.new("RGBA",(W,W),(0,0,0,0)); clip.paste(lay,(0,0),mask)
    img.alpha_composite(clip)
    img = img.resize((S,S), Image.LANCZOS)
    img.save(out)
    return img

if __name__ == '__main__':
    font = sys.argv[1] if len(sys.argv) > 1 else '/usr/share/fonts/opentype/inter/InterDisplay-Bold.otf'
    img = render(font, 'icon-1024.png')
    img.save('AppIcon.icns', sizes=[(x, x) for x in [16, 32, 64, 128, 256, 512, 1024]])
