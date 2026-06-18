options gen2
options indenting = 4

// Tutorial 09 pixel-oracle gate (lavapipe in CI, real GPU locally). The scene is the synthwave
// cube from tutorial 04; the load-bearing test is the same set of structural asserts plus one
// MSAA-specific check: a pixel near the cube's outer silhouette must be a partial blend of cube
// and background (something only 4x MSAA can produce -- a 1x pipeline would write either full
// cube color or full clear color at that pixel).

require dastest/testing_boost public
require msaa_tut

let TEST_TIME : float = 1.0
let TEST_CAM  : float = 0.18

def bg(p : int3) : bool {
    return p.x < 12 && p.y < 4 && p.z < 22
}

[test]
def test_msaa_oracle(t : T?) {
    var pixels <- render_msaa_cube(TEST_TIME, TEST_CAM)

    // four corners are background -- the cube does not fill the frame. Top corners are sampled
    // BELOW the 16-row mode-indicator strip (24px margin) so the indicator's bright colour
    // doesn't trip the bg() check.
    t |> success(bg(px(pixels, 8, 24)),                      "top-left corner is the clear color")
    t |> success(bg(px(pixels, MSAA_W - 8, 24)),             "top-right corner is the clear color")
    t |> success(bg(px(pixels, 8, MSAA_H - 8)),              "bottom-left corner is the clear color")
    t |> success(bg(px(pixels, MSAA_W - 8, MSAA_H - 8)),     "bottom-right corner is the clear color")

    // central box is dominantly cube
    var cube_hits = 0
    let cx = MSAA_W / 2
    let cy = MSAA_H / 2
    for (j in range(20)) {
        for (i in range(20)) {
            let dy = -100 + j * 10
            let dx = -100 + i * 10
            if (!bg(px(pixels, cx + dx, cy + dy))) {
                cube_hits++
            }
        }
    }
    t |> success(cube_hits >= 380, "central 200x200 box is dominantly cube, not background ({cube_hits}/400)")

    // synthwave palette samples (same as tutorial 04 -- the shader didn't change)
    var saw_magenta = false
    var saw_cyan = false
    for (j in range(50)) {
        for (i in range(50)) {
            let y = cy - 100 + j * 4
            let x = cx - 100 + i * 4
            let p = px(pixels, x, y)
            if (p.x > 140 && p.z > 120 && p.y < 120) {
                saw_magenta = true
            }
            if (p.z > 120 && p.y > 100 && p.x < 40) {
                saw_cyan = true
            }
        }
    }
    t |> success(saw_magenta, "found a magenta pixel inside the cube (synthwave sky band sampled)")
    t |> success(saw_cyan,    "found a cyan pixel inside the cube (perspective-grid sampled)")

    // MSAA-specific: scan horizontal lines through the cube and count "edge mix" pixels -- pixels
    // neither pure-background nor pure-cube-foreground (any RGB component in the gradient band).
    // 4x MSAA with edge coverage 1/4, 2/4, 3/4 produces these resolved gradients; 1x rasterization
    // produces ZERO of them (every pixel is either covered or not). Scan 21 rows across the cube's
    // vertical extent so we hit at least one near-horizontal silhouette transition.
    var edge_mix_count = 0
    for (k in range(21)) {
        let scan_y = cy - 100 + k * 10
        for (x in range(MSAA_W)) {
            let p = px(pixels, x, scan_y)
            // partial-cover gradient band: avoid pure-bg (B < 18) and pure-cube-foreground (B > 200).
            // Blue is the most sensitive channel: bg.b ~15, lit-cube cyan-grid pixels ~255.
            if (p.z >= 18 && p.z <= 200) {
                edge_mix_count++
            }
        }
    }
    t |> success(edge_mix_count >= 50, "MSAA produced edge-blend pixels on the cube silhouette ({edge_mix_count})")

    delete pixels
}
