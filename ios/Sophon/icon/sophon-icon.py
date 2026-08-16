#!/usr/bin/env python3
"""Generate the Sophon app icon as SVG, one file per iOS appearance.

The icon is a lemniscate of Bernoulli -- two entangled protons -- with a binary
string passing between them. Everything here is parametric: the curve is sampled
from its own equation rather than hand-drawn, so it is smooth by construction and
the proportions can be retuned by changing the constants below.

Run `render.sh` afterwards to rasterise to the 1024x1024 PNGs the asset catalog
wants. See README.md for the whole pipeline.
"""
import math

# ---- geometry ---------------------------------------------------------------
A      = 368.0   # half-width of the lemniscate
Y_SCALE= 1.35    # vertical stretch; a true Bernoulli is very slender (2.83:1)
CX, CY = 512.0, 512.0
SAMPLES= 64      # curve sample points -> Bezier segments
STROKE = 78      # ribbon weight
R      = 52      # proton radius
BITS   = "01101100101"
FS, LS = 60, 10  # digit size / letter-spacing

# Protons sit at the loop's WIDEST point (x = a*sqrt(3)/(2*sqrt(2)) ~ 0.612a),
# not at the curve's true foci (0.707a). The foci sit visibly outboard of the
# loop's visual centre and read as sliding toward the tips.
FOCUS  = A * math.sqrt(3) / (2 * math.sqrt(2))

# Radial falloff for the protons: the yellow contribution is weighted t**K, so
# the body stays white and heat appears only near the circumference. K=4 keeps
# the warm rim wide enough to survive being scaled to 60px; K=6 loses it.
K      = 4.0
STOPS  = [0, .30, .50, .65, .75, .82, .88, .93, .97, 1.0]


def lemniscate_path():
    """Lemniscate of Bernoulli as a closed cubic-Bezier path.

    x = a*cos t / (1 + sin^2 t),  y = a*sin t*cos t / (1 + sin^2 t)

    Sampled points are joined with Catmull-Rom converted to Beziers, which gives
    C1 continuity -- no flat spots or kinks anywhere on the curve.
    """
    def pt(t):
        d = 1.0 + math.sin(t) ** 2
        return (CX + A * math.cos(t) / d,
                CY + Y_SCALE * A * math.sin(t) * math.cos(t) / d)

    P = [pt(2 * math.pi * i / SAMPLES) for i in range(SAMPLES)]
    n = len(P)
    out = [f"M {P[0][0]:.2f} {P[0][1]:.2f}"]
    for i in range(n):
        p0, p1, p2, p3 = P[(i - 1) % n], P[i], P[(i + 1) % n], P[(i + 2) % n]
        c1 = (p1[0] + (p2[0] - p0[0]) / 6, p1[1] + (p2[1] - p0[1]) / 6)
        c2 = (p2[0] - (p3[0] - p1[0]) / 6, p2[1] - (p3[1] - p1[1]) / 6)
        out.append(f"C {c1[0]:.2f} {c1[1]:.2f} {c2[0]:.2f} {c2[1]:.2f} "
                   f"{p2[0]:.2f} {p2[1]:.2f}")
    return " ".join(out) + " Z"


def gradient_stops(core, hot):
    def mix(t):
        w = t ** K
        return [int(round(c + (h - c) * w)) for c, h in zip(core, hot)]
    return "\n".join(
        '      <stop offset="{:g}%" stop-color="#{:02X}{:02X}{:02X}"/>'.format(
            t * 100, *mix(t)) for t in STOPS)


def svg(bg, ribbon, core, hot, digit):
    """One icon. `digit` is the colour of the binary outside the protons; inside
    them it is always black, which is what makes the string readable where it
    crosses the bright core."""
    d = lemniscate_path()
    lx, rx = CX - FOCUS, CX + FOCUS
    text = (f'<text x="512" y="512" text-anchor="middle" dominant-baseline="central" '
            f'font-family="Menlo, monospace" font-size="{FS}" font-weight="700" '
            f'letter-spacing="{LS}" fill="%s">{BITS}</text>')
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
  <defs>
    <radialGradient id="proton">
{gradient_stops(core, hot)}
    </radialGradient>
    <clipPath id="protonClip">
      <circle cx="{lx:.0f}" cy="512" r="{R}"/>
      <circle cx="{rx:.0f}" cy="512" r="{R}"/>
    </clipPath>
  </defs>

  <rect width="1024" height="1024" fill="{bg}"/>
  <path d="{d}" fill="none" stroke="{ribbon}" stroke-width="{STROKE}" stroke-linejoin="round"/>
  <circle cx="{lx:.0f}" cy="512" r="{R}" fill="url(#proton)"/>
  <circle cx="{rx:.0f}" cy="512" r="{R}" fill="url(#proton)"/>

  {text % digit}
  <g clip-path="url(#protonClip)">
    {text % "#000000"}
  </g>
</svg>'''


WHITE = (255, 255, 255)

# One entry per appearance the asset catalog declares. Deliberately NOT the same
# image three times: iOS asks for three because it renders them in three
# different contexts.
VARIANTS = {
    # default / light: the approved design
    "light":  dict(bg="#0A0E1A", ribbon="#3FD0E0", core=WHITE, hot=(255, 176, 0),  digit="#FFFFFF"),
    # dark: deeper ground so the icon recedes on a dark home screen, with the
    # ribbon lifted slightly to hold contrast against it
    "dark":   dict(bg="#05070D", ribbon="#4FDCEC", core=WHITE, hot=(255, 184, 20), digit="#FFFFFF"),
    # tinted: iOS collapses this to a single hue, so it must carry the form in
    # luminance alone. Values are the light palette mapped through Rec.601 luma.
    "tinted": dict(bg="#0E0E0E", ribbon="#A6A6A6", core=WHITE, hot=(179, 179, 179), digit="#FFFFFF"),
}

if __name__ == "__main__":
    import pathlib
    here = pathlib.Path(__file__).parent
    for name, kw in VARIANTS.items():
        p = here / f"sophon-{name}.svg"
        p.write_text(svg(**kw))
        print(f"wrote {p.name}")
