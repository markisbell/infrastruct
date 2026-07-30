# Builds the Linux tarball end to end (run on Windows; needs Docker + WSL):
#   1. exports the Godot game for Linux (.tools/linux_release.x86_64 template)
#   2. freezes the three solver backends with PyInstaller INSIDE a
#      python:3.12-slim container (glibc binaries; each backend keeps its
#      own dependency set, like the Windows per-venv freezes)
#   3. stages the payload and packs infrastruct-<version>-linux-x86_64.tar.gz
#      through WSL so the executable bits survive
# Result: extract anywhere on a Linux x86_64 box (glibc >= 2.36, Vulkan GPU
# for the game window), ./infrastruct.x86_64 - no Python/Godot required.
$ErrorActionPreference = "Stop"
$root = Resolve-Path "$PSScriptRoot\..\.."
$build = "$root\.tools\dist-build"
$godot = "$root\.tools\godot\Godot_v4.7.1-stable_win64_console.exe"
$version = (Select-String -Path "$PSScriptRoot\setup.iss" -Pattern 'MyAppVersion "([^"]+)"').Matches[0].Groups[1].Value

New-Item -ItemType Directory -Force "$build\dist\game-linux" | Out-Null

# 1. game export (pck embedded)
& $godot --headless --path "$root\game" --export-release "Linux"
if (-not (Test-Path "$build\dist\game-linux\infrastruct.x86_64")) { throw "Linux game export failed" }

# 2. backend freezes in Linux containers (skipped when present - delete to rebuild)
$repoMount = ($root -replace '\\', '/')
$freezes = @(
    @{ src = "rtpowerflow";  name = "netzsim-frozen";     entry = "entry_power.py"; extra = "--collect-all netzsim" },
    @{ src = "rtheatflow";   name = "rtheatflow-frozen";  entry = "entry_heat.py";  extra = "--collect-all pandapipes --collect-all rtheatflow" },
    @{ src = "rtwaterflow";  name = "rtwaterflow-frozen"; entry = "entry_water.py"; extra = "--collect-all pandapipes --collect-all rtwaterflow" }
)
foreach ($f in $freezes) {
    if (Test-Path "$build\dist-linux\$($f.name)\$($f.name)") { continue }
    $cmd = "set -e; pip install --no-cache-dir /repo/backends/$($f.src) pyinstaller > /tmp/pip.log 2>&1 || (tail -20 /tmp/pip.log; exit 1); " +
        "cp /repo/.tools/dist-build/$($f.entry) /tmp/; cd /tmp; " +
        "pyinstaller --noconfirm --onedir --name $($f.name) " +
        "--distpath /repo/.tools/dist-build/dist-linux --workpath /tmp/work " +
        "--collect-all pandapower --collect-all numba --collect-all llvmlite " +
        "--hidden-import uvicorn.logging --hidden-import uvicorn.loops.auto " +
        "--hidden-import uvicorn.protocols.http.auto " +
        "--hidden-import uvicorn.protocols.websockets.auto " +
        "--hidden-import uvicorn.lifespan.on $($f.extra) $($f.entry)"
    docker run --rm -v "${repoMount}:/repo" python:3.12-slim bash -c $cmd
    if ($LASTEXITCODE -ne 0) { throw "container freeze failed: $($f.name)" }
}

# 3. stage the payload (fresh tree, like the Windows build)
$stage = "$build\stage-linux"
if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
if (Test-Path $stage) { throw "stage-linux not removable" }
New-Item -ItemType Directory -Force "$stage\orchestration", "$stage\backends" | Out-Null
Copy-Item "$build\dist\game-linux\infrastruct.x86_64" $stage
Copy-Item "$root\orchestration\sidecars_dist_linux.json" "$stage\orchestration\sidecars.json"
$backends = @(
    @{ id = "power"; dist = "netzsim-frozen";     src = "rtpowerflow" },
    @{ id = "heat";  dist = "rtheatflow-frozen";  src = "rtheatflow" },
    @{ id = "water"; dist = "rtwaterflow-frozen"; src = "rtwaterflow" }
)
foreach ($b in $backends) {
    Copy-Item -Recurse "$build\dist-linux\$($b.dist)" "$stage\backends\$($b.id)"
    Copy-Item -Recurse "$root\backends\$($b.src)\data" "$stage\backends\$($b.id)\data"
}
Set-Content -Encoding utf8 "$stage\README.txt" @"
infrastruct $version (Linux x86_64)

Extract anywhere and run:  ./infrastruct.x86_64
Needs: glibc 2.36+, a Vulkan-capable GPU. No Python or Godot required.
The three physics solvers listen on 127.0.0.1:8010-8012 while playing.
Saves live under ~/.local/share/godot/app_userdata/infrastruct/.
"@

# 4. pack via WSL so the executable bits survive in the tarball
$stageWsl = (wsl wslpath -a ($stage -replace '\\', '/')).Trim()
$buildWsl = (wsl wslpath -a ($build -replace '\\', '/')).Trim()
$tarName = "infrastruct-$version-linux-x86_64.tar.gz"
wsl bash -c "cd '$stageWsl' && chmod +x infrastruct.x86_64 backends/power/netzsim-frozen backends/heat/rtheatflow-frozen backends/water/rtwaterflow-frozen && cd .. && rm -f '$buildWsl/$tarName' && tar -czf '$buildWsl/$tarName' -C '$stageWsl' --transform 's|^\./|infrastruct/|' --show-transformed-names ./"
if ($LASTEXITCODE -ne 0) { throw "tar failed" }
Get-ChildItem "$build\$tarName" | ForEach-Object {
    "TARBALL: $($_.FullName) ($([math]::Round($_.Length / 1MB)) MB)"
}
