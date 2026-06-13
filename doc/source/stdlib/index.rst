.. _stdlib:

##########################
  dasVulkan boost API
##########################

The ergonomic ``vulkan_boost`` surface, organised by tier: the RAII handle
wrappers and their creators, the hand-written builder/bracket core, and the
windowing helpers. The raw ``vulkan`` symbols (generated 1:1 from ``vk.xml``)
are not duplicated here — see the
`Vulkan specification <https://registry.khronos.org/vulkan/specs/latest/html/vkspec.html>`_
for the C API surface, and :doc:`overview` for how the boost layer maps onto it.

.. toctree::
   :maxdepth: 2
   :numbered:

   overview
   generated/vulkan_runtime
   generated/vulkan_handles
   generated/vulkan_commands
   generated/vulkan_boost
   generated/vulkan_window
   external_types
