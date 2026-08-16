# Sophon app icon

The icon is **generated, not drawn**. `sophon-icon.py` emits one SVG per iOS
appearance; `render.sh` rasterises them to the 1024×1024 PNGs the asset catalog
consumes and copies them into `../Sophon/Assets.xcassets/AppIcon.appiconset/`.

```bash
ios/Sophon/icon/render.sh      # regenerate SVGs + PNGs, install into the catalog
```

Both the SVGs and the PNGs are committed. You only need to run this after
changing something in `sophon-icon.py`.

## The design

An **infinity symbol** — two protons in entanglement — with a small circle at the
heart of each loop, and a horizontal binary string running between them for the
data passing back and forth.

The curve is a **lemniscate of Bernoulli**, sampled from its own parametric
equation at 64 points and joined with Catmull-Rom→Bézier conversion. That gives
C1 continuity everywhere, so the loop is smooth by construction rather than by a
hand-placed approximation.

A few constants carry decisions worth not re-litigating:

| Constant | Why |
|---|---|
| `Y_SCALE = 1.35` | A true Bernoulli lemniscate is 2.83:1 and reads as thin. This is an affine stretch, so smoothness is preserved. |
| `FOCUS = 0.612a` | The protons sit at each loop's **widest point**, not the curve's true foci (`0.707a`). The real foci sit visibly outboard and read as sliding toward the tips. |
| `K = 4` | Exponent for the proton gradient. The yellow contribution is weighted `t⁴`, so the core stays white and heat appears only near the circumference. `K=6` is prettier at 1024px but the warm rim vanishes below ~100px. |

The binary string is drawn **twice**: once in white, then again in black clipped
to the two protons. That is what makes it legible where it crosses the bright
cores — a single-colour string would disappear against either the white centre or
the dark background.

## Appearances

Three variants, and they are **deliberately not the same image three times**:

- **light** — the design as approved.
- **dark** — deeper ground so the icon recedes on a dark home screen, ribbon
  lifted slightly to hold contrast against it.
- **tinted** — iOS collapses this to a single hue, so it must carry the form in
  luminance alone. The palette is the light one mapped through Rec.601 luma.

> `ios/FirstContact` ships `icon-light.png` and `icon-dark.png` byte-identical
> (55,989 bytes each) — it declares an appearance-adaptive icon while supplying
> one image for two of the three. Don't copy that here; `render.sh` produces
> three genuinely different files and it is worth keeping them that way.

## Known constraints

- **The digits are live `Menlo` text, not outlines.** Menlo is a macOS system
  font so `render.sh` resolves it, but the SVGs are not self-contained. Convert
  the text to paths before handing these to any tool that does not have Menlo —
  notably **Icon Composer**, if the icon is ever rebuilt as a layered `.icon` for
  Liquid Glass (#216 discusses that route).
- **Chrome is the rasteriser.** macOS ships no SVG CLI converter and this repo
  has no image stack; any replacement that renders SVG to a 1024×1024 PNG works.
- The asset catalog takes a flat 1024 PNG per appearance. That is the classic
  path, not the iOS 26 layered-icon path.
