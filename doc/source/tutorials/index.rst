Tutorials
=========

Runnable, self-verifying tutorials for authoring GPU shaders **in daslang** and
driving them through dasVulkan. Each shader is written in daslang and lowered to
SPIR-V at compile time by `dasSpirv <https://github.com/GaijinEntertainment/daScript>`_
(no GLSL, no glslang) -- the same language as the host, compute and graphics alike.

Every tutorial lives in its own self-contained directory under ``tutorials/`` in
the repository: the shaders, the offscreen render, a **pixel-oracle test** that is
the lavapipe CI regression gate, and a recording driver that renders the embedded
``.mp4``. The video on each page is *both* the figure *and* the regression oracle --
it is regenerated and pixel-checked every CI run, never a stale committed screenshot.

.. toctree::
   :maxdepth: 1

   01_triangle
