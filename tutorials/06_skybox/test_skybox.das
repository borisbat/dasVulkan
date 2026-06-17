options gen2
options indenting = 4

// Tutorial 06 pixel oracle (lavapipe in CI, real GPU locally). The skybox is a procedural sky
// (zenith blue + warm horizon + sun glow + dark ground) sampled from a unit cubemap. At
// (camera_t=0.5, time=0) the camera sits at (-4, 0, 0) looking back at the origin, so the
// sun-bearing +X / +Y / +Z octant is in front. The oracle asserts a handful of structural
// properties the render must have:
//
//   - the frame is not all-clear (the skybox rendered something);
//   - at least one bright sun-tone pixel exists (the sun glow reached the rasteriser);
//   - at least one blue-dominant pixel exists (zenith blue band sampled);
//   - the bottom-centre samples the ground hemisphere (darker than the upper band).

require dastest/testing_boost public
require skybox_tut

let TEST_TIME : float = 0.0
let TEST_CAM  : float = 0.75        // camera at (0, 0, -4), looking +Z -- sun (+X, +Y, +Z) octant is in front

[test]
def test_skybox_oracle(t : T?) {
    var pixels <- render_skybox(TEST_TIME, TEST_CAM)

    // not all clear -- skybox covers the frame end-to-end since every NDC pixel maps to a sampling
    // direction inside the cubemap, so a meaningful mean luminance must be present.
    var sum_lum = 0
    let stride = 16
    for (j in range(SKY_H / stride)) {
        for (i in range(SKY_W / stride)) {
            let p = px(pixels, i * stride, j * stride)
            sum_lum += p.x + p.y + p.z
        }
    }
    let n = (SKY_W / stride) * (SKY_H / stride)
    let mean_lum = sum_lum / (n * 3)
    t |> success(mean_lum > 50, "mean luminance > 50 (skybox is not the clear colour, got {mean_lum})")

    // somewhere in the frame, a warm sun-tone pixel (R high, G moderate, B lower)
    var saw_sun_tone = false
    for (j in range(64)) {
        for (i in range(64)) {
            let x = i * (SKY_W / 64)
            let y = j * (SKY_H / 64)
            let p = px(pixels, x, y)
            if (p.x > 200 && p.y > 150 && p.z < p.x - 20) {
                saw_sun_tone = true
            }
        }
    }
    t |> success(saw_sun_tone, "found a warm sun-tone pixel (warm horizon / sun glow visible)")

    // somewhere in the frame, a blue-dominant zenith pixel (B > R + 20 and B > G - 20)
    var saw_zenith = false
    for (j in range(64)) {
        for (i in range(64)) {
            let x = i * (SKY_W / 64)
            let y = j * (SKY_H / 64)
            let p = px(pixels, x, y)
            if (p.z > p.x + 20 && p.z > 60) {
                saw_zenith = true
            }
        }
    }
    t |> success(saw_zenith, "found a zenith-blue pixel (zenith band sampled)")

    // top band (rows < 1/4) is on average brighter than bottom band (rows > 3/4) -- the bottom of
    // the swarm samples the -Y face which is dimmer (ground).
    var top_sum = 0
    var bot_sum = 0
    let band_h = SKY_H / 4
    for (j in range(band_h / stride)) {
        for (i in range(SKY_W / stride)) {
            let pt = px(pixels, i * stride, j * stride)
            top_sum += pt.x + pt.y + pt.z
            let pb = px(pixels, i * stride, SKY_H - 1 - j * stride)
            bot_sum += pb.x + pb.y + pb.z
        }
    }
    t |> success(top_sum > bot_sum, "top band brighter than bottom band ({top_sum} > {bot_sum}; ground darker than sky)")

    delete pixels
}
