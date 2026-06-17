options gen2
options indenting = 4

// Tutorial 06 render path: draw a procedural cubemap skybox surrounding the camera. Six procedural
// faces (256x256 each) are uploaded once into a single VK_IMAGE_VIEW_TYPE_CUBE image; the skybox is a
// unit cube whose vertex position doubles as the world-space sampling direction. The view matrix
// passed to the shader has its translation column zeroed so the cube stays centred on the camera --
// the skybox appears at infinity even as the camera world position changes.

module skybox_tut

require vulkan public
require vulkan/vulkan_boost public
require vulkan/vulkan_reflect
require skybox_tut_shaders
require math

let public SKY_W = 768
let public SKY_H = 768
let SKY_DEPTH_FMT = VkFormat.D32_SFLOAT
let SKY_COLOR_FMT = VkFormat.R8G8B8A8_UNORM
let FACE_DIM = 256
let N_FACES = 6

let public N_VERTS = 8
let public N_INDICES = 36                  // 6 faces * 2 tris * 3 indices (CW from outside = CCW from inside)

// ===== cube geometry (positions only; the position IS the sampling direction) =====

//! 8 corners of a unit cube. Per-vertex layout: 3 floats (pos.xyz), stride 12.
let private cube_vertices : array<float> <- [
    -1.0, -1.0, -1.0,    // 0
     1.0, -1.0, -1.0,    // 1
     1.0,  1.0, -1.0,    // 2
    -1.0,  1.0, -1.0,    // 3
    -1.0, -1.0,  1.0,    // 4
     1.0, -1.0,  1.0,    // 5
     1.0,  1.0,  1.0,    // 6
    -1.0,  1.0,  1.0]    // 7

//! 36 indices, each face wound CCW **from inside the cube** (= CW from outside). The v3d pipeline
//! culls back-facing triangles with CCW = front; the camera renders the cube as if from inside
//! (the view's translation column is stripped on the host, so the cube stays glued to the camera).
//! Each triangle's inward-pointing normal must match CCW vertex order -- I verified each face by
//! cross-producting the first two edges and checking the sign of the resulting normal component.
let private cube_indices : array<uint16> <- [
    // +X face (right, inward normal = -X): v1, v5, v6, v2
    uint16(1), uint16(5), uint16(6),  uint16(1), uint16(6), uint16(2),
    // -X face (left, inward normal = +X): v0, v3, v7, v4
    uint16(0), uint16(3), uint16(7),  uint16(0), uint16(7), uint16(4),
    // +Y face (top, inward normal = -Y): v2, v6, v7, v3
    uint16(2), uint16(6), uint16(7),  uint16(2), uint16(7), uint16(3),
    // -Y face (bottom, inward normal = +Y): v0, v4, v5, v1
    uint16(0), uint16(4), uint16(5),  uint16(0), uint16(5), uint16(1),
    // +Z face (front, inward normal = -Z): v4, v7, v6, v5
    uint16(4), uint16(7), uint16(6),  uint16(4), uint16(6), uint16(5),
    // -Z face (back, inward normal = +Z): v0, v1, v2, v3
    uint16(0), uint16(1), uint16(2),  uint16(0), uint16(2), uint16(3)]

// ===== matrix builders (column-major) =====

def perspective_vk(fov_y, aspect, znear, zfar : float) : float4x4 {
    let f = 1.0f / tan(fov_y * 0.5f)
    let nf = 1.0f / (znear - zfar)
    var m : float4x4
    m[0] = float4(f / aspect, 0.0f, 0.0f, 0.0f)
    m[1] = float4(0.0f, -f, 0.0f, 0.0f)                 // Y flip -- Vulkan NDC has +Y down
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

//! Strip the translation row from a view matrix so the rendered geometry appears at the same
//! relative position no matter where the camera is in the world. The skybox uses this so the cube
//! stays glued to the camera.
def strip_translation(var m : float4x4) : float4x4 {
    m[3] = float4(0.0f, 0.0f, 0.0f, 1.0f)
    return m
}

// ===== procedural cubemap =====

let public SUN_DIR : float3 = vec3_normalize(float3(0.45f, 0.55f, 0.85f))

//! Sample the sky at a unit direction. A two-tone vertical gradient (zenith blue -> warm horizon)
//! plus a soft falloff to the ground hemisphere, plus a sun disc + Mie-style glow along SUN_DIR.
//! The same function evaluates on every cube face; that's why the seams between faces are invisible
//! -- each face just rasterises this continuous function over its own outgoing-direction patch.
def sample_sky(dir : float3) : float3 {
    let altitude = clamp(dir.y, -1.0f, 1.0f)
    let elevation = clamp(altitude * 0.5f + 0.5f, 0.0f, 1.0f)
    let zenith = float3(0.18f, 0.32f, 0.70f)
    let horizon = float3(0.88f, 0.62f, 0.45f)
    var col = lerp(horizon, zenith, float3(elevation, elevation, elevation))
    if (altitude < 0.0f) {
        let ground = float3(0.10f, 0.07f, 0.05f)
        let g = clamp(-altitude * 1.6f, 0.0f, 1.0f)
        let g3 = float3(g, g, g)
        col = lerp(col, ground, g3)
    }
    let sun_dot = clamp(vec3_dot(dir, SUN_DIR), 0.0f, 1.0f)
    let glow = pow(sun_dot, 32.0f) * 0.9f
    col = col + float3(1.0f, 0.85f, 0.65f) * glow
    if (sun_dot > 0.998f) {
        col = float3(1.0f, 0.95f, 0.85f)        // the sun disc itself
    }
    return clamp(col, float3(0.0f, 0.0f, 0.0f), float3(1.0f, 1.0f, 1.0f))
}

//! Convert a face index + (s,t) in [0,1]^2 to a unit direction. Matches the Vulkan cubemap face
//! ordering used by VK_IMAGE_VIEW_TYPE_CUBE (layer 0..5 = +X, -X, +Y, -Y, +Z, -Z).
def face_direction(face, x, y, dim : int) : float3 {
    let s = (float(x) + 0.5f) / float(dim) * 2.0f - 1.0f
    let t = (float(y) + 0.5f) / float(dim) * 2.0f - 1.0f
    var d : float3
    if (face == 0) {                                // +X
        d = float3(1.0f, -t, -s)
    } elif (face == 1) {                            // -X
        d = float3(-1.0f, -t, s)
    } elif (face == 2) {                            // +Y
        d = float3(s, 1.0f, t)
    } elif (face == 3) {                            // -Y
        d = float3(s, -1.0f, -t)
    } elif (face == 4) {                            // +Z
        d = float3(s, -t, 1.0f)
    } else {                                        // -Z
        d = float3(-s, -t, -1.0f)
    }
    return vec3_normalize(d)
}

//! Build all 6 RGBA8 faces as one contiguous byte array, ready for a single vkCmdCopyBufferToImage
//! call with regions per layer.
def gen_skybox_pixels() : array<uint8> {
    var pixels : array<uint8>
    pixels |> resize(N_FACES * FACE_DIM * FACE_DIM * 4)
    for (face in range(N_FACES)) {
        let layer_base = face * FACE_DIM * FACE_DIM * 4
        for (y in range(FACE_DIM)) {
            for (x in range(FACE_DIM)) {
                let d = face_direction(face, x, y, FACE_DIM)
                let col = sample_sky(d)
                let p = layer_base + (y * FACE_DIM + x) * 4
                pixels[p + 0] = uint8(clamp(col.x * 255.0f, 0.0f, 255.0f))
                pixels[p + 1] = uint8(clamp(col.y * 255.0f, 0.0f, 255.0f))
                pixels[p + 2] = uint8(clamp(col.z * 255.0f, 0.0f, 255.0f))
                pixels[p + 3] = 255u8
            }
        }
    }
    return <- pixels
}

// ===== reusable per-frame context =====

//! Long-lived skybox state: offscreen color + depth, render pass + framebuffer, cube geometry
//! buffers, UBO, cubemap image + view + sampler, descriptors, the depth-trick pipeline, and the
//! readback buffer.
struct public SkyboxResources {
    color       : OffscreenTarget
    depth       : OffscreenDepth
    render_pass : RenderPass
    framebuffer : Framebuffer
    vb          : HostBuffer
    ib          : HostBuffer
    ubo         : HostBuffer
    sky_image   : Image
    sky_memory  : DeviceMemory
    sky_view    : ImageView
    sky_sampler : Sampler
    set_layouts : array<DescriptorSetLayout>
    desc_pool   : DescriptorPool
    desc_set    : VkDescriptorSet
    pipe_layout : PipelineLayout
    pipeline    : Pipeline
    readback    : HostBuffer
    buf_size    : uint64
}

def public finalize(var r : SkyboxResources) {
    unsafe {
        delete r.readback
        delete r.pipeline
        delete r.pipe_layout
        delete r.desc_pool
        delete r.set_layouts
        delete r.sky_sampler
        delete r.sky_view
        delete r.sky_image
        delete r.sky_memory
        delete r.ubo
        delete r.ib
        delete r.vb
        delete r.framebuffer
        delete r.render_pass
        delete r.depth
        delete r.color
    }
}

struct public SkyboxContext {
    instance : Instance
    device   : Device
    queue    : VkQueue
    pool     : CommandPool
    res      : SkyboxResources
}

def public finalize(var ctx : SkyboxContext) {
    unsafe {
        delete ctx.res
        delete ctx.pool
        delete ctx.device
        delete ctx.instance
    }
}

//! Build the offscreen targets, the cubemap (uploaded + transitioned to SHADER_READ_ONLY), and the
//! depth-trick pipeline against a caller-owned (device, phys, queue, pool). Used by both
//! build_skybox_context (offscreen test + recording) and window/show_skybox.das (swapchain blit).
def public build_skybox_resources(device : Device; phys : VkPhysicalDevice; queue : VkQueue; pool : CommandPool) : SkyboxResources {
    let dev = boost_value_to_vk(device)

    var inscope color <- build_offscreen_target(device, phys, SKY_W, SKY_H, SKY_COLOR_FMT)
    var inscope depth <- build_offscreen_depth(device, phys, SKY_W, SKY_H, SKY_DEPTH_FMT)
    var inscope render_pass <- create_render_pass_color_depth(device, SKY_COLOR_FMT, SKY_DEPTH_FMT)
    var inscope framebuffer <- create_framebuffer(device, FramebufferCreateInfo(
        renderPass = weak_copy(render_pass),
        pAttachments <- [weak_copy(color.view), weak_copy(depth.view)],
        width = uint(SKY_W),
        height = uint(SKY_H),
        layers = 1u))

    var vb_usage : VkBufferUsageFlags
    vb_usage.vertex_buffer = true
    var verts_copy : array<float>
    verts_copy |> push_from(cube_vertices)
    var inscope vb <- create_host_buffer_from_bytes(device, phys, vb_usage, verts_copy)
    delete verts_copy

    var ib_usage : VkBufferUsageFlags
    ib_usage.index_buffer = true
    var indices_copy : array<uint16>
    indices_copy |> push_from(cube_indices)
    var inscope ib <- create_host_buffer_from_bytes(device, phys, ib_usage, indices_copy)
    delete indices_copy

    var ubo_usage : VkBufferUsageFlags
    ubo_usage.uniform_buffer = true
    var inscope ubo <- create_host_buffer(device, phys, 128ul, ubo_usage)        // view (64) + proj (64) = 128 bytes

    // 6-face cubemap: build the procedural sky on the host and stage it through one
    // HOST_VISIBLE/HOST_COHERENT buffer into a device-local cube image.
    var sky_pixels <- gen_skybox_pixels()
    var staging_usage : VkBufferUsageFlags
    staging_usage.transfer_src = true
    var inscope staging <- create_host_buffer_from_bytes(device, phys, staging_usage, sky_pixels)
    delete sky_pixels

    var ici : ImageCreateInfo
    ici.flags.cube_compatible = true                     // <-- required for VK_IMAGE_VIEW_TYPE_CUBE
    ici.imageType = VkImageType._2D
    ici.format = SKY_COLOR_FMT
    ici.extent.width = uint(FACE_DIM)
    ici.extent.height = uint(FACE_DIM)
    ici.extent.depth = 1u
    ici.mipLevels = 1u
    ici.arrayLayers = uint(N_FACES)                       // 6 faces, one per array layer
    ici.samples._1 = true
    ici.tiling = VkImageTiling.OPTIMAL
    ici.usage.sampled = true
    ici.usage.transfer_dst = true
    ici.initialLayout = VkImageLayout.UNDEFINED
    var inscope sky_image <- create_image(device, ici)
    var ireq : VkMemoryRequirements
    vkGetImageMemoryRequirements(dev, boost_value_to_vk(sky_image), ireq)
    var iwant : VkMemoryPropertyFlags
    iwant.device_local = true
    var imai : MemoryAllocateInfo
    imai.allocationSize = ireq.size
    imai.memoryTypeIndex = find_memory_type(phys, ireq.memoryTypeBits, iwant)
    var inscope sky_memory <- allocate_memory(device, imai)
    vk_check(vkBindImageMemory(dev, boost_value_to_vk(sky_image), boost_value_to_vk(sky_memory), 0ul), null)

    var tvci : ImageViewCreateInfo
    tvci.image = weak_copy(sky_image)
    tvci.viewType = VkImageViewType.CUBE                 // <-- the cubemap rail
    tvci.format = SKY_COLOR_FMT
    tvci.subresourceRange.aspectMask.color = true
    tvci.subresourceRange.levelCount = 1u
    tvci.subresourceRange.layerCount = uint(N_FACES)
    var inscope sky_view <- create_image_view(device, tvci)

    var sci : SamplerCreateInfo
    sci.magFilter = VkFilter.LINEAR
    sci.minFilter = VkFilter.LINEAR
    sci.mipmapMode = VkSamplerMipmapMode.LINEAR
    sci.addressModeU = VkSamplerAddressMode.CLAMP_TO_EDGE
    sci.addressModeV = VkSamplerAddressMode.CLAMP_TO_EDGE
    sci.addressModeW = VkSamplerAddressMode.CLAMP_TO_EDGE
    sci.maxLod = 1.0f
    var inscope sky_sampler <- create_sampler(device, sci)

    var reflections <- [decode_reflection(skybox_vert_spv_reflect), decode_reflection(skybox_frag_spv_reflect)]
    var inscope set_layouts <- build_descriptor_set_layouts(device, reflections)

    var dpci : DescriptorPoolCreateInfo
    dpci.maxSets = 1u
    var ps0 : DescriptorPoolSize
    ps0.type_ = VkDescriptorType.UNIFORM_BUFFER
    ps0.descriptorCount = 1u
    dpci.pPoolSizes |> push(ps0)
    var ps1 : DescriptorPoolSize
    ps1.type_ = VkDescriptorType.COMBINED_IMAGE_SAMPLER
    ps1.descriptorCount = 1u
    dpci.pPoolSizes |> push(ps1)
    var inscope desc_pool <- create_descriptor_pool(device, dpci)

    var dsai = VkDescriptorSetAllocateInfo()
    dsai.descriptorPool = boost_value_to_vk(desc_pool)
    dsai.descriptorSetCount = 1u
    var raw_set_layout = boost_value_to_vk(set_layouts[0])
    var raw_set : VkDescriptorSet
    unsafe {
        dsai.pSetLayouts = addr(raw_set_layout)
        vk_check(vkAllocateDescriptorSets(dev, dsai, addr(raw_set)), null)
    }

    var writes : array<WriteDescriptorSet>
    var w0 : WriteDescriptorSet
    w0.dstSet = vk_value_to_boost(raw_set)
    w0.dstBinding = 0u
    w0.descriptorType = VkDescriptorType.UNIFORM_BUFFER
    w0.descriptorCount = 1u
    var binfo : DescriptorBufferInfo
    binfo.buffer = weak_copy(ubo.buffer)
    binfo.range_ = 128ul
    w0.pBufferInfo |> push(binfo)
    writes |> emplace(w0)
    var w1 : WriteDescriptorSet
    w1.dstSet = vk_value_to_boost(raw_set)
    w1.dstBinding = 1u
    w1.descriptorType = VkDescriptorType.COMBINED_IMAGE_SAMPLER
    w1.descriptorCount = 1u
    var iinfo : DescriptorImageInfo
    iinfo.sampler = weak_copy(sky_sampler)
    iinfo.imageView = weak_copy(sky_view)
    iinfo.imageLayout = VkImageLayout.SHADER_READ_ONLY_OPTIMAL
    w1.pImageInfo |> push(iinfo)
    writes |> emplace(w1)
    var no_copies : array<CopyDescriptorSet>
    update_descriptor_sets(device, writes, no_copies)

    var inscope pipe_layout <- build_pipeline_layout(device, set_layouts, reflections)
    delete reflections

    var inscope vert <- create_shader_module(device, skybox_vert_spv)
    var inscope frag <- create_shader_module(device, skybox_frag_spv)

    var vbindings : array<VkVertexInputBindingDescription>
    var vb_desc : VkVertexInputBindingDescription
    vb_desc.binding = 0u
    vb_desc.stride = 12u
    vb_desc.inputRate = VkVertexInputRate.VERTEX
    vbindings |> push(vb_desc)
    var vattrs : array<VkVertexInputAttributeDescription>
    var attr_pos : VkVertexInputAttributeDescription
    attr_pos.location = 0u
    attr_pos.binding = 0u
    attr_pos.format = VkFormat.R32G32B32_SFLOAT
    attr_pos.offset = 0u
    vattrs |> push(attr_pos)
    // depth-trick pipeline: test LESS_OR_EQUAL, write disabled. With the vertex shader's z=w snap
    // every skybox fragment lives at NDC z=1.0; the test passes against any cleared 1.0 depth value
    // but never overwrites depth, so future foreground geometry (or a re-ordered scene) keeps its
    // own z values intact.
    var inscope pipeline <- create_graphics_pipeline_v3d(device, render_pass, pipe_layout, vert, frag,
        SKY_W, SKY_H, vbindings, vattrs, /*depth_test_enable=*/true, /*depth_write_enable=*/false,
        VkCompareOp.LESS_OR_EQUAL)
    delete vbindings
    delete vattrs

    let buf_size = uint64(SKY_W * SKY_H * 4)
    var inscope readback <- create_host_buffer(device, phys, buf_size)

    // one-shot cubemap upload: staging -> sky_image (all 6 layers in one copy), transitioned
    // UNDEFINED -> TRANSFER_DST -> SHADER_READ_ONLY across all layers.
    run_cmd_sync(device, pool, queue) $(cmd) {
        var to_dst : VkAccessFlags
        to_dst.transfer_write = true
        let none : VkAccessFlags
        var top : VkPipelineStageFlags
        top.top_of_pipe = true
        var xfer : VkPipelineStageFlags
        xfer.transfer = true
        var frag_stage : VkPipelineStageFlags
        frag_stage.fragment_shader = true
        var to_read : VkAccessFlags
        to_read.shader_read = true
        // transition_image only takes the layout pair; the cube transitions across all 6 layers
        // because the boost helper uses the full subresource range.
        transition_image(cmd, sky_image, VkImageLayout.UNDEFINED, VkImageLayout.TRANSFER_DST_OPTIMAL,
            none, to_dst, top, xfer)
        // One vkCmdCopyBufferToImage call with 6 regions, one per array layer. The staging buffer
        // has the faces laid out contiguously in the order (+X, -X, +Y, -Y, +Z, -Z).
        var regions : array<BufferImageCopy>
        for (face in range(N_FACES)) {
            var region : BufferImageCopy
            region.bufferOffset = uint64(face * FACE_DIM * FACE_DIM * 4)
            region.imageSubresource.aspectMask.color = true
            region.imageSubresource.baseArrayLayer = uint(face)
            region.imageSubresource.layerCount = 1u
            region.imageExtent.width = uint(FACE_DIM)
            region.imageExtent.height = uint(FACE_DIM)
            region.imageExtent.depth = 1u
            regions |> emplace(region)
        }
        cmd_copy_buffer_to_image(cmd, staging.buffer, sky_image, VkImageLayout.TRANSFER_DST_OPTIMAL, regions)
        transition_image(cmd, sky_image, VkImageLayout.TRANSFER_DST_OPTIMAL, VkImageLayout.SHADER_READ_ONLY_OPTIMAL,
            to_dst, to_read, xfer, frag_stage)
    }

    return <- SkyboxResources(
        color <- color, depth <- depth, render_pass <- render_pass, framebuffer <- framebuffer,
        vb <- vb, ib <- ib, ubo <- ubo,
        sky_image <- sky_image, sky_memory <- sky_memory, sky_view <- sky_view, sky_sampler <- sky_sampler,
        set_layouts <- set_layouts, desc_pool <- desc_pool, desc_set = raw_set,
        pipe_layout <- pipe_layout, pipeline <- pipeline, readback <- readback,
        buf_size = buf_size)
}

//! Self-contained one-shot context (own instance + device + queue + pool + resources). Used by the
//! [test] and the recording driver; windowed drivers build their own surface-enabled instance and
//! call build_skybox_resources directly.
def public build_skybox_context() : SkyboxContext {
    if (volkInitialize() != 0) {
        panic("no Vulkan loader")
    }
    var inscope instance <- create_instance("dasVulkan tutorial 06", make_api_version(1u, 3u, 0u))
    volkLoadInstance(boost_value_to_vk(instance))
    let phys = select_physical_device(instance)
    let gfx = select_graphics_queue_family(phys)
    var inscope device <- create_device(phys, gfx)
    volkLoadDevice(boost_value_to_vk(device))
    var queue = get_device_queue(device, gfx, 0u)
    var poolci : CommandPoolCreateInfo
    poolci.queueFamilyIndex = gfx
    var inscope pool <- create_command_pool(device, poolci)
    var inscope res <- build_skybox_resources(device, phys, queue, pool)
    return <- SkyboxContext(
        instance <- instance, device <- device, queue = queue, pool <- pool, res <- res)
}

//! Host-side per-frame prep: derive the camera matrices from ``camera_t in [0,1)``, strip the
//! translation so the cube stays glued to the camera, push view + proj into the UBO.
def public update_skybox_uniforms(res : SkyboxResources; device : Device; time, camera_t : float) {
    // time isn't used for the skybox itself (the cubemap is baked at init), but the signature is
    // kept consistent with the other tutorials' update_*_uniforms helpers so a future combined
    // scene can drop foreground animation onto the same per-frame call.
    let _time_unused = time
    let camera_angle = camera_t * 2.0f * PI
    let cam_x = cos(camera_angle) * 4.0f
    let cam_z = sin(camera_angle) * 4.0f
    let cam_y = sin(camera_angle * 2.0f) * 1.2f          // gentle vertical sway
    let cam_pos = float3(cam_x, cam_y, cam_z)
    var view = look_at_rh(cam_pos, float3(0.0f, 0.0f, 0.0f), float3(0.0f, 1.0f, 0.0f))
    cam.view = strip_translation(view)
    cam.proj = perspective_vk(70.0f * PI / 180.0f, float(SKY_W) / float(SKY_H), 0.1f, 50.0f)
    skybox_vs_bind_uniform(device, res.ubo.memory)
}

//! Record the skybox draw into the given command buffer. The render pass ends with the colour
//! attachment in TRANSFER_SRC_OPTIMAL (boost default), so the windowed driver can blit the result
//! straight onto the swapchain image.
def public record_skybox_render_pass(res : SkyboxResources; cmd : CommandBuffer) {
    var clears <- [clear_color(0.0f, 0.0f, 0.0f, 1.0f), clear_depth(1.0f)]
    record_render_pass(cmd, res.render_pass, res.framebuffer, full_area(SKY_W, SKY_H), clears) {
        cmd_bind_pipeline(cmd, res.pipeline)
        let sets <- [vk_value_to_boost(res.desc_set)]
        var no_dyn : array<uint>
        cmd_bind_descriptor_sets(cmd, VkPipelineBindPoint.GRAPHICS, res.pipe_layout, 0u, sets, no_dyn)
        let vbufs <- [weak_copy(res.vb.buffer)]
        var voffs : array<uint64>
        voffs |> push(0ul)
        cmd_bind_vertex_buffers(cmd, 0u, vbufs, voffs)
        cmd_bind_index_buffer(cmd, weak_copy(res.ib.buffer), 0ul, VkIndexType.UINT16)
        cmd_draw_indexed(cmd, uint(N_INDICES), 1u, 0u, 0, 0u)
    }
    delete clears
}

//! Per-frame work: update UBO, record the skybox draw, copy the colour attachment to the readback
//! buffer, clone the bytes out as RGBA8.
def public render_skybox_frame(var ctx : SkyboxContext; time, camera_t : float) : array<uint8> {
    update_skybox_uniforms(ctx.res, ctx.device, time, camera_t)
    var pixels : array<uint8>
    run_cmd_sync(ctx.device, ctx.pool, ctx.queue) $(cmd) {
        record_skybox_render_pass(ctx.res, cmd)
        copy_image_to_buffer(cmd, ctx.res.color.image, ctx.res.readback, SKY_W, SKY_H)
    }
    map_memory_to_array(ctx.device, ctx.res.readback.memory, ctx.res.buf_size) $(m) {
        pixels := m
    }
    return <- pixels
}

//! One-shot: build a context and render one frame.
def public render_skybox(time, camera_t : float) : array<uint8> {
    var inscope ctx <- build_skybox_context()
    return <- render_skybox_frame(ctx, time, camera_t)
}

//! Sample the RGB of pixel (x,y) from a SKY_W*SKY_H RGBA8 buffer.
def public px(pixels : array<uint8>; x, y : int) : int3 {
    let p = (y * SKY_W + x) * 4
    return int3(int(pixels[p]), int(pixels[p + 1]), int(pixels[p + 2]))
}
