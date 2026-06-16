01 - The Rotating Triangle
==========================

The canonical "hello triangle" -- three vertices, per-vertex red/green/blue,
interpolated across the face -- but with every line of the shader written in
**daslang** and lowered to SPIR-V at compile time by dasSpirv. No GLSL, no
glslang, no committed ``.spv``. A push-constant ``angle`` spins it, so the
recording has a real per-frame GPU parameter to drive.

.. video:: triangle.mp4

The shader
----------

Both stages are plain daslang functions tagged ``[vertex_shader]`` /
``[fragment_shader]``. The emitted ``tri_spin_vert_spv`` / ``tri_spin_frag_spv``
are ``array<uint>`` SPIR-V word blobs, fed straight to ``create_shader_module``.
The vertex stage reads the rotation angle from a ``@push_constant`` struct, builds
a 2D rotation, and spins the hardcoded clip-space positions; the fragment stage
just writes the interpolated varying.

.. literalinclude:: ../../../tutorials/01_triangle/triangle_tut_shaders.das

The render
----------

The offscreen render is the dasVulkan boost path -- an offscreen color target, a
single-color render pass, a graphics pipeline -- with one addition over a static
triangle: a vertex **push-constant range** carrying the angle, pushed each draw
with ``vkCmdPushConstants``. ``render_spin_triangle(angle)`` returns the RGBA8
pixels, a pure parametric ``frame(angle) -> image``.

.. literalinclude:: ../../../tutorials/01_triangle/triangle_tut.das
   :start-at: def public render_spin_triangle

Self-verifying
--------------

The tutorial's test is the CI regression gate -- it runs on lavapipe in CI and a
real GPU locally. At ``angle = 0`` the geometry matches the classic static
triangle, so the proven sample points hold (red top, green/blue bottom corners,
an interpolated centroid). At ``angle = pi`` the red vertex must rotate to
bottom-center and leave the top sample, proving the push-constant actually drives
the vertex shader on the GPU.

.. literalinclude:: ../../../tutorials/01_triangle/test_triangle.das
   :start-at: [test]

Running it
----------

.. code-block:: bash

   # the CI pixel-oracle gate (lavapipe in CI, real GPU locally)
   daslang -load_module <dasVulkan> <daslang>/dastest/dastest.das -- \
       --test <dasVulkan>/tutorials/01_triangle

   # regenerate the recording (needs stbimage + audio + ffmpeg locally)
   daslang -load_module <dasVulkan> \
       <dasVulkan>/tutorials/01_triangle/recording/record_triangle.das
