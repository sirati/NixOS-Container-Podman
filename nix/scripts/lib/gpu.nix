# GPU / OpenGL passthrough helpers. Pure bash (only bare commands:
# ls/echo/[), so no tool interpolation is needed. Returns a string of
# bash function definitions concatenated into the run script.
#
# accelerator_flags <need_cuda> <need_opengl>: print podman flags for
# nvidia GPU and/or OpenGL passthrough, one token per line. Driven by
# the runtime env var HOST_HAS_NVCT (1 = host's nvidia-container-toolkit
# / CDI available).

{ }:

''
  # accelerator_flags <need_cuda> <need_opengl>: print podman
  # flags for nvidia GPU and/or OpenGL passthrough, one token
  # per line. Handles four combinations:
  #
  # CUDA via nvidia-container-toolkit (HOST_HAS_NVCT=1):
  #   `--device nvidia.com/gpu=all`. The toolkit injects all
  #   /dev/nvidia* nodes and the matching libcuda.so userland.
  #   Cross-distro and recommended; works on Debian, Fedora,
  #   Arch, openSUSE, NixOS, etc.
  #
  # CUDA without toolkit:
  #   Bind every /dev/nvidia* node, plus the host directory
  #   containing libcuda.so*. Probed in order:
  #     /run/opengl-driver/lib     - NixOS convention
  #     /usr/lib/x86_64-linux-gnu  - Debian/Ubuntu
  #     /usr/lib64                 - Fedora/RHEL/openSUSE
  #     /usr/lib                   - Arch and others
  #
  # OpenGL:
  #   Bind every /dev/dri/* node (works for Intel / AMD / Mesa
  #   as well as nvidia's GL). Plus the host directory with
  #   libGL.so*, probed the same way.
  #
  # libcuda and libGL live in the same directory on every
  # distro I know of, so when both are requested we bind that
  # dir once. NixOS: /run/opengl-driver gets bound at the same
  # path. Other distros: bound at /opt/host-graphics-libs;
  # the container's shellInit adds it to LD_LIBRARY_PATH.
  accelerator_flags() {
    local need_cuda=$1 need_opengl=$2
    [ "$need_cuda" = "1" ] || [ "$need_opengl" = "1" ] || return 0

    local found=0

    # CUDA via CDI - injects libcuda + /dev/nvidia* itself.
    if [ "$need_cuda" = "1" ] && [ "$HOST_HAS_NVCT" = "1" ]; then
      echo --device
      echo nvidia.com/gpu=all
      found=1
      # CDI doesn't help with OpenGL / Mesa; fall through to
      # the OpenGL section below if also asked.
    fi

    # CUDA without toolkit: manual /dev/nvidia* binds.
    if [ "$need_cuda" = "1" ] && [ "$HOST_HAS_NVCT" != "1" ]; then
      local d
      for d in /dev/nvidia0 /dev/nvidia1 /dev/nvidia2 /dev/nvidia3 \
               /dev/nvidiactl /dev/nvidia-uvm /dev/nvidia-uvm-tools \
               /dev/nvidia-modeset; do
        if [ -e "$d" ]; then
          echo --device
          echo "$d"
          found=1
        fi
      done
    fi

    # OpenGL: /dev/dri/* binds.
    if [ "$need_opengl" = "1" ]; then
      local d
      for d in /dev/dri/card0 /dev/dri/card1 /dev/dri/card2 \
               /dev/dri/renderD128 /dev/dri/renderD129 \
               /dev/dri/renderD130; do
        if [ -e "$d" ]; then
          echo --device
          echo "$d"
          found=1
        fi
      done
    fi

    # Find userland libs we still need to provide:
    #   - libcuda.so* if need_cuda and not using toolkit
    #   - libGL.so* if need_opengl (toolkit doesn't ship GL libs)
    local need_libdir=0
    [ "$need_cuda" = "1" ] && [ "$HOST_HAS_NVCT" != "1" ] && need_libdir=1
    [ "$need_opengl" = "1" ] && need_libdir=1
    if [ "$need_libdir" = "0" ]; then return 0; fi

    local lib_dir="" d
    for d in /run/opengl-driver/lib \
             /usr/lib/x86_64-linux-gnu \
             /usr/lib64 \
             /usr/lib; do
      [ -d "$d" ] || continue
      if   [ "$need_cuda" = "1" ] && [ "$HOST_HAS_NVCT" != "1" ] \
           && ls -- "$d"/libcuda.so* >/dev/null 2>&1; then
        lib_dir=$d; break
      elif [ "$need_opengl" = "1" ] \
           && ls -- "$d"/libGL.so* >/dev/null 2>&1; then
        lib_dir=$d; break
      fi
    done
    if [ -n "$lib_dir" ]; then
      case "$lib_dir" in
        /run/opengl-driver/lib)
          echo -v
          echo "/run/opengl-driver:/run/opengl-driver:ro"
          ;;
        *)
          echo -v
          echo "$lib_dir:/opt/host-graphics-libs:ro"
          ;;
      esac
    fi
    # found stays informational; the dev shell still works
    # without these libs if e.g. only /dev/dri was requested
    # and you only need a software renderer.
    : "$found"
  }

  # Back-compat shim: gpu_flags / opengl_flags wrap the combined
  # helper above. ENABLE_GPU / ENABLE_OPENGL are exported by
  # the up/boot dispatch.
  gpu_flags() {
    accelerator_flags "$1" "''${ENABLE_OPENGL:-0}"
  }
''
