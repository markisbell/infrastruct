# Builds the Windows installer end to end:
#   1. exports the Godot game (needs .tools/windows_release_x86_64.exe — the
#      4.7.1 release export template, extracted from the official tpz)
#   2. freezes the three solver backends with PyInstaller (their venvs)
#   3. stages the install payload under .tools/dist-build/stage
#   4. compiles tools/installer/setup.iss with Inno Setup 6 (ISCC)
# Result: .tools/dist-build/infrastruct-setup-<version>.exe — installs on a
# clean Windows 11 PC, per-user, no Python/Godot/anything required.
$ErrorActionPreference = "Stop"
$root = Resolve-Path "$PSScriptRoot\..\.."
$build = "$root\.tools\dist-build"
$godot = "$root\.tools\godot\Godot_v4.7.1-stable_win64_console.exe"
$iscc = "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe"
if (-not (Test-Path $iscc)) { $iscc = "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" }

New-Item -ItemType Directory -Force "$build\dist\game" | Out-Null

# 1. game export (pck embedded)
& $godot --headless --path "$root\game" --export-release "Windows Desktop"
if (-not (Test-Path "$build\dist\game\infrastruct.exe")) { throw "game export failed" }

# 2. backend freezes (skipped when the dist already exists — delete to rebuild)
$freezes = @(
    @{ venv = ".venv";       name = "netzsim-frozen";    entry = "entry_power.py"; extra = @() },
    @{ venv = ".venv-heat";  name = "rtheatflow-frozen"; entry = "entry_heat.py";  extra = @("--collect-all", "pandapipes", "--collect-all", "rtheatflow") },
    @{ venv = ".venv-water"; name = "rtwaterflow-frozen"; entry = "entry_water.py"; extra = @("--collect-all", "pandapipes", "--collect-all", "rtwaterflow") }
)
foreach ($f in $freezes) {
    if (Test-Path "$build\dist\$($f.name)\$($f.name).exe") { continue }
    $common = @("--noconfirm", "--onedir", "--name", $f.name,
        "--distpath", "$build\dist", "--workpath", "$build\build-$($f.name)",
        "--specpath", $build,
        "--collect-all", "pandapower", "--collect-all", "numba",
        "--collect-all", "llvmlite",
        "--hidden-import", "uvicorn.logging", "--hidden-import", "uvicorn.loops.auto",
        "--hidden-import", "uvicorn.protocols.http.auto",
        "--hidden-import", "uvicorn.protocols.websockets.auto",
        "--hidden-import", "uvicorn.lifespan.on")
    if ($f.name -eq "netzsim-frozen") { $common += @("--collect-all", "netzsim") }
    & "$root\$($f.venv)\Scripts\pyinstaller.exe" @common @($f.extra) "$build\$($f.entry)"
}

# 3. stage the payload
$stage = "$build\stage"
Remove-Item -Recurse -Force $stage -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force "$stage\orchestration", "$stage\backends" | Out-Null
Copy-Item "$build\dist\game\infrastruct.exe" $stage
Copy-Item "$root\orchestration\sidecars_dist.json" "$stage\orchestration\sidecars.json"
$backends = @(
    @{ id = "power"; dist = "netzsim-frozen";    src = "rtpowerflow" },
    @{ id = "heat";  dist = "rtheatflow-frozen"; src = "rtheatflow" },
    @{ id = "water"; dist = "rtwaterflow-frozen"; src = "rtwaterflow" }
)
foreach ($b in $backends) {
    Copy-Item -Recurse "$build\dist\$($b.dist)" "$stage\backends\$($b.id)"
    Copy-Item -Recurse "$root\backends\$($b.src)\data" "$stage\backends\$($b.id)\data"
}

# 4. compile the installer — through a subst'd drive letter, because the
# frozen pandapipes tree nests past MAX_PATH from a deep repo checkout
subst I: /d 2>$null
subst I: $build
try {
    & $iscc "/DStageDir=I:\stage" "/DOutDir=I:\" "$PSScriptRoot\setup.iss"
    if ($LASTEXITCODE -ne 0) { throw "ISCC failed" }
} finally {
    subst I: /d 2>$null
}
Get-ChildItem "$build\infrastruct-setup-*.exe" | ForEach-Object {
    "INSTALLER: $($_.FullName) ($([math]::Round($_.Length / 1MB)) MB)"
}
