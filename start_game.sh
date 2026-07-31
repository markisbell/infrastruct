#!/usr/bin/env bash
# SimGames launcher — starts the game as a normal desktop app.
# The game spawns and supervises its Python solver backends itself
# (ports 8010/8011); closing the game window shuts them down cleanly.
# Live power-flow monitor while playing: http://localhost:8010
cd "$(dirname "$0")"
exec .tools/godot/Godot_v4.7.1-stable_linux.x86_64 --path game "$@"
