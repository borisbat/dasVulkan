options gen2
options indenting = 4

// Tutorial 07 -- a compute-driven particle swarm. The same storage buffer flows through both
// pipelines: a compute shader rewrites every particle's position + velocity each frame (gravity
// pull toward the origin, integrated explicit-Euler), then a single per-frame pipeline barrier
// hands the buffer over to the graphics pipeline, which reads it as a per-instance vertex
// attribute stream and billboards a small quad per particle. The headline rails:
//
//   1. ``@ssbo`` -- a SPIR-V StorageBuffer block holding an ``array<Particle>``. The compute shader
//      reads + writes through ``particles[i].field`` chained access chains; the host marks the
//      buffer USAGE_STORAGE_BUFFER | USAGE_VERTEX_BUFFER so the same VkBuffer can also bind as a
//      vertex input.
//
//   2. **A per-frame execution + memory barrier** (``vkCmdPipelineBarrier`` with
//      COMPUTE_SHADER -> VERTEX_INPUT, SHADER_WRITE -> VERTEX_ATTRIBUTE_READ) -- the canonical
//      compute->graphics handoff. Without it the graphics pipeline can read stale particle values
//      from before the compute dispatch.
//
//   3. **Two pipelines reading the same buffer two ways**: compute sees ``Particle`` structs in a
//      std430-layout array; graphics binds the SAME bytes as a per-instance vertex stream with
//      attribute offsets matching the struct layout (pos at +0, life at +12, vel at +16, stride 32).

module particles_tut_shaders public

require vulkan/vulkan_boost public  // Device + DeviceMemory used by the generated bind_uniform helper
require vulkan/spirv_vulkan_shader public
require spirv/spirv_builtins public
require math

// ===== shared particle struct =====

//! std430 layout: pos@0, life@12, vel@16, pad@28; stride 32 bytes. The pad keeps the struct's vec3
//! alignment (16 bytes) honest -- without it the stride would round up to 32 anyway, but writing it
//! explicitly makes the host-side initial-state generator's offsets impossible to miss.
struct Particle {
    pos  : float3
    life : float
    vel  : float3
    pad  : float
}

// ===== compute shader =====

//! Time + dt feed the explicit-Euler integration. dt = wall-clock-per-frame so the swarm advances
//! at a constant rate regardless of GPU speed; time isn't used in the integrator but is kept for a
//! future re-spawn / noise driver.
struct ComputePush {
    time : float
    dt   : float
}
var @push_constant cpc : ComputePush

var @ssbo @binding = 0 particles : array<Particle>

[vulkan_compute_shader(local_size_x=64, name="particles_compute_spv")]
def particles_compute {
    let i = gl_GlobalInvocationID.x
    let p_pos = particles[i].pos
    let p_vel = particles[i].vel
    // central attractor: gravity-like 1/r^2 pull toward the origin, softened by 0.05 so particles
    // passing close to the origin don't blow up. The orbit isn't strictly Keplerian (explicit Euler
    // drifts) but the trajectories stay bounded and lively for any practical recording length.
    let r2 = dot(p_pos, p_pos)
    let r_mag = sqrt(r2 + 0.05)
    let inv_r3 = 1.0 / (r_mag * r_mag * r_mag)
    let accel = -p_pos * inv_r3 * 1.8
    let new_vel = p_vel + accel * cpc.dt
    let new_pos = p_pos + new_vel * cpc.dt
    particles[i].vel = new_vel
    particles[i].pos = new_pos
    // life is just a colour driver -- it stays untouched here, the host seeded it once.
}

// ===== vertex shader -- point sprite per particle =====

//! View + projection. POINT_LIST topology means each particle is a single GL point; the rasteriser
//! draws it as a single-pixel splat (default gl_PointSize=1, which lavapipe and every real GPU
//! support). Billboarded quads are the more flexible alternative -- they let you set a particle
//! size and shape -- but they require Vulkan's largePoints feature handling and add a quad-winding
//! orientation dance against the projection-matrix Y-flip. For tutorial 07's headline rail
//! (compute->graphics handoff) the single-pixel point form is plenty: 1024 coloured dots animate
//! visibly even at one pixel each.
struct Camera {
    view : float4x4
    proj : float4x4
}
var @uniform @set = 0 @binding = 0 cam : Camera

// per-instance attributes (binding 0, INPUT_RATE_INSTANCE) -- the SAME bytes the compute shader
// wrote to the SSBO, re-interpreted as vertex inputs with stride 32 + matching offsets.
var @in @location = 0 a_pos  : float3
var @in @location = 1 a_life : float
var @in @location = 2 a_vel  : float3

var @out @location = 0 v_speed   : float           // |vel|, drives colour
var @out @location = 1 v_life    : float           // 0..1, drives intensity

[vulkan_vertex_shader(name="particles_vert_spv")]
def particles_vs {
    gl_Position = cam.proj * cam.view * float4(a_pos, 1.0)
    v_speed = sqrt(dot(a_vel, a_vel))
    v_life = a_life
}

// ===== fragment shader =====

var @in @location = 0 f_speed : float
var @in @location = 1 f_life  : float
var @out @location = 0 frag_color : float4

[vulkan_fragment_shader(name="particles_frag_spv")]
def particles_fs {
    // colour by speed: cool teal for slow particles, hot magenta for fast
    let cool = float3(0.18, 0.65, 0.95)
    let hot  = float3(1.00, 0.30, 0.60)
    let s = clamp(f_speed * 0.4, 0.0, 1.0)
    let s3 = float3(s, s, s)
    let base = lerp(cool, hot, s3)
    frag_color = float4(base * f_life, 1.0)
}
