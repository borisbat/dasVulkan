# Recording tutorial videos

dasVulkan ships its tutorial site at `doc/source/` with an `.mp4` per scene
(`doc/source/_static/tutorials/*.mp4`). Recording is **external** to the
tutorial: unlike dasImgui — where the recording driver IS the integration test
that drives the tutorial's interactions and verifies them — a dasVulkan tutorial
just *runs* (an animated shader, a draw_frame loop). There is nothing for a
driver to "click" — so we don't hide the recording seam inside a playwright-
style harness. Instead we **make the seam visible**: each tutorial file has a
clearly-marked block that opts into capture when an env var is set, and is a
no-op otherwise.

Recordings are produced on **Boris's PC** (the one this page lives on). They are
not CI, not reproducible-by-default, and Boris **eyeballs + listens to every
video** before it ships — so no canary-pixel verification, no aggregated
failures, no panic-at-stop. The page documents enough to reproduce elsewhere if
that ever becomes necessary.

> **Status:** design doc. The recorder (`vulkan_live.das`) is not yet built;
> this page documents the model we will ship. Where a piece exists and is
> reusable, it is marked **(reuse)**. Where a piece is TBD, it is marked **(new)**.

## The seam (what tutorials look like)

A tutorial's main loop stays the production loop — same `present_frame` /
`draw_frame` call as a non-recording use case. The recording hook is one line,
guarded so the everyday "run the tutorial and watch it zoom" use case pays
nothing:

```daslang
while (glfwWindowShouldClose(window) == 0) {
    glfwPollEvents()
    // ... per-frame work (compute, present, swapchain resize) ...
    let ok = present_frame(device, queue, swap, pool, sync) $(cmd; target; image_index) { ... }

    // === recording hook: capture this frame to an .apng for the tutorial mp4.
    // === No-op unless DASVULKAN_RECORD is set in the environment.
    // === See skills/recording.md for the pipeline.
    record_tick(device, queue, pool, swap, image_index)
}
```

`record_tick` returns immediately when not armed. The seam is **explicit and
labeled** — readers know exactly which lines exist to support video capture and
can ignore them when reading the tutorial as a Vulkan reference.

The recorder is armed by setting `DASVULKAN_RECORD=<basename>` before launching
the tutorial (also accepts `<basename>:<max_seconds>:<fps>` for the rare case
where the defaults don't fit). No daslang-live host, no driver script, no second
process — the tutorial captures itself.

Caption / voice lines are written as `say_begin(text, [voice=...])` calls in
the same recording-hook block. With the env var unset they are inert; with it
set, the tutorial's `record_tick` records the caption-anchor frame so
`convert_recording` can place text + voice on the same clock at mux time.

## What's reused from dasImgui

The audio + mux pipeline is backend-agnostic:

| Piece | Source | Role |
|---|---|---|
| `<dasimgui>/utils/prepare_recording.das` | **(reuse)** invoked in-place from dasImgui | scans the recording-aware tutorial for `say_begin` literals, synthesizes each unique line via Kokoro TTS (voice `bf_emma`), writes `voiceover/<stem>.manifest.json` + `<stem>.captions.json` |
| Kokoro TTS server | **(reuse)** | text → wav at `http://127.0.0.1:8880/v1`, voice `bf_emma`. Same audio brand as the dasImgui tutorials |
| daStrudel music bed | **(reuse)** | rendered to clip length, faded to `-13 dB`, muxed under the VO |
| `<dasimgui>/utils/convert_recording.das` | **(reuse, extended)** invoked in-place from dasImgui | APNG + wavs + music bed → mp4; **extended** with a caption-manifest path that adds ffmpeg `drawtext` overlays |

`say_begin(text, [voice=...])` lives in `daslib/vulkan_live.das` (new) so the
literal name `prepare_recording`'s AST scanner already looks for is found
without the tutorial needing to `require imgui`. At runtime it records the
caption-anchor frame when the recorder is armed; with `DASVULKAN_RECORD` unset
it is inert.

## What's new for dasVulkan

| Piece | Status | Role |
|---|---|---|
| `daslib/vulkan_live.das` | **(new)** | per-frame capture: copies the just-presented swapchain image to a host-visible buffer via `vkCmdCopyImage`, feeds `stbi_apng_frame`. Exposes the same `record_start` / `record_stop` / `record_status` `[live_command]` verbs as `opengl_live.das` so the existing dasImgui orchestrator can drive it unchanged later if we ever want to |
| `record_tick(...)` | **(new)** | the one-line in-tutorial hook above. Reads `DASVULKAN_RECORD`, lazily starts the recorder on first call, feeds each presented frame, auto-stops at `max_seconds` |
| Caption manifest | **(new)** | `prepare_recording` writes `voiceover/<stem>.captions.json` (text + start_frame + duration). `convert_recording`'s new caption path renders via ffmpeg `drawtext` at mux time, anchored to the same `fps_eff = frames / duration` grid as the voice |

ASCII-only is still mandatory for caption / voice text — `drawtext` can render
Unicode, but keeping the dasImgui constraint means a line can be copy-pasted
between repos.

## The pipeline

Same three-step shape as dasImgui (`prepare → record → convert`):

```bash
# 1. Pre-render the voiceover (Kokoro TTS). Skips lines whose wav already exists.
<daslang>/bin/Release/daslang -load_module <dasimgui> -load_module <dasvulkan> \
    <dasimgui>/utils/prepare_recording.das -- \
    --driver <dasvulkan>/tutorials/02_mandelbrot/window/show_mandelbrot_blit.das

# 2. Run the tutorial with capture armed. The tutorial spawns its own window,
#    drives its own frame loop, exits cleanly when the recorder hits max_seconds.
DASVULKAN_RECORD=mandelbrot_zoom <daslang>/bin/Release/daslang \
    -load_module <dasvulkan> \
    <dasvulkan>/tutorials/02_mandelbrot/window/show_mandelbrot_blit.das

# 3. Mux APNG + voiceovers + music bed + captions -> mp4.
<daslang>/bin/Release/daslang -load_module <dasimgui> -load_module <dasvulkan> \
    <dasimgui>/utils/convert_recording.das -- \
    --apng <dasvulkan>/doc/source/_static/tutorials/mandelbrot_zoom.apng
```

The cwd-independent path resolution + `<basename>.mp4.ffmpeg.txt` audit trail
from dasImgui carry over. The committed deliverable is the `.mp4`; the
`.apng`, `voiceover/*.wav`, `*.manifest.json`, `*.captions.json`,
`*.sidecar.json`, `*_music.wav`, `*.ffmpeg.txt` are all intermediates and
gitignored.

## Reproduction (if it ever has to happen elsewhere)

The recordings are produced on Boris's Windows PC. If someone needs to recreate
the setup from scratch, the moving parts are:

| Dependency | Where on Boris's machine |
|---|---|
| Vulkan SDK | `C:/VulkanSDK/1.4.350.0/` (any matching dasVulkan-CI version works) |
| daslang | `D:/Work/daScript/` (the main checkout, master HEAD; needs the `#3170` function-call landing for the Mandelbrot tutorial specifically) |
| dasVulkan | `D:/DASPKG/dasVulkan/` (this repo) |
| dasImgui | `D:/DASPKG/dasImgui/` — needed for `prepare_recording` + `convert_recording` (reused as-is) and the daStrudel music bed |
| Kokoro TTS | served at `http://127.0.0.1:8880/v1`. Start with: `D:/kokoro/.venv/Scripts/python.exe -m uvicorn server:app --host 127.0.0.1 --port 8880` (cwd `D:/kokoro`). Default voice `bf_emma` |
| ffmpeg | on PATH; any recent build (used: 6.x). Must support `libx264` + the `drawtext` filter (most Windows builds do) |
| Display | a real GPU + monitor at logical 1x. The recorder reads the swapchain image after present, so headless / null-display is not currently supported. Not an issue on Boris's machine |

The skill is best-effort for elsewhere — the recordings themselves get
eyeballed + listened-to before they ship, and a botched reproduction is
recoverable by re-running the pipeline on whatever machine has the assets.

## What this is NOT

- **Not a click / drag driver.** There is no widget state to drive or verify
  ("do what it teaches — drive it like a human" is dasImgui's rule, not ours;
  the tutorial's animation IS what it teaches, and time advances on its own).
- **Not a daslang-live script.** The tutorials stay plain `main()` apps.
- **Not CI.** Recordings are manually-driven artifact producers. The CI tests
  (lavapipe `dastest` + `docs.yml` Sphinx-W) check that the `.mp4` cited by an
  RST `.. video::` exists; they do not run the recording itself.
- **Not self-verifying.** Boris eyeballs + listens to every video before
  shipping. No canary-pixel sampling, no aggregated failures, no panic-at-stop.

## Commit structure for a recording

For scene `foo`:

1. Add the recording hook to `tutorials/.../show_foo.das` (the production
   tutorial gains the env-guarded `record_tick` line + the `say_begin` literals).
2. Run prepare → record → convert; **eyeball-review** the resulting `.mp4`.
3. Commit: `recording: foo` — the `.das` edits + `doc/source/_static/tutorials/foo.mp4`.
4. Commit: `tutorial: foo RST page` — `doc/source/tutorials/foo.rst` (`.. video:: foo.mp4`).

The recording hook + the say literals stay in the production tutorial file;
with the env var unset they are inert. This is the visible seam we chose —
readers see what supports the video capture; users running the tutorial for
fun get the bare animation.
