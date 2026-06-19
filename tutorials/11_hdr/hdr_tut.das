options gen2
options indenting = 4

// Tutorial 11 render path: HDR scene -> Karis-style 5-mip bloom -> ACES-tonemapped LDR.
//
// Eleven render-pass instances per frame:
//   * 1 x scene pass (HDR_W x HDR_H, R16G16B16A16_SFLOAT)
//   * 1 x bright pass (BLOOM_W[0] x BLOOM_H[0], R16G16B16A16_SFLOAT)
//   * 4 x downsample passes (bloom[i] -> bloom[i+1])
//   * 4 x upsample passes (bloom[i+1] added onto bloom[i])
//   * 1 x composite pass (LDR_W x LDR_H, R8G8B8A8_UNORM)
//
// Three render-pass *objects* are shared across these instances: rp_scene (color+depth, clear),
// rp_post_clear (single-color HDR, clear), rp_post_load (single-color HDR, load). Each of the 5
// bloom mips has both a clear- and load-framebuffer, plus one fb_scene and one fb_composite.
//
// Five pipelines: scene_pipeline (instanced vertex+fragment, depth-tested), bright_pipeline +
// downsample_pipeline + composite_pipeline (fullscreen-tri, no depth, no blend) and
// upsample_pipeline (fullscreen-tri, no depth, ADDITIVE blend). All four post-process pipelines
// use dynamic viewport so the same pipeline runs at every mip resolution.

module hdr_tut

require vulkan public
require vulkan/vulkan_boost public
require vulkan/vulkan_reflect
require hdr_tut_shaders public
require math

let public HDR_W = 768
let public HDR_H = 768
let HDR_FMT      = VkFormat.R16G16B16A16_SFLOAT
let DEPTH_FMT    = VkFormat.D32_SFLOAT
let LDR_FMT      = VkFormat.R8G8B8A8_UNORM

let public BLOOM_LEVELS = 5
// width / height per mip: 1/2, 1/4, 1/8, 1/16, 1/32 of HDR_W
let public BLOOM_W : array<int> <- [HDR_W / 2, HDR_W / 4, HDR_W / 8, HDR_W / 16, HDR_W / 32]
let public BLOOM_H : array<int> <- [HDR_H / 2, HDR_H / 4, HDR_H / 8, HDR_H / 16, HDR_H / 32]

let public N_INSTANCES = 1000
let public N_VERTS     = 24
let public N_INDICES   = 36

// per-vertex stride: pos + normal = 6 floats = 24 bytes
let VERT_STRIDE = 24u
// per-instance stride: offset + colour + phase + emissive = 8 floats = 32 bytes
let INST_STRIDE = 32u
let INST_FLOATS_PER = 8
let EVERY_NTH_EMISSIVE = 7              // 1 in 7 cubes glows

// push-constant block matches `BloomCtrl` in the shader (32 bytes total).
let BLOOM_CTRL_SIZE = 32u

// ===== cube geometry (24 verts, 36 indices; faceted normals) =====

let private cube_vertices : array<float> <- [
    -0.5, -0.5, 0.5,   0.0, 0.0, 1.0,
     0.5, -0.5, 0.5,   0.0, 0.0, 1.0,
     0.5,  0.5, 0.5,   0.0, 0.0, 1.0,
    -0.5,  0.5, 0.5,   0.0, 0.0, 1.0,
     0.5, -0.5, -0.5,  0.0, 0.0, -1.0,
    -0.5, -0.5, -0.5,  0.0, 0.0, -1.0,
    -0.5,  0.5, -0.5,  0.0, 0.0, -1.0,
     0.5,  0.5, -0.5,  0.0, 0.0, -1.0,
     0.5, -0.5,  0.5,  1.0, 0.0, 0.0,
     0.5, -0.5, -0.5,  1.0, 0.0, 0.0,
     0.5,  0.5, -0.5,  1.0, 0.0, 0.0,
     0.5,  0.5,  0.5,  1.0, 0.0, 0.0,
    -0.5, -0.5, -0.5, -1.0, 0.0, 0.0,
    -0.5, -0.5,  0.5, -1.0, 0.0, 0.0,
    -0.5,  0.5,  0.5, -1.0, 0.0, 0.0,
    -0.5,  0.5, -0.5, -1.0, 0.0, 0.0,
    -0.5,  0.5,  0.5,  0.0, 1.0, 0.0,
     0.5,  0.5,  0.5,  0.0, 1.0, 0.0,
     0.5,  0.5, -0.5,  0.0, 1.0, 0.0,
    -0.5,  0.5, -0.5,  0.0, 1.0, 0.0,
    -0.5, -0.5, -0.5,  0.0, -1.0, 0.0,
     0.5, -0.5, -0.5,  0.0, -1.0, 0.0,
     0.5, -0.5,  0.5,  0.0, -1.0, 0.0,
    -0.5, -0.5,  0.5,  0.0, -1.0, 0.0
]

let private cube_indices : array<uint16> <- [
    uint16(0),  uint16(1),  uint16(2),   uint16(0),  uint16(2),  uint16(3),
    uint16(4),  uint16(5),  uint16(6),   uint16(4),  uint16(6),  uint16(7),
    uint16(8),  uint16(9),  uint16(10),  uint16(8),  uint16(10), uint16(11),
    uint16(12), uint16(13), uint16(14),  uint16(12), uint16(14), uint16(15),
    uint16(16), uint16(17), uint16(18),  uint16(16), uint16(18), uint16(19),
    uint16(20), uint16(21), uint16(22),  uint16(20), uint16(22), uint16(23)
]

// ===== matrix builders (column-major) =====

def perspective_vk(fov_y, aspect, znear, zfar : float) : float4x4 {
    let f = 1.0f / tan(fov_y * 0.5f)
    let nf = 1.0f / (znear - zfar)
    var m : float4x4
    m[0] = float4(f / aspect, 0.0f, 0.0f, 0.0f)
    m[1] = float4(0.0f, -f, 0.0f, 0.0f)
    m[2] = float4(0.0f, 0.0f, zfar * nf, -1.0f)
    m[3] = float4(0.0f, 0.0f, znear * zfar * nf, 0.0f)
    return m
}

def vec3_sub(a, b : float3) : float3 => float3(a.x - b.x, a.y - b.y, a.z - b.z)
def vec3_cross(a, b : float3) : float3 => float3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
def vec3_dot(a, b : float3) : float => a.x * b.x + a.y * b.y + a.z * b.z
def vec3_normalize(v : float3) : float3 {
    let len = sqrt(vec3_dot(v, v))
    return float3(v.x / len, v.y / len, v.z / len)
}

def look_at_rh(eye, center, up : float3) : float4x4 {
    let f = vec3_normalize(vec3_sub(center, eye))
    let s = vec3_normalize(vec3_cross(f, up))
    let u = vec3_cross(s, f)
    var m : float4x4
    m[0] = float4(s.x, u.x, -f.x, 0.0f)
    m[1] = float4(s.y, u.y, -f.y, 0.0f)
    m[2] = float4(s.z, u.z, -f.z, 0.0f)
    m[3] = float4(-vec3_dot(s, eye), -vec3_dot(u, eye), vec3_dot(f, eye), 1.0f)
    return m
}

// ===== per-instance buffer init =====

//! Build N_INSTANCES rows of (offset.xyz, color.rgb, phase, emissive). Offsets sample a Lissajous-
//! style 3D curve; colours cycle hue thrice; phase is uniform [0,1); emissive = 1.0 every Nth cube.
def gen_instance_data(n : int) : array<float> {
    var data : array<float>
    data |> resize(n * INST_FLOATS_PER)
    for (i in range(n)) {
        let fi = float(i) / float(n)
        let theta = fi * 2.0f * PI * 7.0f
        let phi = fi * 2.0f * PI * 3.0f
        let r = 5.0f + 1.5f * sin(fi * 2.0f * PI * 5.0f)
        let x = r * cos(theta) * cos(phi * 0.5f)
        let y = r * sin(phi)
        let z = r * sin(theta) * cos(phi * 0.5f)
        let hue = fi * 6.0f * PI
        let cr = 0.5f + 0.5f * cos(hue)
        let cg = 0.5f + 0.5f * cos(hue + 2.0944f)
        let cb = 0.5f + 0.5f * cos(hue + 4.1888f)
        let emissive = (i % EVERY_NTH_EMISSIVE == 0) ? 1.0f : 0.0f
        let base = i * INST_FLOATS_PER
        data[base + 0] = x
        data[base + 1] = y
        data[base + 2] = z
        data[base + 3] = cr
        data[base + 4] = cg
        data[base + 5] = cb
        data[base + 6] = fi
        data[base + 7] = emissive
    }
    return <- data
}

// ===== resources =====

struct public HdrResources {
    hdr_color   : OffscreenTarget
    hdr_depth   : OffscreenDepth
    bloom       : array<OffscreenTarget>   // BLOOM_LEVELS entries
    ldr_color   : OffscreenTarget

    rp_scene       : RenderPass
    rp_post_clear  : RenderPass
    rp_post_load   : RenderPass
    rp_composite   : RenderPass

    fb_scene       : Framebuffer
    fb_post_clear  : array<Framebuffer>     // BLOOM_LEVELS entries
    fb_post_load   : array<Framebuffer>     // BLOOM_LEVELS entries (0 unused for upsample but kept symmetric)
    fb_composite   : Framebuffer

    sampler_linear_clamp : Sampler

    cube_vb   : HostBuffer
    cube_ib   : HostBuffer
    inst_buf  : HostBuffer
    ubo       : HostBuffer

    scene_set_layouts    : array<DescriptorSetLayout>
    scene_pipe_layout    : PipelineLayout
    scene_pipeline       : Pipeline
    scene_set            : VkDescriptorSet

    post_set_layouts     : array<DescriptorSetLayout>      // index 0 = scene (UBO), index 1 = post (1 sampler)
    post_pipe_layout     : PipelineLayout
    bright_pipeline      : Pipeline
    down_pipeline        : Pipeline
    up_pipeline          : Pipeline                         // additive blend
    bright_set           : VkDescriptorSet                  // reads HDR scene
    down_set             : array<VkDescriptorSet>           // BLOOM_LEVELS-1 entries (mip i -> i+1)
    up_set               : array<VkDescriptorSet>           // BLOOM_LEVELS-1 entries (mip i+1 -> i)

    composite_set_layouts : array<DescriptorSetLayout>     // 2 samplers
    composite_pipe_layout : PipelineLayout
    composite_pipeline    : Pipeline
    composite_set         : VkDescriptorSet

    desc_pool : DescriptorPool

    readback  : HostBuffer
    buf_size  : uint64
}

def public finalize(var r : HdrResources) {
    unsafe {
        delete r.readback
        delete r.desc_pool
        delete r.composite_pipeline
        delete r.composite_pipe_layout
        delete r.composite_set_layouts
        delete r.up_pipeline
        delete r.down_pipeline
        delete r.bright_pipeline
        delete r.post_pipe_layout
        delete r.post_set_layouts
        delete r.scene_pipeline
        delete r.scene_pipe_layout
        delete r.scene_set_layouts
        delete r.ubo
        delete r.inst_buf
        delete r.cube_ib
        delete r.cube_vb
        delete r.sampler_linear_clamp
        delete r.fb_composite
        delete r.fb_post_load
        delete r.fb_post_clear
        delete r.fb_scene
        delete r.rp_composite
        delete r.rp_post_load
        delete r.rp_post_clear
        delete r.rp_scene
        delete r.ldr_color
        delete r.bloom
        delete r.hdr_depth
        delete r.hdr_color
    }
}

struct public HdrContext {
    instance : Instance
    device   : Device
    queue    : VkQueue
    pool     : CommandPool
    res      : HdrResources
}

def public finalize(var ctx : HdrContext) {
    unsafe {
        delete ctx.res
        delete ctx.pool
        delete ctx.device
        delete ctx.instance
    }
}

// ===== build =====

def public build_hdr_resources(device : Device; phys : VkPhysicalDevice; queue : VkQueue; pool : CommandPool) : HdrResources {
    let _unused_queue = queue
    let _unused_pool = pool

    // ----- offscreen targets -----
    var samples1 : VkSampleCountFlags
    samples1._1 = true
    var hdr_extra : VkImageUsageFlags
    hdr_extra.sampled = true                            // HDR scene is sampled by bright + composite
    var inscope hdr_color <- build_offscreen_target(device, phys, HDR_W, HDR_H, HDR_FMT, samples1, hdr_extra)
    var depth_extra : VkImageUsageFlags
    var inscope hdr_depth <- build_offscreen_depth(device, phys, HDR_W, HDR_H, DEPTH_FMT, depth_extra)

    var bloom_extra : VkImageUsageFlags
    bloom_extra.sampled = true                          // bloom mips are sampled by down + up + composite
    var inscope bloom : array<OffscreenTarget>
    for (i in range(BLOOM_LEVELS)) {
        var inscope mip <- build_offscreen_target(device, phys, BLOOM_W[i], BLOOM_H[i], HDR_FMT, samples1, bloom_extra)
        bloom |> emplace(mip)
    }

    var ldr_extra : VkImageUsageFlags
    ldr_extra.transfer_src = true
    var inscope ldr_color <- build_offscreen_target(device, phys, HDR_W, HDR_H, LDR_FMT, samples1, ldr_extra)

    // ----- render passes -----
    var inscope rp_scene <- create_render_pass_color_depth(device, HDR_FMT, DEPTH_FMT,
        VkImageLayout.SHADER_READ_ONLY_OPTIMAL)                                                // HDR sampled by post passes
    var inscope rp_post_clear <- create_render_pass_single_color(device, HDR_FMT,
        VkImageLayout.SHADER_READ_ONLY_OPTIMAL)                                                // bright + downsample
    var inscope rp_post_load <- build_post_load_render_pass(device)                            // upsample (loadOp=LOAD)
    var inscope rp_composite <- create_render_pass_single_color(device, LDR_FMT,
        VkImageLayout.TRANSFER_SRC_OPTIMAL)                                                    // final blit target

    // ----- framebuffers -----
    var scene_attach : array<ImageView>
    scene_attach |> push(weak_copy(hdr_color.view))
    scene_attach |> push(weak_copy(hdr_depth.view))
    var inscope fb_scene <- create_framebuffer(device, FramebufferCreateInfo(
        renderPass = weak_copy(rp_scene),
        pAttachments <- scene_attach,
        width = uint(HDR_W), height = uint(HDR_H), layers = 1u))

    var inscope fb_post_clear : array<Framebuffer>
    var inscope fb_post_load  : array<Framebuffer>
    for (i in range(BLOOM_LEVELS)) {
        var ac : array<ImageView>
        ac |> push(weak_copy(bloom[i].view))
        var inscope fbc <- create_framebuffer(device, FramebufferCreateInfo(
            renderPass = weak_copy(rp_post_clear),
            pAttachments <- ac,
            width = uint(BLOOM_W[i]), height = uint(BLOOM_H[i]), layers = 1u))
        fb_post_clear |> emplace(fbc)

        var al : array<ImageView>
        al |> push(weak_copy(bloom[i].view))
        var inscope fbl <- create_framebuffer(device, FramebufferCreateInfo(
            renderPass = weak_copy(rp_post_load),
            pAttachments <- al,
            width = uint(BLOOM_W[i]), height = uint(BLOOM_H[i]), layers = 1u))
        fb_post_load |> emplace(fbl)
    }

    var comp_attach : array<ImageView>
    comp_attach |> push(weak_copy(ldr_color.view))
    var inscope fb_composite <- create_framebuffer(device, FramebufferCreateInfo(
        renderPass = weak_copy(rp_composite),
        pAttachments <- comp_attach,
        width = uint(HDR_W), height = uint(HDR_H), layers = 1u))

    // ----- sampler -----
    var sci : SamplerCreateInfo
    sci.magFilter = VkFilter.LINEAR
    sci.minFilter = VkFilter.LINEAR
    sci.mipmapMode = VkSamplerMipmapMode.NEAREST
    sci.addressModeU = VkSamplerAddressMode.CLAMP_TO_EDGE
    sci.addressModeV = VkSamplerAddressMode.CLAMP_TO_EDGE
    sci.addressModeW = VkSamplerAddressMode.CLAMP_TO_EDGE
    sci.maxLod = 0.0f
    var inscope sampler_linear_clamp <- create_sampler(device, sci)

    // ----- geometry + UBOs -----
    var vb_usage : VkBufferUsageFlags
    vb_usage.vertex_buffer = true
    var ib_usage : VkBufferUsageFlags
    ib_usage.index_buffer = true
    var ubo_usage : VkBufferUsageFlags
    ubo_usage.uniform_buffer = true

    var cv_copy : array<float>
    cv_copy |> push_from(cube_vertices)
    var inscope cube_vb <- create_host_buffer_from_bytes(device, phys, vb_usage, cv_copy)
    delete cv_copy
    var ci_copy : array<uint16>
    ci_copy |> push_from(cube_indices)
    var inscope cube_ib <- create_host_buffer_from_bytes(device, phys, ib_usage, ci_copy)
    delete ci_copy

    var inst_data <- gen_instance_data(N_INSTANCES)
    var inscope inst_buf <- create_host_buffer_from_bytes(device, phys, vb_usage, inst_data)
    delete inst_data

    var inscope ubo <- create_host_buffer(device, phys, 144ul, ubo_usage)        // view + proj + cam_time

    // ----- reflection -----
    var scene_refl <- [decode_reflection(hdr_scene_vert_spv_reflect), decode_reflection(hdr_scene_frag_spv_reflect)]
    var inscope scene_set_layouts <- build_descriptor_set_layouts(device, scene_refl)
    var inscope scene_pipe_layout <- build_pipeline_layout(device, scene_set_layouts, scene_refl)

    var bright_refl <- [decode_reflection(hdr_fullscreen_vert_spv_reflect), decode_reflection(hdr_bright_frag_spv_reflect)]
    var inscope post_set_layouts <- build_descriptor_set_layouts(device, bright_refl)
    var inscope post_pipe_layout <- build_pipeline_layout(device, post_set_layouts, bright_refl)
    delete bright_refl

    var comp_refl <- [decode_reflection(hdr_fullscreen_vert_spv_reflect), decode_reflection(hdr_composite_frag_spv_reflect)]
    var inscope composite_set_layouts <- build_descriptor_set_layouts(device, comp_refl)
    var inscope composite_pipe_layout <- build_pipeline_layout(device, composite_set_layouts, comp_refl)
    delete comp_refl

    // ----- descriptor pool sized for all sets -----
    let n_post_samples = uint(1 + 2 * (BLOOM_LEVELS - 1))     // bright + down(4) + up(4) = 9
    var dpci : DescriptorPoolCreateInfo
    dpci.maxSets = uint(1 + n_post_samples + 1)               // scene + post + composite
    var p_ubo : DescriptorPoolSize
    p_ubo.type_ = VkDescriptorType.UNIFORM_BUFFER
    p_ubo.descriptorCount = 1u
    dpci.pPoolSizes |> push(p_ubo)
    var p_smp : DescriptorPoolSize
    p_smp.type_ = VkDescriptorType.COMBINED_IMAGE_SAMPLER
    p_smp.descriptorCount = n_post_samples + 2u               // post-sets each have one sampler + composite has two
    dpci.pPoolSizes |> push(p_smp)
    var inscope desc_pool <- create_descriptor_pool(device, dpci)

    // ----- allocate descriptor sets -----
    var scene_set     = alloc_one_set(device, desc_pool, scene_set_layouts[0])
    var bright_set    = alloc_one_set(device, desc_pool, post_set_layouts[1])      // post-sampler is set 1
    var composite_set = alloc_one_set(device, desc_pool, composite_set_layouts[1]) // composite samplers in set 1
    var down_set : array<VkDescriptorSet>
    var up_set   : array<VkDescriptorSet>
    for (i in range(BLOOM_LEVELS - 1)) {
        down_set |> push(alloc_one_set(device, desc_pool, post_set_layouts[1]))
        up_set   |> push(alloc_one_set(device, desc_pool, post_set_layouts[1]))
    }

    // ----- writes -----
    var writes : array<WriteDescriptorSet>
    writes |> emplace(write_ubo(scene_set, 0u, ubo.buffer, 144ul))
    writes |> emplace(write_sampler(bright_set, 0u, hdr_color.view, sampler_linear_clamp))
    for (i in range(BLOOM_LEVELS - 1)) {
        writes |> emplace(write_sampler(down_set[i], 0u, bloom[i].view, sampler_linear_clamp))
        writes |> emplace(write_sampler(up_set[i],   0u, bloom[i + 1].view, sampler_linear_clamp))
    }
    writes |> emplace(write_sampler(composite_set, 0u, hdr_color.view, sampler_linear_clamp))
    writes |> emplace(write_sampler(composite_set, 1u, bloom[0].view,  sampler_linear_clamp))
    var no_copies : array<CopyDescriptorSet>
    update_descriptor_sets(device, writes, no_copies)

    // ----- shaders + pipelines -----
    var inscope sh_scene_v <- create_shader_module(device, hdr_scene_vert_spv)
    var inscope sh_scene_f <- create_shader_module(device, hdr_scene_frag_spv)
    var inscope sh_full_v  <- create_shader_module(device, hdr_fullscreen_vert_spv)
    var inscope sh_bright  <- create_shader_module(device, hdr_bright_frag_spv)
    var inscope sh_down    <- create_shader_module(device, hdr_down_frag_spv)
    var inscope sh_up      <- create_shader_module(device, hdr_up_frag_spv)
    var inscope sh_comp    <- create_shader_module(device, hdr_composite_frag_spv)

    var vbindings : array<VkVertexInputBindingDescription>
    vbindings |> push(VkVertexInputBindingDescription(binding = 0u, stride = VERT_STRIDE, inputRate = VkVertexInputRate.VERTEX))
    vbindings |> push(VkVertexInputBindingDescription(binding = 1u, stride = INST_STRIDE, inputRate = VkVertexInputRate.INSTANCE))
    var vattrs : array<VkVertexInputAttributeDescription>
    vattrs |> push(VkVertexInputAttributeDescription(location = 0u, binding = 0u, format = VkFormat.R32G32B32_SFLOAT, offset = 0u))
    vattrs |> push(VkVertexInputAttributeDescription(location = 1u, binding = 0u, format = VkFormat.R32G32B32_SFLOAT, offset = 12u))
    vattrs |> push(VkVertexInputAttributeDescription(location = 2u, binding = 1u, format = VkFormat.R32G32B32_SFLOAT, offset = 0u))
    vattrs |> push(VkVertexInputAttributeDescription(location = 3u, binding = 1u, format = VkFormat.R32G32B32_SFLOAT, offset = 12u))
    vattrs |> push(VkVertexInputAttributeDescription(location = 4u, binding = 1u, format = VkFormat.R32_SFLOAT,       offset = 24u))
    vattrs |> push(VkVertexInputAttributeDescription(location = 5u, binding = 1u, format = VkFormat.R32_SFLOAT,       offset = 28u))

    var inscope scene_pipeline <- create_graphics_pipeline_v3d(device, rp_scene, scene_pipe_layout, sh_scene_v, sh_scene_f,
        HDR_W, HDR_H, vbindings, vattrs)
    delete vbindings
    delete vattrs

    var inscope bright_pipeline <- create_graphics_pipeline_simple(device, rp_post_clear, post_pipe_layout, sh_full_v, sh_bright,
        HDR_W, HDR_H, /*dynamic_viewport*/true)
    var inscope down_pipeline   <- create_graphics_pipeline_simple(device, rp_post_clear, post_pipe_layout, sh_full_v, sh_down,
        HDR_W, HDR_H, /*dynamic_viewport*/true)
    var inscope up_pipeline     <- build_additive_pipeline(device, rp_post_load, post_pipe_layout, sh_full_v, sh_up)
    var inscope composite_pipeline <- create_graphics_pipeline_simple(device, rp_composite, composite_pipe_layout,
        sh_full_v, sh_comp, HDR_W, HDR_H)

    delete scene_refl

    let buf_size = uint64(HDR_W * HDR_H * 4)
    var inscope readback <- create_host_buffer(device, phys, buf_size)

    var r : HdrResources
    r.hdr_color <- hdr_color
    r.hdr_depth <- hdr_depth
    r.bloom <- bloom
    r.ldr_color <- ldr_color
    r.rp_scene <- rp_scene
    r.rp_post_clear <- rp_post_clear
    r.rp_post_load <- rp_post_load
    r.rp_composite <- rp_composite
    r.fb_scene <- fb_scene
    r.fb_post_clear <- fb_post_clear
    r.fb_post_load <- fb_post_load
    r.fb_composite <- fb_composite
    r.sampler_linear_clamp <- sampler_linear_clamp
    r.cube_vb <- cube_vb
    r.cube_ib <- cube_ib
    r.inst_buf <- inst_buf
    r.ubo <- ubo
    r.scene_set_layouts <- scene_set_layouts
    r.scene_pipe_layout <- scene_pipe_layout
    r.scene_pipeline <- scene_pipeline
    r.scene_set = scene_set
    r.post_set_layouts <- post_set_layouts
    r.post_pipe_layout <- post_pipe_layout
    r.bright_pipeline <- bright_pipeline
    r.down_pipeline <- down_pipeline
    r.up_pipeline <- up_pipeline
    r.bright_set = bright_set
    r.down_set <- down_set
    r.up_set <- up_set
    r.composite_set_layouts <- composite_set_layouts
    r.composite_pipe_layout <- composite_pipe_layout
    r.composite_pipeline <- composite_pipeline
    r.composite_set = composite_set
    r.desc_pool <- desc_pool
    r.readback <- readback
    r.buf_size = buf_size
    return <- r
}

// ===== helpers =====

def private alloc_one_set(device : Device; pool : DescriptorPool; layout : DescriptorSetLayout) : VkDescriptorSet {
    let dev = boost_value_to_vk(device)
    var dsai = VkDescriptorSetAllocateInfo()
    dsai.descriptorPool = boost_value_to_vk(pool)
    dsai.descriptorSetCount = 1u
    var raw_layout = boost_value_to_vk(layout)
    var raw_set : VkDescriptorSet
    unsafe {
        dsai.pSetLayouts = addr(raw_layout)
        vk_check(vkAllocateDescriptorSets(dev, dsai, addr(raw_set)), null)
    }
    return raw_set
}

def private write_ubo(set : VkDescriptorSet; binding : uint; buf : Buffer; size : uint64) : WriteDescriptorSet {
    var w : WriteDescriptorSet
    w.dstSet = vk_value_to_boost(set)
    w.dstBinding = binding
    w.descriptorType = VkDescriptorType.UNIFORM_BUFFER
    w.descriptorCount = 1u
    var bi : DescriptorBufferInfo
    bi.buffer = weak_copy(buf)
    bi.range_ = size
    w.pBufferInfo |> push(bi)
    return <- w
}

def private write_sampler(set : VkDescriptorSet; binding : uint; view : ImageView; sampler : Sampler) : WriteDescriptorSet {
    var w : WriteDescriptorSet
    w.dstSet = vk_value_to_boost(set)
    w.dstBinding = binding
    w.descriptorType = VkDescriptorType.COMBINED_IMAGE_SAMPLER
    w.descriptorCount = 1u
    var ii : DescriptorImageInfo
    ii.sampler = weak_copy(sampler)
    ii.imageView = weak_copy(view)
    ii.imageLayout = VkImageLayout.SHADER_READ_ONLY_OPTIMAL
    w.pImageInfo |> push(ii)
    return <- w
}

// ===== render passes / pipelines =====

//! Single-color load render pass (HDR mip is loaded, not cleared) -- the upsample blends additively
//! onto the previously-downsampled content of the destination mip.
def private build_post_load_render_pass(device : Device) : RenderPass {
    var attach : VkAttachmentDescription
    attach.format = HDR_FMT
    attach.samples._1 = true
    attach.loadOp = VkAttachmentLoadOp.LOAD
    attach.storeOp = VkAttachmentStoreOp.STORE
    attach.stencilLoadOp = VkAttachmentLoadOp.DONT_CARE
    attach.stencilStoreOp = VkAttachmentStoreOp.DONT_CARE
    attach.initialLayout = VkImageLayout.SHADER_READ_ONLY_OPTIMAL     // previous pass left it sampled
    attach.finalLayout   = VkImageLayout.SHADER_READ_ONLY_OPTIMAL
    var ref : VkAttachmentReference
    ref.layout = VkImageLayout.COLOR_ATTACHMENT_OPTIMAL
    var subpass : VkSubpassDescription
    subpass.pipelineBindPoint = VkPipelineBindPoint.GRAPHICS
    subpass.colorAttachmentCount = 1u
    var ci = VkRenderPassCreateInfo()
    ci.attachmentCount = 1u
    ci.subpassCount = 1u
    var h : VkRenderPass
    unsafe {
        subpass.pColorAttachments = addr(ref)
        ci.pAttachments = addr(attach)
        ci.pSubpasses = addr(subpass)
        vk_check(vkCreateRenderPass(boost_value_to_vk(device), ci, null, h), null)
    }
    var b = vk_value_to_boost(h)
    b._needs_delete = true
    b._device = unsafe(reinterpret<uint64>(boost_value_to_vk(device)))
    return <- b
}

//! Fullscreen-triangle pipeline with additive blend (srcColor=ONE, dstColor=ONE on RGB; alpha
//! passed through). Used for the upsample passes -- each smaller mip's contribution is *added* to
//! the destination mip, building the energy-pyramid back up.
def private build_additive_pipeline(device : Device; rp : RenderPass; layout : PipelineLayout;
                                    vert : ShaderModule; frag : ShaderModule) : Pipeline {
    var stages : array<VkPipelineShaderStageCreateInfo>
    stages |> resize(2)
    stages[0] = VkPipelineShaderStageCreateInfo()
    stages[0].stage.vertex = true
    stages[0].module_ = boost_value_to_vk(vert)
    stages[0].pName = "main"
    stages[1] = VkPipelineShaderStageCreateInfo()
    stages[1].stage.fragment = true
    stages[1].module_ = boost_value_to_vk(frag)
    stages[1].pName = "main"

    var vinput = VkPipelineVertexInputStateCreateInfo()
    var iasm = VkPipelineInputAssemblyStateCreateInfo()
    iasm.topology = VkPrimitiveTopology.TRIANGLE_LIST

    var vpstate = VkPipelineViewportStateCreateInfo()
    vpstate.viewportCount = 1u
    vpstate.scissorCount = 1u

    var raster = VkPipelineRasterizationStateCreateInfo()
    raster.polygonMode = VkPolygonMode.FILL
    raster.frontFace = VkFrontFace.COUNTER_CLOCKWISE
    raster.lineWidth = 1.0f
    var msaa = VkPipelineMultisampleStateCreateInfo()
    msaa.rasterizationSamples._1 = true

    var blend_att : VkPipelineColorBlendAttachmentState
    blend_att.blendEnable = VK_TRUE
    blend_att.srcColorBlendFactor = VkBlendFactor.ONE
    blend_att.dstColorBlendFactor = VkBlendFactor.ONE
    blend_att.colorBlendOp = VkBlendOp.ADD
    blend_att.srcAlphaBlendFactor = VkBlendFactor.ONE
    blend_att.dstAlphaBlendFactor = VkBlendFactor.ONE
    blend_att.alphaBlendOp = VkBlendOp.ADD
    blend_att.colorWriteMask.r = true
    blend_att.colorWriteMask.g = true
    blend_att.colorWriteMask.b = true
    blend_att.colorWriteMask.a = true
    var blend = VkPipelineColorBlendStateCreateInfo()
    blend.attachmentCount = 1u

    var dyn_states : array<VkDynamicState>
    dyn_states |> push(VkDynamicState.VIEWPORT)
    dyn_states |> push(VkDynamicState.SCISSOR)
    var dynstate = VkPipelineDynamicStateCreateInfo()
    dynstate.dynamicStateCount = uint(length(dyn_states))

    var gp = VkGraphicsPipelineCreateInfo()
    gp.stageCount = 2u
    gp.layout = boost_value_to_vk(layout)
    gp.renderPass = boost_value_to_vk(rp)
    var h : VkPipeline
    unsafe {
        dynstate.pDynamicStates = addr(dyn_states[0])
        blend.pAttachments = addr(blend_att)
        gp.pStages = addr(stages[0])
        gp.pVertexInputState = addr(vinput)
        gp.pInputAssemblyState = addr(iasm)
        gp.pViewportState = addr(vpstate)
        gp.pRasterizationState = addr(raster)
        gp.pMultisampleState = addr(msaa)
        gp.pColorBlendState = addr(blend)
        gp.pDynamicState = addr(dynstate)
        vk_check(vkCreateGraphicsPipelines(boost_value_to_vk(device), null, 1u, addr(gp), null, addr(h)), null)
    }
    delete stages
    delete dyn_states
    var b = vk_value_to_boost(h)
    b._needs_delete = true
    b._device = unsafe(reinterpret<uint64>(boost_value_to_vk(device)))
    return <- b
}

// ===== build context =====

def public build_hdr_context() : HdrContext {
    if (volkInitialize() != 0) {
        panic("no Vulkan loader")
    }
    var inscope instance <- create_instance("dasVulkan tutorial 11", make_api_version(1u, 3u, 0u))
    volkLoadInstance(boost_value_to_vk(instance))
    let phys = select_physical_device(instance)
    let gfx = select_graphics_queue_family(phys)
    var inscope device <- create_device(phys, gfx)
    volkLoadDevice(boost_value_to_vk(device))
    var queue = get_device_queue(device, gfx, 0u)
    var poolci : CommandPoolCreateInfo
    poolci.queueFamilyIndex = gfx
    var inscope pool <- create_command_pool(device, poolci)
    var inscope res <- build_hdr_resources(device, phys, queue, pool)
    return <- HdrContext(
        instance <- instance, device <- device, queue = queue, pool <- pool, res <- res)
}

// ===== per-frame =====

//! Push the camera matrices + camera world position + time into the scene UBO, exactly like the
//! instancing tutorial. Bloom UBO has no per-frame data -- everything is in the push-constant.
def public update_hdr_uniforms(res : HdrResources; device : Device; time, camera_t : float) {
    let camera_angle = camera_t * 2.0f * PI
    let camera_r = 14.0f
    let cam_x = camera_r * cos(camera_angle)
    let cam_z = camera_r * sin(camera_angle)
    let cam_y = sin(camera_angle * 2.0f) * 2.0f
    let cam_pos = float3(cam_x, cam_y, cam_z)
    cam.view = look_at_rh(cam_pos, float3(0.0f, 0.0f, 0.0f), float3(0.0f, 1.0f, 0.0f))
    cam.proj = perspective_vk(60.0f * PI / 180.0f, float(HDR_W) / float(HDR_H), 0.1f, 60.0f)
    cam.cam_time = float4(cam_pos.x, cam_pos.y, cam_pos.z, time)
    hdr_scene_vs_bind_uniform(device, res.ubo.memory)
}

//! Set the dynamic viewport + scissor to `(w x h)`. Called between each bloom-mip render pass.
def private set_dyn_vp(cmd : CommandBuffer; w, h : int) {
    var vp : VkViewport
    vp.width = float(w)
    vp.height = float(h)
    vp.maxDepth = 1.0f
    var sc : VkRect2D
    sc.extent.width = uint(w)
    sc.extent.height = uint(h)
    unsafe {
        vkCmdSetViewport(boost_value_to_vk(cmd), 0u, 1u, addr(vp))
        vkCmdSetScissor(boost_value_to_vk(cmd), 0u, 1u, addr(sc))
    }
}

//! Build a 32-byte push-constant block (matches `BloomCtrl` in the shader) with the supplied
//! source-mip texel size + threshold/knee/intensity.
def private pc_bytes(src_rcp_x, src_rcp_y, threshold, soft_knee, bloom_intensity : float) : array<uint8> {
    var f : array<float>
    f |> push(src_rcp_x)
    f |> push(src_rcp_y)
    f |> push(threshold)
    f |> push(soft_knee)
    f |> push(bloom_intensity)
    f |> push(0.0f)
    f |> push(0.0f)
    f |> push(0.0f)
    var b : array<uint8>
    b |> resize(int(BLOOM_CTRL_SIZE))
    unsafe {
        memcpy(addr(b[0]), addr(f[0]), int(BLOOM_CTRL_SIZE))
    }
    delete f
    return <- b
}

//! Issue `vkCmdPushConstants` for the post-process block (32 bytes, stage_fragment).
def private push_post(cmd : CommandBuffer; layout : PipelineLayout; pc : array<uint8>) {
    var stages : VkShaderStageFlags
    stages.fragment = true
    unsafe {
        vkCmdPushConstants(boost_value_to_vk(cmd), boost_value_to_vk(layout), stages, 0u, BLOOM_CTRL_SIZE, addr(pc[0]))
    }
}

// ===== record =====

//! Record the full HDR + bloom + composite frame into `cmd`. Eleven render-pass instances; the
//! final `rp_composite` ends with `ldr_color` in `TRANSFER_SRC_OPTIMAL` so the caller can blit it
//! straight to the readback buffer or the swap target.
def public record_hdr_frame(res : HdrResources; cmd : CommandBuffer) {
    let threshold = 1.0f
    let soft_knee = 0.5f
    let bloom_intensity = 0.06f

    // ---- scene pass ----
    var scene_clears <- [clear_color(0.02f, 0.0f, 0.04f, 1.0f), clear_depth(1.0f)]
    record_render_pass(cmd, res.rp_scene, res.fb_scene, full_area(HDR_W, HDR_H), scene_clears) {
        cmd_bind_pipeline(cmd, res.scene_pipeline)
        let sets <- [vk_value_to_boost(res.scene_set)]
        var no_dyn : array<uint>
        cmd_bind_descriptor_sets(cmd, VkPipelineBindPoint.GRAPHICS, res.scene_pipe_layout, 0u, sets, no_dyn)
        let vbufs <- [weak_copy(res.cube_vb.buffer), weak_copy(res.inst_buf.buffer)]
        var voffs : array<uint64>
        voffs |> push(0ul)
        voffs |> push(0ul)
        cmd_bind_vertex_buffers(cmd, 0u, vbufs, voffs)
        cmd_bind_index_buffer(cmd, weak_copy(res.cube_ib.buffer), 0ul, VkIndexType.UINT16)
        cmd_draw_indexed(cmd, uint(N_INDICES), uint(N_INSTANCES), 0u, 0, 0u)
    }
    delete scene_clears

    // ---- bright pass : HDR scene -> bloom[0] ----
    var b0_clears <- [clear_color(0.0f, 0.0f, 0.0f, 1.0f)]
    record_render_pass(cmd, res.rp_post_clear, res.fb_post_clear[0], full_area(BLOOM_W[0], BLOOM_H[0]), b0_clears) {
        set_dyn_vp(cmd, BLOOM_W[0], BLOOM_H[0])
        cmd_bind_pipeline(cmd, res.bright_pipeline)
        let sets <- [vk_value_to_boost(res.bright_set)]
        var no_dyn : array<uint>
        cmd_bind_descriptor_sets(cmd, VkPipelineBindPoint.GRAPHICS, res.post_pipe_layout, 1u, sets, no_dyn)
        let pc = pc_bytes(1.0f / float(HDR_W), 1.0f / float(HDR_H), threshold, soft_knee, bloom_intensity)
        push_post(cmd, res.post_pipe_layout, pc)
        cmd_draw(cmd, 3u, 1u)
    }
    delete b0_clears

    // ---- downsample chain : bloom[i] -> bloom[i+1] ----
    for (i in range(BLOOM_LEVELS - 1)) {
        var clears <- [clear_color(0.0f, 0.0f, 0.0f, 1.0f)]
        record_render_pass(cmd, res.rp_post_clear, res.fb_post_clear[i + 1],
                           full_area(BLOOM_W[i + 1], BLOOM_H[i + 1]), clears) {
            set_dyn_vp(cmd, BLOOM_W[i + 1], BLOOM_H[i + 1])
            cmd_bind_pipeline(cmd, res.down_pipeline)
            let sets <- [vk_value_to_boost(res.down_set[i])]
            var no_dyn : array<uint>
            cmd_bind_descriptor_sets(cmd, VkPipelineBindPoint.GRAPHICS, res.post_pipe_layout, 1u, sets, no_dyn)
            let pc = pc_bytes(1.0f / float(BLOOM_W[i]), 1.0f / float(BLOOM_H[i]),
                              threshold, soft_knee, bloom_intensity)
            push_post(cmd, res.post_pipe_layout, pc)
            cmd_draw(cmd, 3u, 1u)
        }
        delete clears
    }

    // ---- upsample chain (additive blend) : bloom[i+1] -> bloom[i] ----
    for (k in range(BLOOM_LEVELS - 1)) {
        let i = BLOOM_LEVELS - 2 - k       // iterate dst = 3, 2, 1, 0
        // record_render_pass requires N clears for N attachments even when loadOp=LOAD ignores
        // them; pass a single dummy clear so the pClearValues pointer is valid.
        var up_clears <- [clear_color(0.0f, 0.0f, 0.0f, 1.0f)]
        record_render_pass(cmd, res.rp_post_load, res.fb_post_load[i],
                           full_area(BLOOM_W[i], BLOOM_H[i]), up_clears) {
            set_dyn_vp(cmd, BLOOM_W[i], BLOOM_H[i])
            cmd_bind_pipeline(cmd, res.up_pipeline)
            let sets <- [vk_value_to_boost(res.up_set[i])]
            var no_dyn : array<uint>
            cmd_bind_descriptor_sets(cmd, VkPipelineBindPoint.GRAPHICS, res.post_pipe_layout, 1u, sets, no_dyn)
            let pc = pc_bytes(1.0f / float(BLOOM_W[i + 1]), 1.0f / float(BLOOM_H[i + 1]),
                              threshold, soft_knee, bloom_intensity)
            push_post(cmd, res.post_pipe_layout, pc)
            cmd_draw(cmd, 3u, 1u)
        }
        delete up_clears
    }

    // ---- composite pass : HDR + bloom[0] -> ACES -> LDR ----
    var comp_clears <- [clear_color(0.0f, 0.0f, 0.0f, 1.0f)]
    record_render_pass(cmd, res.rp_composite, res.fb_composite, full_area(HDR_W, HDR_H), comp_clears) {
        cmd_bind_pipeline(cmd, res.composite_pipeline)
        let sets <- [vk_value_to_boost(res.composite_set)]
        var no_dyn : array<uint>
        cmd_bind_descriptor_sets(cmd, VkPipelineBindPoint.GRAPHICS, res.composite_pipe_layout, 1u, sets, no_dyn)
        let pc = pc_bytes(1.0f / float(HDR_W), 1.0f / float(HDR_H), threshold, soft_knee, bloom_intensity)
        push_post(cmd, res.composite_pipe_layout, pc)
        cmd_draw(cmd, 3u, 1u)
    }
    delete comp_clears
}

//! Per-frame work: update UBO, record the HDR/bloom/composite chain, copy LDR target to readback.
def public render_hdr_frame(var ctx : HdrContext; time, camera_t : float) : array<uint8> {
    update_hdr_uniforms(ctx.res, ctx.device, time, camera_t)
    var pixels : array<uint8>
    run_cmd_sync(ctx.device, ctx.pool, ctx.queue) $(cmd) {
        record_hdr_frame(ctx.res, cmd)
        copy_image_to_buffer(cmd, ctx.res.ldr_color.image, ctx.res.readback, HDR_W, HDR_H)
    }
    map_memory_to_array(ctx.device, ctx.res.readback.memory, ctx.res.buf_size) $(m) {
        pixels := m
    }
    return <- pixels
}

//! Self-contained one-shot. Used by the test + recording.
def public render_hdr_scene(time, camera_t : float) : array<uint8> {
    var inscope ctx <- build_hdr_context()
    return <- render_hdr_frame(ctx, time, camera_t)
}

//! Sample RGB of pixel (x,y) from an HDR_W*HDR_H RGBA8 buffer.
def public px(pixels : array<uint8>; x, y : int) : int3 {
    let p = (y * HDR_W + x) * 4
    return int3(int(pixels[p]), int(pixels[p + 1]), int(pixels[p + 2]))
}
