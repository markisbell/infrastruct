extends GdUnitTestSuite
## SidecarManager launch-command builder (Phase-4 refactor plan): both OS
## branches' command shapes and the venv path translation, testable on
## either platform because the builder takes os_name as a parameter.

const CFG := {"python": ".venv/Scripts/python.exe", "module": "netzsim.main",
	"cwd": "backends/rtpowerflow", "env": {"NETZSIM_EXTERNAL_CLOCK": "true"}}


func test_posix_command_shape() -> void:
	var command := SidecarManager.build_launch_command(
		"Linux", "/repo", CFG, "/repo/orchestration/logs/power_8014.log")
	assert_str(command["exe"]).is_equal("sh")
	assert_str(command["args"][0]).is_equal("-c")
	var script: String = command["args"][1]
	assert_str(script).contains('cd "/repo/backends/rtpowerflow"')
	assert_str(script).contains('export NETZSIM_EXTERNAL_CLOCK="true"')
	# exec makes the spawned pid the backend itself (plain kill suffices)
	assert_str(script).contains('exec "/repo/.venv/bin/python" -m netzsim.main')
	assert_str(script).contains('>> "/repo/orchestration/logs/power_8014.log" 2>&1')


func test_windows_command_shape() -> void:
	var command := SidecarManager.build_launch_command(
		"Windows", "C:/repo", CFG, "C:/repo/orchestration/logs/power_8014.log")
	assert_str(command["exe"]).is_equal("cmd.exe")
	assert_str(command["args"][0]).is_equal("/c")
	var script: String = command["args"][1]
	assert_str(script).contains('cd /d "C:/repo/backends/rtpowerflow"')
	assert_str(script).contains('set "NETZSIM_EXTERNAL_CLOCK=true"')
	# Windows keeps the venv layout verbatim, incl. the .exe suffix
	assert_str(script).contains('"C:/repo/.venv/Scripts/python.exe" -m netzsim.main')
	assert_bool(script.contains("exec ")).is_false()


func test_frozen_exe_config_skips_python() -> void:
	var frozen := {"exe": "backends/power/power.bin", "cwd": "backends/power"}
	var command := SidecarManager.build_launch_command(
		"Linux", "/opt/infrastruct", frozen, "/tmp/p.log")
	var script: String = command["args"][1]
	assert_str(script).contains('exec "/opt/infrastruct/backends/power/power.bin"')
	assert_bool(script.contains(" -m ")).is_false()


func test_python_path_translation() -> void:
	# POSIX: Scripts -> bin, .exe stripped — WITHOUT following symlinks
	# (uv-venv pythons symlink to the base interpreter; resolving escapes
	# the venv — the Linux-port lesson this test pins)
	assert_str(SidecarManager.translate_python_path(
		"Linux", "/repo", ".venv/Scripts/python.exe")) \
		.is_equal("/repo/.venv/bin/python")
	# Windows: verbatim
	assert_str(SidecarManager.translate_python_path(
		"Windows", "C:/repo", ".venv/Scripts/python.exe")) \
		.is_equal("C:/repo/.venv/Scripts/python.exe")
	# a non-venv path is never rewritten
	assert_str(SidecarManager.translate_python_path(
		"Linux", "/repo", "tools/python")).is_equal("/repo/tools/python")
