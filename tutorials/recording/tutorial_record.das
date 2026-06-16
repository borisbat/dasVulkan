options gen2
options indenting = 4
options rtti                                 // dasOPENAI's SpeechRequest has @optional fields

// Shared tutorial recording harness (manual, local-only). Drivers use either the silent path
// (capture_apng + convert_to_mp4) or the voiced one (add say() lines, then prepare_voiceover +
// convert_to_mp4_voiced for ffmpeg drawtext captions + Kokoro VO mixed under a faded music bed).
//
//   capture_apng           stream a parametric frame(i) render into an APNG intermediate
//   convert_to_mp4         render a strudel music bed to the clip length, then ffmpeg-mux APNG + faded
//                          bed into the committed .mp4 (only the .mp4 is tracked; APNG/wav are scratch)
//   say(frame, caption [, voice])    register a caption + voice anchor at frame index
//   prepare_voiceover(apng)          hit Kokoro for each registered say() line, write wavs
//   convert_to_mp4_voiced(apng,...)  convert_to_mp4 + voiceover wavs (delayed/mixed) + drawtext captions
//
// This is NOT a regression gate -- each tutorial's pixel oracle (its [test]) is. This folder is
// named `recording` so the tutorials .das_test skips it in CI (stbimage + audio aren't loaded there).

module tutorial_record

require stbimage
require daslib/fio
require math
require openai/openai_audio                 // speech / SpeechRequest / openai_client
require audio/audio_wav                     // read_wav (for measuring voiceover durations)
require strings
require daslib/strings_boost

// The APNG writer flips rows top-down for GL glReadPixels (bottom-up) data; Vulkan readback is
// already top-down, so we pre-flip each frame to cancel the writer's flip (apng_write_impl.h:
// "callers should flip in their pixel buffer instead").
def private flip_rows_inplace(var pixels : array<uint8>; w, h : int) {
    let row = w * 4
    for (y in range(h / 2)) {
        let top = y * row
        let bot = (h - 1 - y) * row
        for (i in range(row)) {
            let tmp = pixels[top + i]
            pixels[top + i] = pixels[bot + i]
            pixels[bot + i] = tmp
        }
    }
}

//! Stream RGBA8 frames into an APNG. `render(frame)` returns one w*h*4 RGBA8 buffer per frame index;
//! `frame_ms` is the per-frame delay stored in the APNG. Returns true on success.
def public capture_apng(apng_path : string; w, h, n_frames, frame_ms : int;
                        render : block<(frame : int) : array<uint8>>) : bool {
    var writer = stbi_apng_begin(apng_path, w, h, 4)
    if (writer == null) {
        to_log(LOG_ERROR, "[record] stbi_apng_begin failed for {apng_path}\n")
        return false
    }
    var ok = true
    for (f in range(n_frames)) {
        var pixels <- invoke(render, f)
        if (length(pixels) < w * h * 4) {
            to_log(LOG_ERROR, "[record] frame {f}: short buffer ({length(pixels)} < {w * h * 4})\n")
            ok = false
            delete pixels
            break
        }
        flip_rows_inplace(pixels, w, h)
        var rc = 0
        unsafe {
            rc = stbi_apng_frame(writer, addr(pixels[0]), w * 4, frame_ms)
        }
        delete pixels
        if (rc != 1) {
            to_log(LOG_ERROR, "[record] stbi_apng_frame {f} failed\n")
            ok = false
            break
        }
    }
    if (stbi_apng_end(writer) != 1) {
        to_log(LOG_ERROR, "[record] stbi_apng_end failed\n")
        ok = false
    }
    return ok
}

//! Locate the daslang executable under `das_root`, probing the common build layouts across platforms
//! (Windows MSVC multi-config, single-config, Unix install / build dirs). Falls back to bare "daslang"
//! (resolved via PATH) when none exist, so the recording driver runs on Windows, Linux, and macOS.
def public find_daslang_exe(das_root : string) : string {
    let candidates <- [
        path_join(das_root, "bin/Release/daslang.exe"),    // Windows MSVC multi-config
        path_join(das_root, "bin/daslang.exe"),            // Windows single-config
        path_join(das_root, "bin/daslang"),                // Unix install layout
        path_join(das_root, "build/daslang")]              // Unix Make/Ninja build dir
    for (c in candidates) {
        var st : FStat
        if (stat(c, st)) {
            return c
        }
    }
    return "daslang"
}

//! Render the strudel music bed to `dur_s` seconds, then ffmpeg-mux the APNG video + a faded,
//! low-volume bed into `out_mp4`. `daslang_exe` runs `music_feature` (a daStrudel feature) as a
//! subprocess to synthesize the bed. Returns true on success.
def public convert_to_mp4(apng_path, music_feature, daslang_exe, out_mp4 : string;
                          dur_s : float; fps, bed_db, fade_ms : int) : bool {
    let music_wav = path_join(dir_name(apng_path), "{stem(apng_path)}_bed.wav")
    let margs <- [daslang_exe, music_feature, "--", "--wav", music_wav, "--duration", "{dur_s}"]
    var mout : string
    if (run_and_capture(margs, mout) != 0) {
        to_log(LOG_ERROR, "[record] music bed render failed:\n{mout}\n")
        return false
    }
    let fade = float(fade_ms) / 1000.0f
    let fade_out_st = max(dur_s - fade, 0.0f)
    let bed = "[1:a]afade=t=in:st=0:d={fade},afade=t=out:st={fade_out_st}:d={fade},volume={bed_db}dB[aout]"
    let fargs <- [
        "ffmpeg", "-y", "-loglevel", "error", "-r", "{fps}", "-i", apng_path, "-i", music_wav,
        "-filter_complex", bed, "-map", "0:v", "-map", "[aout]",
        "-c:v", "libx264", "-preset", "medium", "-crf", "23", "-pix_fmt", "yuv420p",
        "-movflags", "+faststart", "-shortest", out_mp4]
    var fout : string
    if (run_and_capture(fargs, fout) != 0) {
        to_log(LOG_ERROR, "[record] ffmpeg mux failed:\n{fout}\n")
        return false
    }
    to_log(LOG_INFO, "[record] wrote {out_mp4}\n")
    return true
}

// ===== voice + captions =====
// say() records anchors into a module-level array; prepare_voiceover() walks it later. Recordings are
// one at a time (the recorder collides on Kokoro / ffmpeg processes anyway), so a global array is the
// simplest fit and matches dasImgui's prepare_recording pattern.

struct public Line {
    frame   : int       // frame index the caption appears on (matches capture_apng's frame model)
    caption : string    // on-screen text (canonical -- dasVulkan / SPIR-V / dasSpirv stay as written)
    voice   : string    // spoken sentence (phonetic respellings -- see skills/recording.md)
    wav     : string    // path to the rendered voiceover wav (filled by prepare_voiceover)
    dur_s   : float     // wav duration in seconds (filled by prepare_voiceover)
}

var private g_lines : array<Line>

//! Register a caption + voice anchor at `frame`. The caption is what shows on screen (terse,
//! for the eye); the voice is what's spoken (natural sentence, ASCII-only, with phonetic
//! respellings for brand names -- see skills/recording.md). Defaults voice to caption.
def public say(frame : int; caption : string) {
    g_lines |> push(Line(frame = frame, caption = caption, voice = caption))
}

def public say(frame : int; caption, voice : string) {
    g_lines |> push(Line(frame = frame, caption = caption, voice = voice))
}

//! For each registered say() line, render a wav via Kokoro TTS (skipped if the wav exists on disk
//! already, so re-runs are cheap) and measure the duration. Wavs land in <apng_dir>/voiceover/.
def public prepare_voiceover(apng_path : string;
                              base_url : string = "http://127.0.0.1:8880/v1";
                              voice_id : string = "bf_emma";
                              model : string = "kokoro") : bool {
    let vo_dir = path_join(dir_name(apng_path), "voiceover")
    mkdir_rec(vo_dir)
    let client = openai_client(base_url, "")
    for (i in range(length(g_lines))) {
        let wav_path = path_join(vo_dir, "line_{i}.wav")
        if (!stat(wav_path).is_valid) {
            let res = speech(client, SpeechRequest(model = model, voice = voice_id,
                input = g_lines[i].voice, response_format = "wav"))
            if (!res.ok) {
                to_log(LOG_ERROR, "[record] TTS failed for line {i}: \"{g_lines[i].voice}\"\n")
                return false
            }
            fopen(wav_path, "wb") $(f) {
                if (f != null) {
                    fwrite(f, res.audio)
                }
            }
        }
        var samples : array<float>
        var rate = 0
        var channels = 0
        if (!read_wav(wav_path, samples, rate, channels) || rate <= 0 || channels <= 0) {
            to_log(LOG_ERROR, "[record] could not measure wav: {wav_path}\n")
            delete samples
            return false
        }
        let dur = float(length(samples) / channels) / float(rate)
        delete samples
        g_lines[i].wav = wav_path
        g_lines[i].dur_s = dur
        to_log(LOG_INFO, "[record] line {i}: {dur}s  \"{g_lines[i].voice}\"\n")
    }
    return true
}

//! Same as convert_to_mp4 but also:
//!   - mixes each prepared voiceover wav (delayed to its frame index) under the music bed,
//!   - paints each caption via ffmpeg drawtext, timed to (line.frame/fps .. + line.dur_s + 0.4s).
//! `font_file` must be the ffmpeg-escaped path of a TTF on the running machine (the Windows default
//! works on Boris's PC; pass a different one on Linux). prepare_voiceover() must run first.
def public convert_to_mp4_voiced(apng_path, music_feature, daslang_exe, out_mp4 : string;
                                  dur_s : float; fps, bed_db, fade_ms : int;
                                  font_file : string = "C\\:/Windows/Fonts/arial.ttf") : bool {
    let music_wav = path_join(dir_name(apng_path), "{stem(apng_path)}_bed.wav")
    if (!stat(music_wav).is_valid) {
        let margs <- [daslang_exe, music_feature, "--", "--wav", music_wav, "--duration", "{dur_s}"]
        var mout : string
        if (run_and_capture(margs, mout) != 0) {
            to_log(LOG_ERROR, "[record] music bed render failed:\n{mout}\n")
            return false
        }
    }
    let n_vo = length(g_lines)
    let fade = float(fade_ms) / 1000.0f
    let fade_out_st = max(dur_s - fade, 0.0f)
    let bed = "[1:a]afade=t=in:st=0:d={fade},afade=t=out:st={fade_out_st}:d={fade},volume={bed_db}dB[bed]"
    let fg = build_string() $(var w) {
        // video drawtext chain
        w |> write("[0:v]")
        for (i in range(n_vo)) {
            let t_start = float(g_lines[i].frame) / float(fps)
            let t_end = t_start + g_lines[i].dur_s + 0.4f
            if (i != 0) {
                w |> write(",")
            }
            w |> write("drawtext=fontfile='{font_file}':text='{g_lines[i].caption}'")
            w |> write(":fontsize=28:fontcolor=white:box=1:boxcolor=black@0.55:boxborderw=10")
            w |> write(":x=(w-text_w)/2:y=h-70")
            w |> write(":enable='between(t\\,{t_start}\\,{t_end})'")
        }
        w |> write("[vout]")
        // audio chain: bed + voices delayed to their frames, amix into one stream
        w |> write(";{bed}")
        for (i in range(n_vo)) {
            let t_ms = g_lines[i].frame * 1000 / fps
            w |> write(";[{2 + i}:a]adelay={t_ms}:all=1[vo{i}]")
        }
        w |> write(";[bed]")
        for (i in range(n_vo)) {
            w |> write("[vo{i}]")
        }
        w |> write("amix=inputs={1 + n_vo}:duration=longest:normalize=0[aout]")
    }
    var fargs <- ["ffmpeg", "-y", "-loglevel", "error", "-r", "{fps}", "-i", apng_path, "-i", music_wav]
    for (i in range(n_vo)) {
        fargs |> push("-i")
        fargs |> push(g_lines[i].wav)
    }
    fargs |> push_from([
        "-filter_complex", fg,
        "-map", "[vout]", "-map", "[aout]",
        "-c:v", "libx264", "-preset", "medium", "-crf", "23", "-pix_fmt", "yuv420p",
        "-movflags", "+faststart", "-shortest", out_mp4])
    fwrite("{out_mp4}.ffmpeg.txt", join(fargs, " "))
    var fout : string
    if (run_and_capture(fargs, fout) != 0) {
        to_log(LOG_ERROR, "[record] ffmpeg voiced mux failed:\n{fout}\n")
        return false
    }
    to_log(LOG_INFO, "[record] wrote {out_mp4}\n")
    return true
}
