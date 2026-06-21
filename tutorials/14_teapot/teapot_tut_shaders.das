options gen2
options indenting = 4

// Tutorial 14 -- the Utah teapot, tessellated on the GPU by a mesh-shader pipeline. There is no
// vertex buffer and no index buffer: the 32 bicubic Bezier patches of the classic Newell teapot are
// uploaded once as control points, and the GPU amplifies them into geometry every frame.
//
//   TASK  one workgroup, 32-patch-wide. Decides which patches survive (back-facing patches are
//         culled as the teapot rotates -- the visible proof that the task stage removed geometry on
//         the GPU) and writes the survivor indices into a @task_payload. EmitMeshTasksEXT then
//         dispatches exactly `count` mesh workgroups, one per surviving patch.
//
//   MESH  one workgroup per surviving patch. Reads its patch index from the payload (keyed by
//         gl_WorkGroupID), evaluates the bicubic Bezier surface on a TESS x TESS grid -- on-GPU patch
//         tessellation, a flagship mesh-shader technique -- and emits the grid as (TESS+1)^2 vertices
//         and 2*TESS*TESS triangles, with a finite-difference surface normal per vertex.
//
//   FRAG  view-facing Lambert + rim (robust to per-patch winding), with an optional per-patch debug
//         tint that colors each patch distinctly to show the "1 patch = 1 mesh workgroup" structure.
//
// Every line is daslang, lowered to SPIR-V at compile time by dasSpirv (no glslang). Geometry data
// lives in teapot_data.das; the host (teapot_tut.das) uploads it to the control-point UBO.

module teapot_tut_shaders public

require vulkan/vulkan_boost public  // Device + DeviceMemory used by the generated bind_uniform_* helpers
require vulkan/spirv_vulkan_shader public
require spirv/spirv_builtins public
require math

let PATCH_COUNT = 32
let TESS  = 7    // TESS x TESS quad grid per patch
let VERTS = 64   // (TESS+1)^2  -- emitter needs literal-constant globals (SetMeshOutputsEXT operand)
let TRIS  = 98   // 2*TESS^2

// ===== UBO =====

//! One UBO (binding 0). The generated bind_uniform supports a single @uniform struct per shader, so
//! the static control net and the per-frame transform share one block; the ~8 KB re-upload per frame
//! is negligible. cp = 32 patches x 16 control points (xyz; w pad), patch p = cp[p*16 .. p*16+15],
//! row-major 4x4. mvp = proj*view*model (positions); model = world rotation (normals + cull facing);
//! camera.xyz = world eye, camera.w = debug-tint flag (0/1); light.xyz = world light direction.
struct TeapotUBO {
    mvp    : float4x4
    model  : float4x4
    camera : float4
    light  : float4
    cp     : float4[512]
}
var @uniform @set = 0 @binding = 0 ubo : TeapotUBO

// ===== task -> mesh payload =====

struct PatchPayload {
    count   : uint
    visible : uint[32]
}
var @task_payload payload : PatchPayload

// ===== mesh -> fragment varyings =====

var @out @location = 0 v_world_normal : array<float3>
var @out @location = 1 v_world_pos    : array<float3>
var @out @location = 2 v_patch        : array<float>

// ===== bicubic Bezier evaluation (helpers shared by task + mesh) =====

//! Evaluate the bicubic Bezier patch at (u,v) in [0,1]^2. base = patch*16. Fully unrolled so the only
//! dynamic index is into the control-point UBO array (base varies per patch).
def eval_patch(base : int; u, v : float) : float3 {
    let su = 1.0 - u
    let sv = 1.0 - v
    let bu0 = su * su * su; let bu1 = 3.0 * su * su * u; let bu2 = 3.0 * su * u * u; let bu3 = u * u * u
    let bv0 = sv * sv * sv; let bv1 = 3.0 * sv * sv * v; let bv2 = 3.0 * sv * v * v; let bv3 = v * v * v
    let r0 = bv0 * ubo.cp[base +  0].xyz + bv1 * ubo.cp[base +  1].xyz + bv2 * ubo.cp[base +  2].xyz + bv3 * ubo.cp[base +  3].xyz
    let r1 = bv0 * ubo.cp[base +  4].xyz + bv1 * ubo.cp[base +  5].xyz + bv2 * ubo.cp[base +  6].xyz + bv3 * ubo.cp[base +  7].xyz
    let r2 = bv0 * ubo.cp[base +  8].xyz + bv1 * ubo.cp[base +  9].xyz + bv2 * ubo.cp[base + 10].xyz + bv3 * ubo.cp[base + 11].xyz
    let r3 = bv0 * ubo.cp[base + 12].xyz + bv1 * ubo.cp[base + 13].xyz + bv2 * ubo.cp[base + 14].xyz + bv3 * ubo.cp[base + 15].xyz
    return bu0 * r0 + bu1 * r1 + bu2 * r2 + bu3 * r3
}

//! Surface normal at (u,v) via central finite differences -- robust and simple (no analytic
//! derivative basis). Model space.
def eval_normal(base : int; u, v : float) : float3 {
    let e = 0.012
    let du = eval_patch(base, min(u + e, 1.0), v) - eval_patch(base, max(u - e, 0.0), v)
    let dv = eval_patch(base, u, min(v + e, 1.0)) - eval_patch(base, u, max(v - e, 0.0))
    return normalize(cross(du, dv))
}

// ===== TASK: per-patch cull =====

[vulkan_task_shader(local_size_x=1, name="teapot_task_spv")]
def teapot_task {
    // v1: pass-through (keep all patches) to validate tessellation + shading first; the backface cull
    // is enabled in a follow-up once the full teapot renders correctly.
    for (p in range(PATCH_COUNT)) {
        payload.visible[p] = uint(p)
    }
    payload.count = uint(PATCH_COUNT)
    EmitMeshTasksEXT(uint(PATCH_COUNT), 1u, 1u)
}

// ===== MESH: tessellate one patch =====

[vulkan_mesh_shader(local_size_x=1, max_vertices=64, max_primitives=98, name="teapot_mesh_spv")]
def teapot_mesh {
    SetMeshOutputsEXT(uint(VERTS), uint(TRIS))
    let patch = payload.visible[gl_WorkGroupID.x]
    let base = int(patch) * 16
    // evaluate the (TESS+1)^2 grid of surface points + normals
    for (iu in range(TESS + 1)) {
        for (iv in range(TESS + 1)) {
            let u = float(iu) / float(TESS)
            let v = float(iv) / float(TESS)
            let pos = eval_patch(base, u, v)
            let nrm = eval_normal(base, u, v)
            let idx = iu * (TESS + 1) + iv
            gl_MeshVerticesEXT[idx].gl_Position = ubo.mvp * float4(pos, 1.0)
            v_world_normal[idx] = normalize((ubo.model * float4(nrm, 0.0)).xyz)
            v_world_pos[idx] = (ubo.model * float4(pos, 1.0)).xyz
            v_patch[idx] = float(patch)
        }
    }
    // emit two triangles per grid quad
    var t = 0
    for (iu in range(TESS)) {
        for (iv in range(TESS)) {
            let a = iu * (TESS + 1) + iv
            let b = a + 1
            let c = a + (TESS + 1)
            let d = c + 1
            gl_PrimitiveTriangleIndicesEXT[t] = uint3(uint(a), uint(b), uint(c))
            t ++
            gl_PrimitiveTriangleIndicesEXT[t] = uint3(uint(b), uint(d), uint(c))
            t ++
        }
    }
}

// ===== FRAGMENT =====

var @in @location = 0 f_world_normal : float3
var @in @location = 1 f_world_pos    : float3
var @in @location = 2 f_patch        : float
var @out @location = 0 frag_color    : float4

[vulkan_fragment_shader(name="teapot_frag_spv")]
def teapot_fs {
    var n = normalize(f_world_normal)
    let view = normalize(ubo.camera.xyz - f_world_pos)
    if (dot(n, view) < 0.0) {            // view-facing: robust to per-patch winding
        n = -n
    }
    let l = normalize(ubo.light.xyz)
    let key = max(dot(n, l), 0.0) * 0.8 + 0.2
    let ceramic = float3(0.85, 0.55, 0.28)
    var col = ceramic * key
    let rim = pow(1.0 - max(dot(n, view), 0.0), 3.0) * 0.35
    col += float3(rim, rim, rim)
    if (ubo.camera.w > 0.5) {             // per-patch debug tint
        let h = fract(f_patch * 0.137)
        let tint = float3(fract(h + 0.0), fract(h + 0.33), fract(h + 0.66))
        col = lerp(col, tint, float3(0.55, 0.55, 0.55))   // splat t: dasSpirv FMix needs a vec t
    }
    frag_color = float4(col, 1.0)
}
