# SiriGlass source record

Source: https://github.com/haplollc/SiriGlass
Pinned commit: 4ba0bb078dfa16233883e6fc072c15d160df3122
Upstream path: Sources/SiriGlass/Shaders/SiriGlass.metal
Copyright (c) 2026 Haplo LLC. MIT; see LICENSE.

The ported portions are identified below. The complete upstream source is available at the pinned commit.

## Actual adaptation

Production file: `boringNotch/components/Notch/NotchOpticalSurface.metal`

Reused (ported, `sg` prefix where upstream already used one):

- `sgEnvelope` — the bell that windows every strand to zero at the sides.
- `SGStrands` / `sgStrands` — three differently-phased low-frequency strands
  and their interleaved lobe centre lines (`s.c`).
- `sgLobes` — the filled lens between each strand and its mirror, including
  the upstream `(1.0, 0.72, 0.52)` strand weighting.
- The rim ink retreat from the `ink *= mix(0.12, 1.0, smoothstep(0.0,
  rimWidth, depth))` line, adapted to this panel's real left/right side
  distance and bottom-corner distance.
- The under-the-line arc, lit layer, soft shadow and foot glow formulas,
  re-anchored to the strip's waterline.

Deliberately not reused:

- The `sgPill` / `sgBead` / `sgSmin` bead SDF and Dynamic Island shape; this
  project keeps its existing horizontal `NotchShape` outline.
- The seven-wavelength prism spectrum array, `kSpectrum`, the spectral loop
  and `kTint`. The adaptation is neutral warm white with a quiet cool strand
  and a very weak cover-colour stain.
- Microphone/voice levels, audio capture, WindowReader and any render-window
  or UIKit plumbing. Notch Harbor supplies its own Core Audio music signal.
- The additive output model. Upstream permits RGB > alpha for additive light;
  this adaptation keeps every value premultiplied and clamps reflection to its
  own coverage before compositing.

## Differences from upstream

- The field is horizontal and confined to the lowest ~24pt of the expanded
  notch; the upstream vertical bead's waterline, ink and lobes are
  re-anchored to that strip.
- The clear native glass and the ink/light coating are enabled together in
  normal glass mode, independently of optional ScreenCaptureKit capture.
  The existing quadratic-edge height field now continues along both side
  faces, with reflected light fading below the opaque hardware header.
- The hardware header stays an opaque black cutout. Upstream pours the whole
  bead in ink and clears it with `extra.x`; that growth state is not used.
- Motion comes from the existing `TimelineView`/`NotchLightClock` gate and
  Reduce Motion. A new `params.w` carries `motionActive`; the host uses a capped timeline for idle, transition and music states.
- The original file's uniforms (`island`, `drop`, `form`, `amps`, `phases`,
  `light`, `extra`) are not reused; the strip derives its amplitudes, phases
  and activity from the panel size and the motion parameter.

Packaging: `scripts/build-local.sh` copies this NOTICE and the upstream
LICENSE to `Notch Harbor.app/Contents/Resources/ThirdParty/SiriGlass/`.
