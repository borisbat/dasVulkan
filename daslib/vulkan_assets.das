options gen2
options indenting = 4

// Shared asset loaders for the tutorials: file textures (via dasStbImage) and OBJ models (via the
// daslang glsl/geom_gen OBJ parser). Both upload onto GPU resources with the same staging path the
// cube tutorial uses inline. The actual asset FILES live in tutorials/_assets/ (all CC0).
//
// NOTE: this requires dasStbImage. The lavapipe CI daslang build is compiled WITHOUT stbimage (same
// reason the recording/ folders are CI-skipped), so a tutorial pixel-oracle that loads a file texture
// must soft-skip when stbimage is unavailable -- or the CI build must add stbimage. Locally it just works.

module vulkan_assets

require vulkan public
require vulkan/vulkan_boost public
require stbimage/stbimage_boost
require geometry/geom_gen
require math

// ===== textures =====

//! A GPU texture: device-local image + its memory + a 2D view. Bind through a combined image sampler.
struct public Texture {
    image  : vulkan_handles::Image
    memory : DeviceMemory
    view   : ImageView
    width  : int
    height : int
}

def public finalize(var t : Texture) {
    unsafe {
        delete t.view
        delete t.image
        delete t.memory
    }
}

// Isolate the dasStbImage `Image` (clashes with vulkan's `Image` name) to this one helper: load a
// file as 4-channel data and hand back the raw bytes + dimensions. hdr=true loads float (bpc=4).
def private load_pixels(path : string; hdr : bool; var w, h : int; var bytes : array<uint8>) : bool {
    var simg : stbimage_boost::Image
    let r = hdr ? simg.load_hdr(path, 4) : simg.load(path, 4)
    if (!r._0) {
        return false
    }
    w = simg.width
    h = simg.height
    bytes <- simg.bytes
    return true
}

//! Upload already-decoded pixel `bytes` (w*h*`fmt`) as a sampled device-local image of `fmt`.
def public upload_texture(device : Device; phys : VkPhysicalDevice; queue : VkQueue; pool : CommandPool;
                          w, h : int; fmt : VkFormat; var bytes : array<uint8>) : Texture {
    let dev = boost_value_to_vk(device)
    var ici = ImageCreateInfo(imageType = VkImageType._2D, format = fmt, mipLevels = 1u, arrayLayers = 1u,
        tiling = VkImageTiling.OPTIMAL, initialLayout = VkImageLayout.UNDEFINED)
    ici.extent.width = uint(w)
    ici.extent.height = uint(h)
    ici.extent.depth = 1u
    ici.samples._1 = true
    ici.usage.sampled = true
    ici.usage.transfer_dst = true
    var inscope image <- create_image(device, ici)
    var ireq : VkMemoryRequirements
    vkGetImageMemoryRequirements(dev, boost_value_to_vk(image), ireq)
    var iwant : VkMemoryPropertyFlags
    iwant.device_local = true
    var imai = MemoryAllocateInfo(allocationSize = ireq.size,
        memoryTypeIndex = find_memory_type(phys, ireq.memoryTypeBits, iwant))
    var inscope memory <- allocate_memory(device, imai)
    vk_check(vkBindImageMemory(dev, boost_value_to_vk(image), boost_value_to_vk(memory), 0ul), null)

    var vci = ImageViewCreateInfo(image = weak_copy(image), viewType = VkImageViewType._2D, format = fmt)
    vci.subresourceRange.aspectMask.color = true
    vci.subresourceRange.levelCount = 1u
    vci.subresourceRange.layerCount = 1u
    var inscope view <- create_image_view(device, vci)

    var staging_usage : VkBufferUsageFlags
    staging_usage.transfer_src = true
    var inscope staging <- create_host_buffer_from_bytes(device, phys, staging_usage, bytes)
    run_cmd_sync(device, pool, queue) $(cmd) {
        let none : VkAccessFlags
        var to_dst : VkAccessFlags
        to_dst.transfer_write = true
        var to_read : VkAccessFlags
        to_read.shader_read = true
        var top : VkPipelineStageFlags
        top.top_of_pipe = true
        var xfer : VkPipelineStageFlags
        xfer.transfer = true
        var frag_stage : VkPipelineStageFlags
        frag_stage.fragment_shader = true
        transition_image(cmd, image, VkImageLayout.UNDEFINED, VkImageLayout.TRANSFER_DST_OPTIMAL, none, to_dst, top, xfer)
        var region : BufferImageCopy
        region.imageSubresource.aspectMask.color = true
        region.imageSubresource.layerCount = 1u
        region.imageExtent.width = uint(w)
        region.imageExtent.height = uint(h)
        region.imageExtent.depth = 1u
        var regions : array<BufferImageCopy>
        regions |> emplace(region)
        cmd_copy_buffer_to_image(cmd, staging.buffer, image, VkImageLayout.TRANSFER_DST_OPTIMAL, regions)
        transition_image(cmd, image, VkImageLayout.TRANSFER_DST_OPTIMAL, VkImageLayout.SHADER_READ_ONLY_OPTIMAL,
            to_dst, to_read, xfer, frag_stage)
    }
    return <- Texture(image <- image, memory <- memory, view <- view, width = w, height = h)
}

//! Load an 8-bit file texture (PNG/JPG) as a sampled image. `srgb` picks R8G8B8A8_SRGB (albedo) vs
//! _UNORM (data maps: normal / roughness / AO). Panics if the file can't be decoded.
def public load_texture_2d(device : Device; phys : VkPhysicalDevice; queue : VkQueue; pool : CommandPool;
                           path : string; srgb : bool = false) : Texture {
    var w, h : int
    var bytes : array<uint8>
    if (!load_pixels(path, false, w, h, bytes)) {
        panic("load_texture_2d: cannot decode '{path}'")
    }
    let fmt = srgb ? VkFormat.R8G8B8A8_SRGB : VkFormat.R8G8B8A8_UNORM
    var tex <- upload_texture(device, phys, queue, pool, w, h, fmt, bytes)
    delete bytes
    return <- tex
}

//! Load a float (HDR) equirectangular image as an R32G32B32A32_SFLOAT sampled image (IBL / env).
def public load_texture_hdr(device : Device; phys : VkPhysicalDevice; queue : VkQueue; pool : CommandPool;
                            path : string) : Texture {
    var w, h : int
    var bytes : array<uint8>
    if (!load_pixels(path, true, w, h, bytes)) {
        panic("load_texture_hdr: cannot decode '{path}'")
    }
    var tex <- upload_texture(device, phys, queue, pool, w, h, VkFormat.R32G32B32A32_SFLOAT, bytes)
    delete bytes
    return <- tex
}

// ===== OBJ models =====

//! A GPU mesh: interleaved vertex buffer (pos float3 @0, normal float3 @12, uv float2 @24 -- 32 bytes)
//! + a uint32 index buffer, plus the model-space bounds for fitting.
struct public Mesh {
    vbuf        : HostBuffer
    ibuf        : HostBuffer
    index_count : int
    bmin        : float3
    bmax        : float3
}

def public finalize(var m : Mesh) {
    unsafe {
        delete m.ibuf
        delete m.vbuf
    }
}

//! Load an OBJ model into vertex + index buffers via the daslang glsl/geom_gen parser (positions +
//! normals + texcoords, interleaved 32-byte vertices). `dir` is the search directory for the file.
def public load_obj_model(device : Device; phys : VkPhysicalDevice; fname, dir : string) : Mesh {
    var frag <- load_obj_mesh(fname, dir, dir, false)
    var vb_usage : VkBufferUsageFlags
    vb_usage.vertex_buffer = true
    var inscope vbuf <- create_host_buffer_from_bytes(device, phys, vb_usage, frag.vertices)
    var ib_usage : VkBufferUsageFlags
    ib_usage.index_buffer = true
    var inscope ibuf <- create_host_buffer_from_bytes(device, phys, ib_usage, frag.indices)
    let n = length(frag.indices)
    let bmin = frag.bmin
    let bmax = frag.bmax
    delete frag
    return <- Mesh(vbuf <- vbuf, ibuf <- ibuf, index_count = n, bmin = bmin, bmax = bmax)
}
