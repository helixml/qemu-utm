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
endif
