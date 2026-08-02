#!/usr/bin/env bash
# SimGames launcher — starts the game as a normal desktop app.
# The game spawns and supervises its Python solver backends itself
# (ports 8010/8011); closing the game window shuts them down cleanly.
# Live power-flow monitor while playing: http://localhost:8010
cd "$(dirname "$0")"
# Hybrid-graphics laptops: prefer the NVIDIA dGPU via PRIME render offload
# (harmless no-ops when no NVIDIA driver / on other machines). Needs the
# proprietary driver installed — nouveau ships no Vulkan ICD.
export __NV_PRIME_RENDER_OFFLOAD=1
export __VK_LAYER_NV_optimus=NVIDIA_only
export __GLX_VENDOR_LIBRARY_NAME=nvidia
exec .tools/godot/Godot_v4.7.1-stable_linux.x86_64 --path game "$@"
