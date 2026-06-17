options gen2
options indenting = 4

// Tutorial 06 -- a procedural skybox via a cubemap. The vertex shader emits one cube vertex per draw
// vertex; the cube position IS the sampling direction (a normalized unit cube around the camera) so
// the fragment shader can sample the cubemap with the world direction without a separate UV. Two
// rails are exercised:
//
//   1. ``samplerCube`` and its ``texture(samplerCube, vec3)`` sampling overload -- the same
//      ``texture()`` builtin tutorial 04 used for ``sampler2D``, but now with a 3-vector direction
//      instead of a 2D UV. dasSpirv lowers it to ``OpImageSampleImplicitLod`` against an
//      ``OpTypeImage`` with ``Dim = Cube``.
//
//   2. The **depth=1.0 trick** for skyboxes. After the projection multiply we snap ``clip.z = clip.w``
//      so the post-divide NDC ``z`` is exactly ``1.0``: every skybox fragment lives at the far
//      plane. Paired with a ``LESS_OR_EQUAL`` depth test, the skybox passes only where the depth
//      buffer is still at its cleared 1.0 -- so once tutorial 07 (or a later combined scene) lays
//      down foreground geometry in the same render pass, the skybox automatically fills the gaps
//      without overdrawing what's in front of it. This tutorial draws skybox only; the trick is set
//      up here so the next tutorial can drop foreground geometry into the same pipeline with no
//      changes.

module skybox_tut_shaders public

require vulkan/vulkan_boost public  // Device + DeviceMemory used by the generated bind_uniform helper
require vulkan/spirv_vulkan_shader public
require spirv/spirv_builtins public
require math

// ===== shared UBO =====

//! Rotation-only view matrix (translation stripped) plus the perspective projection. The
//! translation strip keeps the skybox cube centred on the camera -- the skybox appears at
//! infinity, no matter where the camera moves.
struct Camera {
    view : float4x4
    proj : float4x4
}
var @uniform @set = 0 @binding = 0 cam : Camera

// ===== cubemap binding =====

//! 6-face cubemap of the procedural sky (sun + gradient + horizon). VK_IMAGE_VIEW_TYPE_CUBE on the
//! host side; ``samplerCube`` here makes dasSpirv emit an ``OpTypeImage`` with ``Dim=Cube``.
var @set = 0 @binding = 1 sky_tex : samplerCube

// ===== vertex shader =====

var @in @location = 0 a_pos : float3
var @out @location = 0 v_dir : float3

[vulkan_vertex_shader(name="skybox_vert_spv")]
def skybox_vs {
    // Pass the local cube position as the per-fragment sampling direction. Because we render a unit
    // cube centred at the origin and the view is rotation-only, the position is the world-space
    // direction from camera to vertex.
    v_dir = a_pos
    // Standard rotation+projection. Then snap z to w so the post-divide NDC z = 1.0 (the far plane).
    // dasSpirv does not support write-swizzle (clip.z = clip.w), so rebuild the vec4 via constructor.
    let clip = cam.proj * cam.view * float4(a_pos, 1.0)
    gl_Position = float4(clip.x, clip.y, clip.w, clip.w)
}

// ===== fragment shader =====

var @in @location = 0 f_dir : float3
var @out @location = 0 frag_color : float4

[vulkan_fragment_shader(name="skybox_frag_spv")]
def skybox_fs {
    // ``f_dir`` is the interpolated cube position. Normalize to get the unit direction the cubemap
    // expects; the cube face + intra-face UV are computed by the sampler from this direction.
    let col = texture(sky_tex, normalize(f_dir)).rgb
    frag_color = float4(col, 1.0)
}
