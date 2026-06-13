# dasVulkan — roadmap / postponed work

The raw binding, the boost layer (handles, vk_view structs, sType ctors, command
wrappers, windowing), array-of-struct marshalling, the resizable swapchain, the
independent-count model, the Linux lavapipe test suite, and the documentation
site all shipped. What's deliberately left, with enough context to pick each up
cold:

## p-prefix strip on boost field names

The boost view structs keep Vulkan's C field names verbatim — `pAttachments`,
`pApplicationInfo`, `renderPass`, `queueFamilyIndex` — even though in daslang
`pAttachments` is just `array<ImageView>`, not a pointer. The `p` / `pp`
Hungarian prefix is meaningless on the boost side.

A p-strip pass would rename the boost field to drop the prefix (`pAttachments` →
`attachments`). It's purely cosmetic: the generated marshalling maps boost-field
→ raw `Vk*`-field by position, so the boost-side name is free to change without
touching the C side.

Deferred because: (1) it's ergonomics, not function; (2) it's a churning
public-API rename touching every example/test that sets a field by name; (3) it's
entangled with two related decisions best made in the same pass — whether to drop
the auto-derived `…Count` fields from the public surface entirely, and whether to
go full snake_case. Do it once, decisively, with the convention nailed down.

## Typed pNext chains

Nearly every Vulkan struct begins `VkStructureType sType; const void* pNext;`.
`pNext` points at another extension struct (also starting sType+pNext), forming a
linked "chain" the driver walks to read optional/extension parameters without
changing the base struct's ABI.

Today this is a raw escape hatch: the boost field is `next : void?`, copied
straight to `vk.pNext`. Attaching an extension struct means manually setting its
`sType`, taking `unsafe(addr(...))`, and keeping it alive across the call.

A typed-chain API would take a list of extension structs, auto-fill each `sType`,
link the `pNext` pointers in order, manage their lifetime via the same scratch
mechanism `vk_view` already uses for arrays, and validate against the registry's
`structextends` metadata (already parsed by the generator) that each struct may
legally extend the base.

Deferred because: the raw `void?` is sufficient for everything the current
examples do (offscreen triangle, compute, windowed present need no chains), and a
typed API needs the `structextends` data wired through the emitter, a
scratch/lifetime mechanism for chained structs, and an API-shape decision
(fluent builder vs. array-of-variant).

## macOS Metal surface — **owned by Boris (needs a Mac to test)**

`vk_surface_from_native` in `src/dasVULKAN.main.cpp` covers Win32 (via the
`extern "C" char __ImageBase;` linker trick for HINSTANCE) and X11. The macOS
path (MoltenVK / `VK_EXT_metal_surface`, `CAMetalLayer` from the `NSWindow`) is
stubbed. Boris will implement and test this on his Mac laptop.

## Windows CI

`tests.yml` and `docs.yml` are Linux-only. A Windows lane needs a software Vulkan
ICD (lavapipe or SwiftShader, via `jakoch/install-vulkan-sdk-action`) with
`VK_DRIVER_FILES` pointed at the ICD JSON. The native-module build already works
on Windows (MSVC) locally; this is purely the CI wiring.

## oldSwapchain reuse

`recreate_swapchain` destroys the old swapchain *before* creating the new one
(destroy-first), because move-assigning the new one while the old still owns the
surface trips `ERROR_NATIVE_WINDOW_IN_USE_KHR`. That leaves a momentary gap where
no swapchain exists. The proper fix passes the old swapchain as
`VkSwapchainCreateInfoKHR.oldSwapchain` so the driver can recycle resources and
the handoff is seamless, then destroys the old one after.

## The skipped command / struct tail

The struct emitter skips ~182 composites and the command emitter ~124 commands —
the irregular long tail: structs/commands whose params are flags-output, raw
`PFN_*` function pointers, foreign/opaque types, or other shapes the uniform
vk_view / classifier rules don't cover. Each is logged at generation time. Most
are exotic extensions; revisit case-by-case if a consumer needs one.
