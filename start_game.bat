@echo off
rem SimGames launcher — starts the game as a normal desktop app.
rem The game spawns and supervises its Python solver backends itself
rem (ports 8010/8011); closing the game window shuts them down cleanly.
rem Live power-flow monitor while playing: http://localhost:8010
cd /d "%~dp0"
start "" ".tools\godot\Godot_v4.7.1-stable_win64.exe" --path game
