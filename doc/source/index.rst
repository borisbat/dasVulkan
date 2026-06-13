.. dasVulkan documentation master file.

dasVulkan documentation
=======================

Part of the daslang ecosystem. See also the `daslang documentation
<https://daslang.io/doc/>`_ and `daslang.io <https://daslang.io>`_.

dasVulkan is the daslang binding for `Vulkan <https://www.vulkan.org/>`_,
generated from the Khronos ``vk.xml`` registry. It ships two layers:

- **vulkan** — the raw binding: the full Vulkan API surface (core + extensions),
  generated as a daslang C++ module dispatching through
  `volk <https://github.com/zeux/volk>`_. It mirrors the C API 1:1 and is **not**
  re-documented here — consult the
  `Vulkan specification <https://registry.khronos.org/vulkan/specs/latest/html/vkspec.html>`_
  for those symbols.
- **vulkan_boost** — the ergonomic layer documented on this site: RAII-owning
  handle wrappers with ``finalize``, idiomatic structs (``array<T>`` instead of
  count+pointer pairs, auto-filled ``sType``), named arguments with defaults,
  and block-bracketing helpers.

**Source code**: https://github.com/borisbat/dasVulkan

**Issues**: https://github.com/borisbat/dasVulkan/issues

Install
=======

Via daspkg:

.. code-block:: bash

   daslang utils/daspkg/main.das -- install github.com/borisbat/dasVulkan

Or add to your project's ``.das_package``:

.. code-block:: das

   [export]
   def dependencies(version : string) {
       require_package("github.com/borisbat/dasVulkan")
   }

Then run ``daspkg install``.

Building the module needs no Vulkan SDK — the vendored Vulkan-Headers and
volk's runtime loading cover it. A real GPU or `Mesa lavapipe
<https://docs.mesa3d.org/drivers/llvmpipe.html>`_ (software ICD, used in CI)
provides the runtime.

----

.. toctree::
   :maxdepth: 2
   :caption: Contents

   stdlib/index
