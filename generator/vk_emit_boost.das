options gen2
options indenting = 4
options persistent_heap = true

module vk_emit_boost

require vk_model
require vk_naming
require vk_emit
require daslib/fio
require strings
require daslib/strings_boost

// OB / CB / GEN_HEADER are re-exported from vk_emit

// ===== ctors: sType-filling constructors over the RAW Vk structs =====
// daslang has no #if, so the boost can only reference types registered on every
// platform -- emit only for non-platform-guarded structs (protect == "").

def private emit_ctors(reg : VkRegistry; em : EmitModel; out_dir : string) {
    let stype_prefix = enum_value_prefix("VkStructureType", false, reg.vendor_tags)
    var count = 0
    fopen("{out_dir}/vulkan_ctors.das", "wb") $(f) {
        panic("can't write vulkan_ctors.das") if (f == null)
        fprint(f, GEN_HEADER)
        fprint(f, "options gen2\noptions indenting = 4\n\nmodule vulkan_ctors\n\nrequire vulkan public\n\n")
        for (s in reg.structs) {
            continue if (!empty(s.alias))
            continue if (!key_exists(em.struct_emit, s.name))
            continue if (!empty(s.protect))
            // find the sType member (always named "sType" with a values= attribute)
            var stype_const = ""
            for (m in s.members) {
                if (m.name == "sType" && !empty(m.stype_value)) {
                    stype_const = m.stype_value
                    break
                }
            }
            continue if (empty(stype_const))
            let short = enum_short_name(stype_prefix, stype_const)
            fprint(f, "//! construct a {s.name} with sType pre-filled\n")
            fprint(f, "def {s.name}() : {s.name} {OB}\n")
            fprint(f, "    var self : {s.name}\n")
            fprint(f, "    self.sType = VkStructureType.{short}\n")
            fprint(f, "    return self\n")
            fprint(f, "{CB}\n\n")
            count++
        }
    }
    to_log(LOG_INFO, "boost: {count} sType constructors -> vulkan_ctors.das\n")
}

// ===== ownership: derive create/destroy pairs, emit wrapper structs =====

//! the idiomatic boost name for a handle: strip the leading "Vk"
def public boost_name(vk_handle : string) : string {
    if (vk_handle |> starts_with("Vk")) {
        return vk_handle |> slice(2)
    }
    return vk_handle
}

struct ParentField {
    field : string      //! "_device"
    vktype : string     //! "VkDevice"
}

struct OwnerInfo {
    handle : string         //! VkImage
    boost : string          //! Image
    destroyer : string      //! vkDestroyImage / vkFreeMemory  ("" = no destroyer)
    parents : array<ParentField>
    pool_owned : bool       //! freed by a pool (cmd buffers / descriptor sets) -> finalize no-op
}

def private is_boost_handle(em : EmitModel; tn : string) : bool {
    return key_exists(em.handle_names, tn)
}

//! a command is a destroyer if it is named vkDestroy*/vkFree* and takes a handle param
def private find_destroyers(reg : VkRegistry; em : EmitModel) : table<string; int> {
    var result : table<string; int>    // handle name -> command index
    for (c, idx in reg.commands, range(length(reg.commands))) {
        continue if (!empty(c.alias))
        continue if (!key_exists(reg.enabled_commands, c.name))
        continue if (!empty(c.protect))
        let is_destroy = c.name |> starts_with("vkDestroy")
        let is_free = c.name |> starts_with("vkFree")
        continue if (!is_destroy && !is_free)
        // the destroyed handle is the (usually last) handle-typed param
        for (p in c.params) {
            if (is_boost_handle(em, p.type_name) && !key_exists(result, p.type_name)) {
                result[p.type_name] = idx
            }
        }
    }
    return <- result
}

def public derive_owners(reg : VkRegistry; em : EmitModel) : array<OwnerInfo> {
    let destroyers = find_destroyers(reg, em)
    var owners : array<OwnerInfo>
    for (h in reg.handles) {
        continue if (!empty(h.alias))
        continue if (!is_boost_handle(em, h.name))
        continue if (!empty(h.protect))
        var oi = OwnerInfo(handle = h.name, boost = boost_name(h.name))
        let didx = destroyers?[h.name] ?? -1
        if (didx >= 0) {
            let dc & = unsafe(reg.commands[didx])
            oi.destroyer = dc.name
            // parents = the np==0 handle params that appear before the destroyed handle
            for (p in dc.params) {
                if (p.type_name == h.name) {
                    break
                }
                if (is_boost_handle(em, p.type_name) && p.num_ptrs == 0) {
                    oi.parents |> emplace(ParentField(field = "_{das_safe_name(p.name)}", vktype = p.type_name))
                }
            }
            // array-free (the destroyed handle param is a pointer) => pool-owned, finalize is a no-op
            for (p in dc.params) {
                if (p.type_name == h.name && p.num_ptrs >= 1) {
                    oi.pool_owned = true
                }
            }
        }
        owners |> emplace(oi)
    }
    return <- owners
}

def private emit_handles_boost(reg : VkRegistry; em : EmitModel; out_dir : string; owners : array<OwnerInfo>) {
    fopen("{out_dir}/vulkan_handles.das", "wb") $(f) {
        panic("can't write vulkan_handles.das") if (f == null)
        fprint(f, GEN_HEADER)
        fprint(f, "options gen2\noptions indenting = 4\n\nmodule vulkan_handles\n\n")
        fprint(f, "require vulkan public\nrequire vulkan/vulkan_runtime public\n\n")
        for (oi in owners) {
            // wrapper struct -- handles stored as uint64 (their ABI form) so wrapper
            // copies are friction-free; reinterpret to the typed handle at the boundary.
            fprint(f, "struct {oi.boost} \{\n")
            fprint(f, "    _vk : uint64\n")
            fprint(f, "    _needs_delete : bool\n")
            for (pf in oi.parents) {
                fprint(f, "    {pf.field} : uint64\n")
            }
            fprint(f, "\}\n")
            // finalize
            fprint(f, "def finalize(var self : {oi.boost}) \{\n")
            if (!empty(oi.destroyer) && !oi.pool_owned) {
                fprint(f, "    if (self._needs_delete) \{\n")
                fprint(f, "        unsafe \{\n")
                fprint(f, "            {oi.destroyer}(")
                for (pf in oi.parents) {
                    fprint(f, "reinterpret<{pf.vktype}>(self.{pf.field}), ")
                }
                fprint(f, "reinterpret<{oi.handle}>(self._vk), null)\n")
                fprint(f, "        \}\n")
                fprint(f, "    \}\n")
            }
            fprint(f, "    self._needs_delete = false\n")
            fprint(f, "\}\n")
            // conversions
            fprint(f, "def boost_value_to_vk(self : {oi.boost}) : {oi.handle} \{ return unsafe(reinterpret<{oi.handle}>(self._vk)) \}\n")
            fprint(f, "def vk_value_to_boost(v : {oi.handle}) : {oi.boost} \{ var b : {oi.boost}; b._vk = unsafe(reinterpret<uint64>(v)); return b \}\n\n")
        }
    }
    to_log(LOG_INFO, "boost: {length(owners)} handle wrappers -> vulkan_handles.das\n")
}

// ===== orchestrator =====

def public emit_boost(reg : VkRegistry; var em : EmitModel; out_dir : string) {
    emit_ctors(reg, em, out_dir)
    let owners <- derive_owners(reg, em)
    emit_handles_boost(reg, em, out_dir, owners)
}
