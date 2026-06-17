options gen2
options indenting = 4

// Vulkan-specific dasSpirv shader subclass + annotations. Mirrors the dasGlsl/dasOpenGL split:
// dasSpirv declares abstract bind hooks on SpirvShader; this subclass overrides them to emit
// Vulkan-flavored bind functions, and three function-macro annotations ([vulkan_vertex_shader],
// [vulkan_fragment_shader], [vulkan_compute_shader]) instantiate the subclass.
//
// generate_bind_uniform walks every @uniform-tagged module global reachable from the shader,
// computes its std140 layout via spirv_emit::compute_block_layout (the same offsets the SPIR-V
// emitter uses to lay out the interface block — single source of truth), and emits one write_field
// call per std140 field at its byte offset. The whole body is wrapped in with_mapped_memory so
// vkMapMemory/vkUnmapMemory bookend a single map cycle per call.

module spirv_vulkan_shader shared public

// vulkan_boost (where with_mapped_memory + write_field live) is NOT a shared module, so this
// shared macro module can't require it directly. It's not needed at macro time anyway — we just
// emit symbolic ExprCall("with_mapped_memory") / ExprCall("write_field") and rely on the consumer
// (tutorial / app) module's `require vulkan/vulkan_boost public` for resolution at codegen time.
// Same trick dasOpenGL's glsl_opengl uses for glUniformAny without requiring opengl_boost.
require spirv/spirv_shader public
require spirv/spirv_emit
require daslib/ast
require daslib/ast_boost

class SpirvVulkanShader : SpirvShader {
    def override generate_bind_uniform_dummy(var func : FunctionPtr) {
        spirv_vulkan_shader::generate_bind_uniform_dummy(func)
    }
    def override generate_bind_uniform(fnMain : FunctionPtr; var fn : FunctionPtr) {
        spirv_vulkan_shader::generate_bind_uniform(fnMain, fn)
    }
}

[function_macro(name="vulkan_compute_shader")]
class SpirvVulkanComputeShader : SpirvVulkanShader {
    def override shader_stage() : ShaderStage => ShaderStage.Compute
}

[function_macro(name="vulkan_vertex_shader")]
class SpirvVulkanVertexShader : SpirvVulkanShader {
    def override shader_stage() : ShaderStage => ShaderStage.Vertex
}

[function_macro(name="vulkan_fragment_shader")]
class SpirvVulkanFragmentShader : SpirvVulkanShader {
    def override shader_stage() : ShaderStage => ShaderStage.Fragment
}

// Reserve an empty bind_uniform_<shader>(device : Device; memory : DeviceMemory) function so
// consumer code referencing it resolves during the first inference pass. The body is filled in
// patch by generate_bind_uniform; until then `exports = true` flags the function as still dummy.
[macro_function]
def private generate_bind_uniform_dummy(fnMain : FunctionPtr) {
    var fn = new Function(at = fnMain.at, atDecl = fnMain.at, name := bind_uniform_function_name(fnMain))
    fn.flags.generated = true
    fn.flags.exports = true
    fn.result = new TypeDecl(at = fnMain.at, baseType = Type.tVoid)
    fn.arguments |> emplace_new() <| new Variable(at = fnMain.at,
        name := "device",
        _type <- new TypeDecl(at = fnMain.at, baseType = Type.alias, alias := "Device")
    )
    fn.arguments |> emplace_new() <| new Variable(at = fnMain.at,
        name := "memory",
        _type <- new TypeDecl(at = fnMain.at, baseType = Type.alias, alias := "DeviceMemory")
    )
    fn.body = new ExprBlock(at = fnMain.at)
    if (!(compiling_module() |> add_function(fn))) {
        panic("can't reserve bind_uniform dummy function for {fnMain.name}")
    }
}

// Fill the dummy bind_uniform function body: for every @uniform struct global reachable from
// fnMain, walk its std140 field layout and emit one write_field call per field. The whole body
// is wrapped in `with_mapped_memory(device, memory) <| $(ptr : void?) { ... }` so each call to
// the generated function does exactly one map/unmap cycle. Samplers/images are skipped here —
// they bind via descriptor-set writes, not via mapped memory.
[macro_function]
def private generate_bind_uniform(fnMain : FunctionPtr; var fn : FunctionPtr) {
    var inner = new ExprBlock(at = fn.at)
    inner.blockFlags.isClosure = true
    inner.returnType = new TypeDecl(at = fn.at, baseType = Type.tVoid)
    var ptr_arg <- new Variable(at = fn.at, name := "ptr")
    ptr_arg._type = new TypeDecl(at = fn.at,
        baseType = Type.tPointer,
        firstType = new TypeDecl(at = fn.at, baseType = Type.tVoid)
    )
    // Mark the parameter type as const so the block sig matches `block<(ptr : void?) : void>` —
    // block params default to const in source, but a macro-built Variable defaults to mutable.
    ptr_arg._type.flags.constant = true
    inner.arguments |> emplace(ptr_arg)

    collect_dependencies(fnMain) $(vfun, vvar) {
        for (vv in vvar) {
            if (!(vv.annotation |> find_arg("uniform") is tBool)) continue
            // Only struct-typed @uniform globals (the std140 interface-block case). Samplers /
            // images / standalone scalars under @uniform either bind via descriptors or aren't
            // supported here; skip them silently — the SPIR-V emitter has already rejected any
            // invalid combos.
            if (vv._type == null || vv._type.baseType != Type.tStructure || vv._type.structType == null) continue
            let st = vv._type.structType
            var layout_errors : array<string>
            var fields : array<BlockField>
            let layout = compute_block_layout(string(vv.name), st, fields, layout_errors)
            if (!layout.ok) {
                delete fields
                delete layout_errors
                continue
            }
            for (f in fields) {
                var cll = new ExprCall(at = vv.at, name := "write_field")
                cll.arguments |> emplace_new() <| new ExprVar(at = vv.at, name := "ptr")
                cll.arguments |> emplace_new() <| new ExprConstUInt(at = vv.at, value = uint(f.offset))
                var fld_access = new ExprField(at = vv.at,
                    value <- new ExprVar(at = vv.at, name := vv.name),
                    name := f.name
                )
                cll.arguments |> emplace(fld_access)
                inner.list |> emplace(cll)
            }
            delete fields
            delete layout_errors
        }
    }

    var mkblk = new ExprMakeBlock(at = fn.at, _block = inner)
    var wmm = new ExprCall(at = fn.at, name := "with_mapped_memory")
    wmm.arguments |> emplace_new() <| new ExprVar(at = fn.at, name := "device")
    wmm.arguments |> emplace_new() <| new ExprVar(at = fn.at, name := "memory")
    wmm.arguments |> emplace(mkblk)

    var body = new ExprBlock(at = fn.at)
    body.list |> emplace(wmm)
    fn.body = body
}
