//
//  NotchOpticalSurface.metal
//  boringNotch
//
//  One curvature-driven surface for the shared glass shell. The lower lip is a
//  convex circular bevel: zero thickness at the clipped outline, steep at the
//  lip, and flat toward the interior. Distance and height gradients build the
//  normal; a broad analytic area light and Schlick Fresnel turn that normal
//  into one continuous warm rim with a wider, weaker belly. Nothing here is
//  painted as a separate stroke.
//
//  The bottom strip also carries a small voice field adapted from SiriGlass
//  (MIT, pinned commit; see THIRD_PARTY/SiriGlass/NOTICE.md). Its waterline,
//  three mirrored strands and rim-ink retreat are re-anchored to this
//  horizontal panel. The prism spectrum, bead silhouette and additive output
//  of the original are deliberately not used: every value stays premultiplied
//  and the field is confined to the lowest 24pt.
//

#include <metal_stdlib>
using namespace metal;

namespace {

// Width of the convex droplet bevel in points. A 30pt curve gives the
// shell a plump, water-drop-like meniscus instead of a thin border.
constant float kBevelWidth = 30.0;

// Height-to-normal gain. The profile is dimensionless; this scales the
// resulting slope into a visible, three-dimensional water-drop lip.
constant float kHeightSlope = 9.0;

float sanitize(float value, float fallback) {
    return isfinite(value) ? value : fallback;
}

float2 quadraticPoint(float2 a, float2 c, float2 b, float t) {
    float u = 1.0 - t;
    return u * u * a + 2.0 * u * t * c + t * t * b;
}

struct EdgeSample {
    float distance;
    float along;
};

// Closest point on the exact quadratic Bezier used by the notch's bottom
// corner. A short coarse scan seeds four Newton iterations on the squared
// distance, which is enough for a smooth 20–24pt radius in point space.
EdgeSample nearestOnCorner(float2 p, float2 a, float2 c, float2 b,
                           bool leftSide, float width, float topRadius,
                           float bottomRadius) {
    float bestT = 0.0;
    float bestDistance = 1e30;
    for (int i = 0; i <= 8; ++i) {
        float t = float(i) / 8.0;
        float2 q = quadraticPoint(a, c, b, t);
        float d = length(q - p);
        if (d < bestDistance) {
            bestDistance = d;
            bestT = t;
        }
    }

    float t = bestT;
    for (int i = 0; i < 4; ++i) {
        float2 q = quadraticPoint(a, c, b, t);
        float2 first = 2.0 * (1.0 - t) * (c - a) + 2.0 * t * (b - c);
        float2 second = 2.0 * (a - 2.0 * c + b);
        float f = dot(q - p, first);
        float fp = dot(first, first) + dot(q - p, second);
        if (fabs(fp) < 1e-5) { break; }
        t = clamp(t - f / fp, 0.0, 1.0);
    }

    float2 q = quadraticPoint(a, c, b, t);
    EdgeSample sample;
    sample.distance = length(q - p);
    sample.along = leftSide
        ? (topRadius + bottomRadius * t)
        : ((width - topRadius) - bottomRadius * t);
    return sample;
}

// Distance to the lower boundary, straight sides, and (when convex) top corners.
// The phase extends continuously around the contour from the bottom corners.
EdgeSample edgeSample(float2 p, float2 size, float topRadius, float bottomRadius,
                      float sideInset, bool topConvex) {
    float width = size.x;
    float height = size.y;
    float left = sideInset + bottomRadius;
    float right = width - sideInset - bottomRadius;

    // Use the finite bottom segment. An infinite baseline would overstate the
    // distance beside the corners and could beat the real curved boundary.
    float nearestX = clamp(p.x, left, right);
    EdgeSample best;
    best.distance = length(float2(nearestX, height) - p);
    best.along = nearestX;

    if (p.x < left) {
        float2 a = float2(sideInset, height - bottomRadius);
        float2 c = float2(sideInset, height);
        float2 b = float2(sideInset + bottomRadius, height);
        EdgeSample corner = nearestOnCorner(
            p, a, c, b, true, width, sideInset, bottomRadius
        );
        if (corner.distance < best.distance) { best = corner; }
    } else if (p.x > right) {
        float2 a = float2(width - sideInset, height - bottomRadius);
        float2 c = float2(width - sideInset, height);
        float2 b = float2(width - sideInset - bottomRadius, height);
        EdgeSample corner = nearestOnCorner(
            p, a, c, b, false, width, sideInset, bottomRadius
        );
        if (corner.distance < best.distance) { best = corner; }
    }

    if (p.y >= topRadius && p.y <= height - bottomRadius) {
        bool onLeft = p.x < width * 0.5;
        float sideDistance = abs(onLeft ? p.x - sideInset : width - sideInset - p.x);
        if (sideDistance < best.distance) {
            best.distance = sideDistance;
            float alongSide = height - bottomRadius - p.y;
            best.along = onLeft ? sideInset - alongSide : width - sideInset + alongSide;
        }
    }

    if (topConvex && topRadius > 0.5 && p.y < topRadius) {
        if (p.x < topRadius) {
            float2 a = float2(0.0, topRadius);
            float2 c = float2(0.0, 0.0);
            float2 b = float2(topRadius, 0.0);
            EdgeSample corner = nearestOnCorner(
                p, a, c, b, true, width, 0.0, topRadius
            );
            corner.along = -(height - bottomRadius - topRadius) - topRadius * ((corner.along) / max(topRadius, 1.0));
            if (corner.distance < best.distance) { best = corner; }
        } else if (p.x > width - topRadius) {
            float2 a = float2(width - topRadius, 0.0);
            float2 c = float2(width, 0.0);
            float2 b = float2(width, topRadius);
            EdgeSample corner = nearestOnCorner(
                p, a, c, b, false, width, 0.0, topRadius
            );
            corner.along = width + (height - bottomRadius - topRadius) + topRadius * (1.0 - (width - corner.along) / max(topRadius, 1.0));
            if (corner.distance < best.distance) { best = corner; }
        }
    }

    return best;
}

// Convex circular section: zero at the clipped edge, maximum slope at the
// lip, then flat once the inward depth reaches the bevel width. q is the
// normalized inward distance, so this is a lens profile rather than an edge
// ramp that fades back to the body plane.
float bevelProfile(float depth) {
    float q = clamp(depth / kBevelWidth, 0.0, 1.0);
    return sqrt(max(0.0, 2.0 * q - q * q));
}

// Low-frequency thickness undulation. It is part of the height field, so it
// bends the normal and lets one continuous belly breathe instead of drawing
// separate sinusoidal highlights.
float lipUndulation(float along, float depth, float time) {
    return sin(along * 0.017 + time * 0.16 + 0.6)
         + 0.55 * sin(along * 0.0065 - time * 0.12 + 2.3)
         + 0.38 * sin(depth * 0.13 + along * 0.0037 + time * 0.24 + 4.1);
}

float heightFromEdge(EdgeSample edge, float time) {
    if (edge.distance >= kBevelWidth * 1.75) { return 0.0; }
    float profile = bevelProfile(edge.distance);
    float ripple = lipUndulation(edge.along, edge.distance, time);
    float window = 1.0 - smoothstep(kBevelWidth, kBevelWidth * 1.75, edge.distance);
    return profile * (1.0 + 0.18 * ripple) * window;
}

// ── SiriGlass voice sources ─────────────────────────────────
// Adapted from haplollc/SiriGlass, Sources/SiriGlass/Shaders/SiriGlass.metal,
// pinned at 4ba0bb078dfa16233883e6fc072c15d160df3122 (MIT; see
// THIRD_PARTY/SiriGlass/NOTICE.md). Only the envelope, strand, lobe and
// waterline/rim-ink formulas are reused; the bead SDF, prism spectrum and
// additive coverage model are not. x is normalized across this panel.

/// The bell every strand lives under: zero at the panel's sides.
float sgEnvelope(float x) {
    float u = saturate(1.0 - x * x);
    return u * sqrt(sqrt(u));
}

struct SGStrands {
    float3 f;   // signed strand heights (pt)
    float3 c;   // centre line of each lobe (pt)
};

/// Three low-frequency strands. Each amplitude is windowed by `sgEnvelope`,
/// and each lobe leans on another strand so the mirrors form filled lenses.
SGStrands sgStrands(float x, float4 amps, float4 phases) {
    float env = sgEnvelope(x);
    SGStrands s;
    s.f = float3(amps.x * sin(0.90 * M_PI_F * x + phases.x),
                 amps.y * sin(1.30 * M_PI_F * x + phases.y),
                 amps.z * sin(1.75 * M_PI_F * x + phases.z)) * env;
    s.c = float3(0.55 * s.f.y, 0.50 * s.f.z, 0.45 * s.f.x);
    return s;
}

/// Each lobe's light at height y over the waterline: a lens between the
/// strand and its mirror, translucent inside, brighter along the middle.
/// The second and third strands land fainter through the upstream colour
/// weights (0.72, 0.52) that remain in the returned value.
float3 sgLobes(float y, SGStrands s, float edgeWidth, float fill) {
    float3 a = abs(s.f);
    float3 dy = abs(y - s.c);
    float3 thick = smoothstep(0.6, 7.0, a);
    float3 inside = 1.0 - smoothstep(a - edgeWidth, a + edgeWidth, dy);
    float3 r = dy / (a + edgeWidth);
    float3 body = inside * (0.62 - 0.22 * r * r) * (0.62 + 0.38 * thick);
    return body * fill * float3(1.0, 0.72, 0.52);
}

} // namespace

half4 notchOpticalSurfaceImpl(
    float2 position,
    half4 color,
    float4 rect,
    float4 radii,
    float4 params,
    float4 tint,
    float4 music,
    bool edgeOnly
) {
    (void)color;
    (void)tint;

    float2 size = float2(max(rect.z, 1.0), max(rect.w, 1.0));
    float2 p = position - rect.xy;

    float time = sanitize(params.x, 0.0);
    float intensity = clamp(sanitize(params.y, 1.0), 0.0, 1.0);

    float radiusLimit = max(0.0, min(size.x * 0.5, size.y));
    float rawTopRadius = sanitize(radii.x, 0.0);
    bool topConvex = rawTopRadius < 0.0;
    float topRadius = clamp(fabs(rawTopRadius), 0.0, radiusLimit);
    float bottomRadius = clamp(sanitize(radii.y, 0.0), 0.0, radiusLimit);
    float radiusSum = topRadius + bottomRadius;
    if (radiusSum > radiusLimit && radiusSum > 0.0) {
        float scale = radiusLimit / radiusSum;
        topRadius *= scale;
        bottomRadius *= scale;
    }
    float sideInset = topConvex ? 0.0 : topRadius;

    float header = clamp(sanitize(radii.z, 0.0), 0.0, size.y);

    // The adapted voice field is re-anchored to the top of the lowest 24pt,
    // so it never reaches the controls or the centre content.
    float lineY = max(header, size.y - 24.0);

    // A continuous shoulder releases its optical depth across the body.
    // Restrict the extra camera depth to a short taper; a width-only mask
    // continued through the body would create a visible black column.
    float bodyT = clamp(
        (p.y - header) / max(1.0, size.y - header), 0.0, 1.0
    );
    // Continuous optical depth. The shoulder and the transparent portion
    // share the same decay, without a threshold introducing a second band.
    float remaining = 1.0 - bodyT;
    float tau = 5.7 * pow(remaining, 2.63) + 0.30 * remaining * remaining;
    float bodyAbsorb = 1.0 - exp(-tau);
    float headerAbsorb = 1.0 - smoothstep(header, header + 24.0, p.y);
    float absorb = 1.0 - (1.0 - headerAbsorb) * (1.0 - bodyAbsorb);

    EdgeSample edge = edgeSample(p, size, topRadius, bottomRadius, sideInset, topConvex);

    // ── Rim ink retreat ─────────────────────────────────────
    // Adapted from SiriGlass's
    //   ink *= mix(0.12, 1.0, smoothstep(0.0, rimWidth, depth))
    // A glass shell stays clear inside its outline: the body's ink recedes
    // from the real left/right sides and bottom corners while the header
    // stays fully opaque and the centre keeps its continuous absorption.
    // `rise` widens the clear band toward the waterline, exactly as the
    // upstream rim widens toward its line.
    if (p.y > header) {
        float sideDistance = max(
            min(p.x - sideInset, (size.x - sideInset) - p.x), 0.0
        );
        float shellDepth = min(sideDistance, edge.distance);
        float rise = smoothstep(lineY - 60.0, lineY, p.y);
        float rimWidth = mix(3.5, 18.0, rise * rise);
        float rimClear = mix(
            0.12, 1.0, smoothstep(0.0, rimWidth, shellDepth)
        );
        bodyAbsorb *= mix(1.0, rimClear, smoothstep(header + 4.0, header + 46.0, p.y));
        absorb = 1.0 - (1.0 - headerAbsorb) * (1.0 - bodyAbsorb);
    }

    float3 normal = float3(0.0, 0.0, 1.0);
    float band = 0.0;
    float fresnel = 0.035;
    float3 reflected = float3(0.0, 0.0, -1.0);

    if (edge.distance < kBevelWidth) {
        // The normal comes from the real distance field through the convex
        // height profile: the lip is steep, the interior flattens.
        const float eps = 0.7;
        float h0 = heightFromEdge(edge, time);
        float hx = heightFromEdge(
            edgeSample(p + float2(eps, 0.0), size, topRadius, bottomRadius, sideInset, topConvex), time
        );
        float hy = heightFromEdge(
            edgeSample(p + float2(0.0, eps), size, topRadius, bottomRadius, sideInset, topConvex), time
        );
        float2 gradient = float2(hx - h0, hy - h0) / eps;
        normal = normalize(float3(-gradient * kHeightSlope, 1.0));

        band = 1.0 - smoothstep(0.0, kBevelWidth, edge.distance);
        band = pow(saturate(band), 1.1);

        float3 viewDirection = normalize(float3(
            (p.x - size.x * 0.5) / max(size.x, 1.0) * 0.45,
            (p.y - size.y) / max(size.y, 1.0) * 0.25,
            0.86
        ));
        float ndv = saturate(dot(normal, viewDirection));
        fresnel = 0.035 + 0.965 * pow(1.0 - ndv, 5.0);
        reflected = reflect(-viewDirection, normal);
    }

    // Soft analytic environment. The outward-facing lip mirrors the desktop
    // side of the panel, so the warm area source sits below and in front of
    // the surface; a very broad reflected-down field keeps the whole straight
    // edge continuous, and two weak cool lobes catch the turning corners. The
    // slow drift lives in the environment, never in a surface gate.
    float3 keyDirection = normalize(float3(
        0.10 + 0.04 * sin(time * 0.13 + 0.4), 0.58, 0.81
    ));
    float3 rimDirection = normalize(float3(0.0, 0.72, 0.69));
    float3 leftDirection = normalize(float3(-0.72, 0.36, 0.59));
    float3 rightDirection = normalize(float3(0.72, 0.36, 0.59));

    float key = saturate(dot(reflected, keyDirection));
    float rim = saturate(dot(reflected, rimDirection));
    float sideLeft = saturate(dot(reflected, leftDirection));
    float sideRight = saturate(dot(reflected, rightDirection));

    float keyEnv = key * key * key;
    float rimEnv = rim * rim;
    float sideEnv = 0.5 * (sideLeft * sideLeft + sideRight * sideRight);
    float cornerTurn = saturate(abs(normal.x) * 1.8);
    float downField = 0.35 + 0.65 * saturate(0.5 + 0.5 * reflected.y);

    float core = exp(-edge.distance / 3.6);
    float belly = pow(band, 1.35);
    float rimLight = fresnel * (0.36 + 1.05 * rimEnv) * core;
    // Side light follows the real turned normal: it grows on the corner
    // curves and stays quiet along the straight edge, so the corners read as
    // thickness rather than as a second uniform contour.
    float sideWeight = 0.10 + 0.20 * cornerTurn;
    float bellyLight = fresnel
        * (0.10 * downField + 0.55 * keyEnv + sideWeight * sideEnv) * belly;
    // Light through the convex face becomes a short sheen where the reflected
    // ray intersects the key source. Leave the flat pane and hard edge clear.
    float face = smoothstep(1.5, 6.0, edge.distance)
        * (1.0 - smoothstep(9.0, 16.0, edge.distance));
    float wideBelly = face * (0.018 * downField + 0.079 * keyEnv + 0.031 * sideEnv);
    float cornerLight = fresnel * 0.20 * cornerTurn * belly;
    float light = (0.95 * rimLight + 0.70 * bellyLight
        + 0.60 * wideBelly + 0.35 * cornerLight) * intensity;
    light *= smoothstep(header, header + 20.0, p.y);
    light = min(light, 0.65);

    // ── SiriGlass voice field and music crest ────────────
    // The lower edge keeps a soft idle field. Audio lifts the glow and its
    // internal reflections together within the lower glass.
    float activity = clamp(sanitize(params.w, 0.0), 0.0, 1.0);
    float fieldAlpha = 0.0;

    float yDepth = p.y - lineY;
    float bandGate = smoothstep(0.0, 8.0, yDepth);
    float fromBottom = size.y - p.y;
    if (music.w > 0.5 && intensity > 0.001 && fromBottom < 37.0 && p.y > header + 4.0) {
        float3 bands = saturate(music.xyz);
        float x = (p.x - size.x * 0.5) / max(size.x * 0.5, 1.0);

        // The bass plume climbs, while the midrange sends two softer pools
        // out along the lower glass. Treble brightens their feathered edges.
        float bassHeight = 5.7 + 25.0 * bands.x;
        float bassDepth = (fromBottom - bassHeight) / (3.8 + 2.4 * bands.x);
        float bassSpread = 0.22 + 0.24 * bands.x;
        float bassX = (x + 0.045 * bands.y * bassDepth) / bassSpread;
        float bass = exp(-(bassX * bassX + bassDepth * bassDepth));
        float bassHalo = exp(-(bassX * bassX * 0.52 + bassDepth * bassDepth * 0.34));

        float sideCentre = 0.24 + 0.30 * bands.y;
        float sideHeight = 5.0 + 12.0 * bands.y + 3.0 * bands.x;
        float sideDepth = (fromBottom - sideHeight + 2.1 * x) / (4.4 + 2.0 * bands.z);
        float sideX = (abs(x + 0.038 * bands.x) - sideCentre) / (0.16 + 0.085 * bands.y);
        float sides = exp(-(sideX * sideX + sideDepth * sideDepth));
        float sideHalo = exp(-(sideX * sideX * 0.56 + sideDepth * sideDepth * 0.48));

        float boundary = (1.0 - smoothstep(30.0, 37.0, fromBottom))
                       * smoothstep(header + 4.0, header + 15.0, p.y)
                       * smoothstep(1.3, 4.5, edge.distance)
                       * (1.0 - smoothstep(0.69, 0.91, abs(x)));
        float bassGain = smoothstep(0.025, 0.56, bands.x);
        float sideGain = smoothstep(0.03, 0.68, max(bands.y, 0.58 * bands.z));
        float centreLight = bassGain * (0.28 * bass + 0.13 * bassHalo);
        float sideLight = sideGain * ((0.17 + 0.07 * bands.z) * sides + 0.09 * sideHalo);
        fieldAlpha = min(0.45, (centreLight + sideLight) * intensity * boundary);
    }
    if (bandGate > 0.001 && intensity > 0.001) {
        float phaseTime = time * 0.74 + 0.20;
        // A short wake starts under the cutout. In an active state, small
        // packets continue to travel through the glass with different speeds.
        float wake = smoothstep(0.0, 0.20, phaseTime)
            * (1.0 - smoothstep(0.34, 1.55, phaseTime));
        float reach = mix(0.24, 0.94, smoothstep(0.0, 0.82, phaseTime));
        float x = clamp((p.x - size.x * 0.5) / max(size.x * 0.5, 1.0), -1.0, 1.0);
        float wakeFront = 1.0 - smoothstep(reach - 0.42, reach, abs(x));
        float first = pow(0.5 + 0.5 * sin(phaseTime * 2.62 - 0.9), 3.0);
        float second = pow(0.5 + 0.5 * sin(phaseTime * 1.71 + 0.6), 4.0);
        float firstX = 0.44 * sin(phaseTime * 1.29 - 0.34);
        float secondX = -0.36 * sin(phaseTime * 1.03 + 1.3);
        float packetA = exp(-pow((x - firstX) / 0.34, 2.0));
        float packetB = exp(-pow((x - secondX) / 0.26, 2.0));
        float current = 0.12 + first * packetA * 0.68 + second * packetB * 0.54;
        float local = saturate(wake * wakeFront * 0.66 + mix(0.70, 1.10, activity) * current);
        float fieldLevel = 0.43 + 0.57 * local;
        // The bright body has two tapered ends. Only the glass rim extends
        // farther toward the corners.
        float fieldX = clamp(x / 0.78, -1.0, 1.0);
        float env = sgEnvelope(fieldX);

        // Anchor the luminous body to the inner curve of the same bevel,
        // including the upturn at the corners, with no projected floor halo.
        float lift = 8.0 + 3.0 * local + 0.85 * sin(phaseTime * 1.61 - x * 4.4);
        float y = lift - edge.distance;
        float4 amps = float4(5.9, 3.7, 2.1, 0.0) * (0.58 + 0.95 * local);
        float4 phases = float4(
            0.8 + 2.2 * phaseTime - 2.1 * x,
            2.3 - 1.65 * phaseTime,
            4.0 + 1.19 * phaseTime,
            0.0
        );
        SGStrands strands = sgStrands(fieldX, amps, phases);
        float3 lobes = sgLobes(y, strands, 0.85 + 0.48 * local, 0.88 + 0.12 * local);
        float lobePeak = 1.0 - exp(-1.34 * (lobes.x + lobes.y + lobes.z));
        float3 outside = max(abs(y - strands.c) - abs(strands.f), 0.0);
        float3 halo3 = exp(-outside / (2.9 + 2.3 * local));
        float halo = (halo3.x + halo3.y + halo3.z) / 3.0;

        float inward = smoothstep(1.3, 4.3, edge.distance);
        float ends = 1.0 - smoothstep(0.56, 0.88, abs(x));
        float gate = intensity * bandGate * fieldLevel * env * inward * ends;
        float spectralCore = lobePeak * (0.33 + 0.42 * local);
        float haloLight = halo * (0.06 + 0.13 * local);
        float ambientWeight = music.w > 0.5 ? 0.36 : 1.0;
        float ambient = (spectralCore * 1.04 + haloLight) * gate * ambientWeight;
        fieldAlpha = min(0.45, fieldAlpha + ambient * (1.0 - fieldAlpha));

        // The waves can thin the remaining ink. Adding absorption along the
        // arc makes a visible grey seam on light backgrounds.
        float lobeThin = 0.06 * lobePeak * fieldLevel;
        absorb *= 1.0 - lobeThin * gate * ambientWeight;
    }
    float3 fieldRGB = float3(fieldAlpha * 0.97);

    if (edgeOnly) {
        // Native clear glass owns the body transmission. This coating models a
        // plump water droplet lit by a directional studio key light:
        //   1. A crisp hairline meniscus right inside the outline
        //   2. A directional specular glint on the lit curve + softer opposite bounce
        //   3. A broad convex lens belly & soft bottom caustic glow
        // Zero colourful rainbow bands.
        float interior = smoothstep(0.0, 0.9, edge.distance);
        float shoulder = topConvex
            ? smoothstep(header * 0.20, header + 16.0, p.y)
            : smoothstep(header, header + 18.0, p.y);
        float bevelWindow = 1.0 - smoothstep(16.0, kBevelWidth, edge.distance);

        // 2D outward edge normal approximation for directional droplet glint.
        float2 pNorm = normalize(float2(
            (p.x - size.x * 0.5) / max(size.x * 0.5, 1.0),
            (p.y - size.y * 0.45) / max(size.y * 0.55, 1.0)
        ) + float2(1e-4));
        float2 key2D = normalize(float2(
            -0.52 + 0.08 * sin(time * 0.18),
            -0.85 + 0.05 * cos(time * 0.14)
        ));
        // Near the meniscus the actual bevel normal, not the panel centre,
        // sets the glint direction. Keep the radial direction for its flat tail.
        float2 slope = normal.xy;
        float2 rimNormal = normalize(mix(pNorm, slope, smoothstep(0.08, 0.65, length(slope))) + float2(1e-4));
        float facing = pow(saturate(dot(rimNormal, key2D)), 2.2)
                     + 0.48 * pow(saturate(dot(rimNormal, -key2D)), 2.8);
        float bottomBias = smoothstep(header, size.y, p.y);

        // Hairline meniscus + directional glint + convex Fresnel body light.
        float hair = exp(-pow(edge.distance / 1.15, 2.0)) * (0.15 + 0.53 * facing + 0.12 * bottomBias);
        float glint = exp(-pow(edge.distance / 2.2, 2.0)) * facing * 0.45;
        float lensBody = light * (0.85 + 0.35 * bottomBias) * bevelWindow;

        // Soft caustic pool gathered near the bottom center of the water drop.
        float xNorm = (p.x - size.x * 0.5) / max(size.x * 0.5, 1.0);
        float causticY = smoothstep(size.y - 28.0, size.y - 2.0, p.y)
                       * (1.0 - smoothstep(size.y - 2.0, size.y, p.y) * 0.2);
        float caustic = causticY * exp(-pow(xNorm / 0.58, 2.0)) * 0.14;

        float specLum = (hair * 0.58 + glint + lensBody * 0.78 + caustic) * intensity * interior * shoulder;
        float3 dropletWhite = float3(1.0);
        float3 combinedRGB = dropletWhite * specLum + fieldRGB * 0.86;
        float alpha = clamp(specLum + fieldAlpha * 0.86, 0.0, 0.58);
        float3 rgb = min(combinedRGB, float3(alpha));
        if (!isfinite(rgb.x) || !isfinite(rgb.y) || !isfinite(rgb.z) || !isfinite(alpha)) {
            return half4(0.0);
        }
        return half4(half3(rgb), half(alpha));
    }

    float3 reflection = float3(light) + fieldRGB;
    float reflectionAlpha = clamp(light + fieldAlpha, 0.0, 0.65);
    reflection = clamp(reflection, float3(0.0), float3(reflectionAlpha));

    float alpha = clamp(
        absorb + reflectionAlpha * (1.0 - absorb), 0.0, 1.0
    );
    float3 rgb = min(reflection, float3(alpha));

    if (!isfinite(rgb.x) || !isfinite(rgb.y) || !isfinite(rgb.z)
        || !isfinite(alpha)) {
        return half4(0.0);
    }
    return half4(half3(rgb), half(alpha));
}

// Shared implementation keeps the original desktop-optical entry unchanged.
[[ stitchable ]] half4 notchOpticalSurface(float2 position, half4 color, float4 rect,
                                         float4 radii, float4 params, float4 tint, float4 music) {
    return notchOpticalSurfaceImpl(position, color, rect, radii, params, tint, music, false);
}

[[ stitchable ]] half4 notchEdgeOptics(float2 position, half4 color, float4 rect,
                                     float4 radii, float4 params, float4 tint, float4 music) {
    return notchOpticalSurfaceImpl(position, color, rect, radii, params, tint, music, true);
}

// Samples the moving display texture using the lab's convex Snell profile.
// The undeformed centre reads the exact desktop coordinate; a local change
// in ray angle bends lines only at the curved lower and side edges.
struct NotchBackdropVertex {
    float4 position [[position]];
    float2 uv;
};

vertex NotchBackdropVertex notchBackdropVertex(uint index [[vertex_id]]) {
    float2 uv = float2((index << 1) & 2, index & 2);
    return { float4(uv * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0), uv };
}

float3x2 notchRefractionOffsets(float2 p, float2 size, float2 radii, float intensity) {
    // The lower/side optics use the actual straight-side inset. Convex top
    // corners are encoded by a negative top radius and have no shoulder inset.
    float rawTop = radii.x;
    bool topConvex = rawTop < 0.0;
    float topRadius = max(fabs(rawTop), 0.0);
    float sideInset = topConvex ? 0.0 : topRadius;
    float side = min(p.x - sideInset, size.x - sideInset - p.x);
    if (size.y - p.y >= radii.y + kBevelWidth && side >= kBevelWidth) {
        return float3x2(float2(0.0), float2(0.0), float2(0.0));
    }
    float depth = edgeSample(p, size, topRadius, radii.y, sideInset, topConvex).distance;
    const float eps = 0.7;
    float dx = edgeSample(p + float2(eps, 0.0), size, topRadius, radii.y, sideInset, topConvex).distance - depth;
    float dy = edgeSample(p + float2(0.0, eps), size, topRadius, radii.y, sideInset, topConvex).distance - depth;
    float2 inward = float2(dx, dy);
    if (p.y < size.y - radii.y && side < depth) {
        inward = float2(p.x < size.x * 0.5 ? 1.0 : -1.0, 0.0);
        depth = side;
    }

    float q = saturate(depth / kBevelWidth);
    float section = bevelProfile(depth);
    float slope = (1.0 - q) / max(section, 0.08);
    float theta = atan(slope * 0.75);
    // Per-channel refraction, with the strongest dispersion in the bevel.
    // A smooth travel bound preserves channel separation at grazing angles.
    float dispersion = 1.0 - smoothstep(0.18, 0.85, q);
    float3 ior = 1.46 + dispersion * float3(-0.043, 0.0, 0.058);
    float3 transmitted = asin(sin(theta) / ior);
    float3 travel = tan(theta - transmitted) * kBevelWidth * (1.0 + 0.55 * section);
    travel = (16.0 * travel / (15.0 + travel))
        * (1.0 - smoothstep(0.55, 1.0, q)) * intensity;
    float2 direction = inward / max(length(inward), 0.001);
    return float3x2(direction * travel.r, direction * travel.g, direction * travel.b);
}

// The hosted Metal layer also masks itself using the SwiftUI path's exact
// quadratics, so the texture cannot spill into the transparent window corners.
float notchBackdropCoverage(float2 p, float2 size, float2 radii) {
    float top = abs(radii.x);
    float inset = max(radii.x, 0.0);
    if (top > 0.0 && p.y < top) {
        float t = sqrt(saturate(p.y / top));
        inset = radii.x < 0.0 ? top * (1.0 - t) * (1.0 - t)
                             : top * (2.0 * t - t * t);
    } else if (size.y - p.y < radii.y) {
        float t = 1.0 - sqrt(saturate((size.y - p.y) / radii.y));
        inset += radii.y * t * t;
    }
    float inward = min(p.x, size.x - p.x) - inset;
    float aa = max(length(float2(dfdx(inward), dfdy(inward))), 0.25);
    return smoothstep(-aa, aa, inward);
}

fragment float4 notchRefractedBackdrop(
    NotchBackdropVertex input [[stage_in]],
    constant float4 *u [[buffer(0)]],
    texture2d<float> desktop [[texture(0)]]
) {
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 size = u[0].xy;
    float2 p = input.uv * size;
    float coverage = notchBackdropCoverage(p, size, u[0].zw);
    if (coverage <= 0.0) return float4(0.0);
    float2 uv = u[1].xy + p * u[1].zw;
    float3x2 bend = notchRefractionOffsets(p, size, u[0].zw, u[2].x);
    // Leave the pane to the live compositor. The capture can lag a
    // Space/window change or omit protected content; never let an opaque
    // texture cover the actual app window through the entire glass.
    float displacement = length(bend[1]);
    float frostedEdge = smoothstep(0.3, 7.0, displacement);
    float alpha = coverage * 0.48 * frostedEdge;
    if (alpha <= 0.0) return float4(0.0);
    float red = desktop.sample(s, uv + bend[0] * u[1].zw).r;
    float green = desktop.sample(s, uv + bend[1] * u[1].zw).g;
    float blue = desktop.sample(s, uv + bend[2] * u[1].zw).b;
    // Scatter the transmitted light locally around the refracted ray. This
    // softens real high contrast detail on the bevel without a flat glow
    // layer or blur over the clear centre. Keep the sharp spectral core.
    float2 center = uv + bend[1] * u[1].zw;
    float2 normal = bend[1] / displacement;
    float2 tangent = float2(-normal.y, normal.x);
    float radius = mix(1.2, 3.0, frostedEdge);
    float2 dx = tangent * radius * u[1].zw;
    float2 dy = normal * radius * 0.70 * u[1].zw;
    float3 spread = (desktop.sample(s, center + dx).rgb + desktop.sample(s, center - dx).rgb
                   + desktop.sample(s, center + dy).rgb + desktop.sample(s, center - dy).rgb) * 0.25;
    float3 color = mix(float3(red, green, blue), spread, 0.43 * frostedEdge);
    return float4(color * alpha, alpha);
}
