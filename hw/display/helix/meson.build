# Helix Frame Export for QEMU
# Integrates with hw/display/meson.build via subdir('helix')

if host_machine.system() == 'darwin'
  # Framework dependencies for macOS
  videotoolbox = dependency('VideoToolbox', required: true)
  corevideo = dependency('CoreVideo', required: true)
  coremedia = dependency('CoreMedia', required: true)
  iosurface = dependency('IOSurface', required: true)
  metal = dependency('Metal', required: true)
  foundation = dependency('Foundation', required: true)

  system_ss.add(files('helix-frame-export.m'))
  system_ss.add(videotoolbox)
  system_ss.add(corevideo)
  system_ss.add(coremedia)
  system_ss.add(iosurface)
  system_ss.add(metal)
  system_ss.add(foundation)

  # Also need virglrenderer
  system_ss.add(virgl)

  # OpenGL/EGL via epoxy (for GPU blit path: IOSurface-backed GL texture)
  if opengl.found()
    system_ss.add(opengl)
  endif

  # macOS native OpenGL framework (for CGLGetCurrentContext detection)
  opengl_framework = dependency('OpenGL', required: false)
  if opengl_framework.found()
    system_ss.add(opengl_framework)
  endif
endif
