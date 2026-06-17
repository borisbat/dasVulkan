options gen2
options indenting = 4

// Tutorial 07 pixel oracle (lavapipe in CI, real GPU locally). 1024 particles are seeded on a
// tilted ring of radius ~1.2 with tangential velocity, then one compute dispatch advances the
// integrator by dt=1/30 before the graphics pass rasterises them as single-pixel POINT_LIST
// points (colour-by-speed palette). The oracle asserts:
//
//   - the compute->graphics handoff actually moved data through (many particles visible);
//   - the palette covers both ends (a teal-leading and a magenta-leading pixel both exist).

require dastest/testing_boost public
require particles_tut

let TEST_TIME : float = 1.0
let TEST_CAM  : float = 0.07         // camera off-axis enough to see the ring tilt

def bg(p : int3) : bool {
    // clear colour is (0.01, 0.0, 0.03) * 255 = (2.55, 0, 7.65)
    return p.x < 10 && p.y < 5 && p.z < 18
}

[test]
def test_particles_oracle(t : T?) {
    var pixels <- render_particle_swarm(TEST_TIME, TEST_CAM)

    // Walk the full frame and count non-bg pixels; POINT_LIST renders each particle as a single
    // pixel, so the count is ~N_PARTICLES (less a few overlap collisions / off-frame outliers).
    var non_bg = 0
    var saw_teal = false
    var saw_magenta = false
    var max_b = 0
    var max_r = 0
    for (y in range(PART_H)) {
        for (x in range(PART_W)) {
            let p = px(pixels, x, y)
            if (bg(p)) {
                continue
            }
            non_bg++
            if (p.z > max_b) {
                max_b = p.z
            }
            if (p.x > max_r) {
                max_r = p.x
            }
            if (p.z > 130 && p.z > p.x + 20) {
                saw_teal = true
            }
            if (p.x > 130 && p.x > p.z + 20) {
                saw_magenta = true
            }
        }
    }
    t |> success(non_bg > 500, "found > 500 non-background pixels (most of {N_PARTICLES} particles rasterised, got {non_bg})")
    t |> success(max_b > 130,  "saw a strong-blue particle pixel (cool end of the palette reached, max_b={max_b})")
    t |> success(max_r > 130,  "saw a strong-red particle pixel (hot end of the palette reached, max_r={max_r})")
    t |> success(saw_teal,     "found a teal-dominant particle (blue clearly above red, max_b={max_b})")

    delete pixels
}
