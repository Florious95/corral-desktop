#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
exec python3 - "$SCRIPT_DIR" "$@" <<'PY'
import argparse, datetime as dt, hashlib, json, os, platform, re, statistics, subprocess, sys, time
from pathlib import Path

root = Path(sys.argv[1])
parser = argparse.ArgumentParser(description="Read-only macOS footprint/vmmap sampler for an isolated native-app PID.")
parser.add_argument("pid", type=int)
parser.add_argument("--mode", choices=("idle", "sustained", "high-entropy", "background"), default="idle")
parser.add_argument("--duration", type=float, default=30.0)
parser.add_argument("--interval", type=float, default=1.0)
parser.add_argument("--metrics-json", type=Path, help="optional app instrumentation receipt (schema v1; see README)")
parser.add_argument("--source-sha", default=os.environ.get("CORRAL_SOURCE_SHA"))
parser.add_argument("--out-dir", type=Path, default=root / "ledgers")
args = parser.parse_args(sys.argv[2:])


def refuse(message):
    print("REFUSED: " + message, file=sys.stderr)
    raise SystemExit(2)

if platform.system() != "Darwin":
    refuse("footprint/vmmap collection is macOS-only")
if args.pid <= 1 or args.duration <= 0 or args.interval <= 0:
    refuse("PID, duration, and interval must be positive")
if args.pid in {87692, 72646, 90213}:
    refuse("production service/client PID is permanently protected")

def run(argv, timeout=20):
    return subprocess.run(argv, check=False, capture_output=True, text=True, timeout=timeout)

def process_identity(pid):
    start = run(["ps", "-p", str(pid), "-o", "lstart="]).stdout.strip()
    comm = run(["ps", "-p", str(pid), "-o", "comm="]).stdout.strip()
    images = run(["/usr/sbin/lsof", "-nP", "-a", "-p", str(pid), "-d", "txt", "-Fn"]).stdout.splitlines()
    paths = sorted(line[1:] for line in images if line.startswith("n/"))
    if not start:
        refuse("target PID is not live")
    if any("/Applications/Corral.app/" in path for path in paths):
        refuse("production Corral.app is permanently protected")
    return {"start": start, "comm": comm, "paths": paths}

prod_listener = run(["/usr/sbin/lsof", "-nP", "-t", "-iTCP:9900", "-sTCP:LISTEN"]).stdout.split()
if str(args.pid) in prod_listener:
    refuse("target PID owns the protected production 9900 listener")
identity = process_identity(args.pid)
exe_path = identity["paths"][0] if identity["paths"] else None
exe_hash = None
if exe_path and Path(exe_path).is_file():
    h = hashlib.sha256()
    with open(exe_path, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    exe_hash = h.hexdigest()


def parse_bytes(text):
    m = re.fullmatch(r"([0-9]+(?:\.[0-9]+)?)([KMGTP]?)", text.strip())
    if not m:
        return None
    scale = {"": 1, "K": 1024, "M": 1024**2, "G": 1024**3, "T": 1024**4, "P": 1024**5}[m.group(2)]
    return int(float(m.group(1)) * scale)

number = r"(?:[0-9]+(?:\.[0-9]+)?[KMGTP]?|[-]+)"
region_re = re.compile(r"^\s*(.+?)\s+(" + number + r")\s+(" + number + r")\s+(" + number + r")\s+[0-9]+\s+")

def parse_vmmap(text):
    physical = re.search(r"^Physical footprint:\s*([0-9]+(?:\.[0-9]+)?[KMGTP]?)\s*$", text, re.M)
    result = {"physical_footprint_bytes": parse_bytes(physical.group(1)) if physical else None,
              "iosurface_regions": [], "metal_ioaccelerator_regions": [], "malloc_dirty_bytes": 0, "malloc_regions": []}
    in_table = False
    for line in text.splitlines():
        if "REGION TYPE" in line:
            in_table = True
            continue
        if not in_table or line.lstrip().startswith("==========="):
            continue
        m = region_re.match(line)
        if not m:
            continue
        name, virtual, resident, dirty = m.groups()
        name = name.strip()
        if name == "TOTAL":
            in_table = False
            continue
        row = {"region": name, "virtual_bytes": parse_bytes(virtual), "resident_bytes": parse_bytes(resident), "dirty_bytes": parse_bytes(dirty)}
        upper = name.upper()
        if upper.startswith("MALLOC"):
            result["malloc_dirty_bytes"] += row["dirty_bytes"] or 0
            result["malloc_regions"].append(row)
        if "IOSURFACE" in upper:
            result["iosurface_regions"].append(row)
        if any(key in upper for key in ("IOACCELERATOR", "METAL", "MTL", "AGX")):
            result["metal_ioaccelerator_regions"].append(row)
    if not result["malloc_regions"]:
        result["malloc_dirty_bytes"] = None
    return result

def sample():
    fp = run(["/usr/bin/footprint", "--pid", str(args.pid), "--format", "bytes"])
    vm = run(["/usr/bin/vmmap", "-summary", str(args.pid)])
    if fp.returncode != 0 or vm.returncode != 0:
        return {"sampled_at_utc": dt.datetime.now(dt.timezone.utc).isoformat(), "error": "footprint/vmmap command failed"}
    footprint = re.search(r"Footprint:\s*([0-9,]+)\s*B", fp.stdout)
    if not footprint:
        return {"sampled_at_utc": dt.datetime.now(dt.timezone.utc).isoformat(), "error": "footprint output had no byte total"}
    vm_values = parse_vmmap(vm.stdout)
    if vm_values["physical_footprint_bytes"] is None:
        return {"sampled_at_utc": dt.datetime.now(dt.timezone.utc).isoformat(), "error": "vmmap summary had no physical footprint"}
    return {"sampled_at_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
            "footprint_bytes": int(footprint.group(1).replace(",", "")), **vm_values}

started_at = dt.datetime.now(dt.timezone.utc)
start_mono = time.monotonic()
samples = []
while time.monotonic() - start_mono < args.duration:
    lap = time.monotonic()
    if process_identity(args.pid)["start"] != identity["start"]:
        refuse("target PID identity changed during sampling")
    try:
        samples.append(sample())
    except subprocess.TimeoutExpired:
        samples.append({"sampled_at_utc": dt.datetime.now(dt.timezone.utc).isoformat(), "error": "footprint/vmmap timed out"})
    remaining = args.interval - (time.monotonic() - lap)
    if remaining > 0:
        time.sleep(min(remaining, max(0, args.duration - (time.monotonic() - start_mono))))
ended_at = dt.datetime.now(dt.timezone.utc)
valid = [s for s in samples if "footprint_bytes" in s]
failures = len(samples) - len(valid)

metrics = None
if args.metrics_json:
    try:
        metrics = json.loads(args.metrics_json.read_text())
        if metrics.get("schema_version") != 1 or int(metrics.get("pid", -1)) != args.pid or metrics.get("mode") != args.mode:
            refuse("app instrumentation receipt schema/PID/mode does not match this run")
        for key in ("metal_submission_count", "rendered_frames"):
            if not isinstance(metrics.get(key), int) or metrics[key] < 0:
                refuse("app instrumentation receipt has invalid counters")
        window = float(metrics.get("window_duration_seconds", 0))
        if window <= 0 or window > args.duration + max(args.interval, 1.0):
            refuse("app instrumentation receipt window is inconsistent with sampler duration")
        metrics = {"source_file": args.metrics_json.name, "schema_version": 1, "mode": args.mode,
                   "window_duration_seconds": window, "metal_submission_count": metrics["metal_submission_count"],
                   "rendered_frames": metrics["rendered_frames"], "render_fps": metrics["rendered_frames"] / window,
                   "view_state": metrics.get("view_state", "unknown")}
    except (OSError, ValueError, TypeError, json.JSONDecodeError) as e:
        refuse("cannot read app instrumentation receipt: " + str(e))

gpu = {"attribution_status": "unavailable" if metrics is None else "app_instrumentation",
       "metal_submission_count": None if metrics is None else metrics["metal_submission_count"],
       "rendered_frames": None if metrics is None else metrics["rendered_frames"],
       "render_fps": None if metrics is None else metrics["render_fps"],
       "device_gpu_percent": None,
       "note": "GPU usage is not inferred from RSS or vmmap; device GPU percentage requires an app-attributed instrumented source."}
idle_proven = bool(metrics and args.mode == "idle" and metrics["view_state"] == "idle" and metrics["metal_submission_count"] == 0 and metrics["rendered_frames"] == 0)

version = run(["/usr/bin/sw_vers", "-productVersion"]).stdout.strip()
hardware = run(["/usr/sbin/sysctl", "-n", "machdep.cpu.brand_string"]).stdout.strip()
report = {
    "schema_version": 1,
    "captured_at_utc": ended_at.isoformat(),
    "target": {"pid": args.pid, "process_name": identity["comm"], "executable_basename": Path(exe_path).name if exe_path else None, "executable_sha256": exe_hash, "process_start_time": identity["start"]},
    "provenance": {"source_sha": args.source_sha, "macos_version": version, "architecture": platform.machine(), "hardware": hardware, "measurement_tools": {"footprint": "/usr/bin/footprint --pid PID --format bytes", "vmmap": "/usr/bin/vmmap -summary PID"}},
    "sampling": {"mode": args.mode, "requested_duration_seconds": args.duration, "requested_interval_seconds": args.interval, "started_at_utc": started_at.isoformat(), "ended_at_utc": ended_at.isoformat(), "samples": len(samples), "successful_samples": len(valid), "failed_samples": failures, "series": samples},
    "memory_summary": {"footprint_min_bytes": min((s["footprint_bytes"] for s in valid), default=None), "footprint_max_bytes": max((s["footprint_bytes"] for s in valid), default=None), "footprint_mean_bytes": int(statistics.mean(s["footprint_bytes"] for s in valid)) if valid else None, "footprint_last_bytes": valid[-1]["footprint_bytes"] if valid else None, "vmmap_physical_footprint_last_bytes": valid[-1]["physical_footprint_bytes"] if valid else None, "iosurface_regions_last": valid[-1]["iosurface_regions"] if valid else None, "metal_ioaccelerator_regions_last": valid[-1]["metal_ioaccelerator_regions"] if valid else None, "malloc_dirty_last_bytes": valid[-1]["malloc_dirty_bytes"] if valid else None, "malloc_regions_last": valid[-1]["malloc_regions"] if valid else None},
    "gpu": gpu,
    "idle_window": {"requested": args.mode == "idle", "proven_idle": idle_proven, "status": "measured_zero_metal_submissions" if idle_proven else ("not_idle_or_nonzero" if metrics else "unavailable_without_app_instrumentation")},
    "result": "PASS" if valid and failures == 0 else "INCOMPLETE",
}
if metrics:
    report["gpu"]["instrumentation"] = metrics

args.out_dir.mkdir(parents=True, exist_ok=True)
stamp = ended_at.strftime("%Y%m%dT%H%M%SZ")
base = args.out_dir / ("resource-ledger-%s-%s" % (args.pid, stamp))
json_path, md_path = base.with_suffix(".json"), base.with_suffix(".md")
json_path.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
json_path.chmod(0o600)
lines = ["# Resource ledger", "", "- Result: **%s**" % report["result"], "- PID: %s (%s)" % (args.pid, report["target"]["process_name"]), "- Executable SHA-256: `%s`" % (exe_hash or "unavailable"), "- Mode/window: %s / %.1fs" % (args.mode, args.duration), "- Samples: %d successful / %d failed" % (len(valid), failures), "- Footprint min/max/mean: %s / %s / %s bytes" % (report["memory_summary"]["footprint_min_bytes"], report["memory_summary"]["footprint_max_bytes"], report["memory_summary"]["footprint_mean_bytes"]), "- vmmap Physical footprint (last): %s bytes" % report["memory_summary"]["vmmap_physical_footprint_last_bytes"], "- vmmap IOSurface regions (last): %d" % len(report["memory_summary"]["iosurface_regions_last"] or []), "- vmmap Metal/IOAccelerator regions (last): %d" % len(report["memory_summary"]["metal_ioaccelerator_regions_last"] or []), "- Malloc dirty (last): %s bytes" % report["memory_summary"]["malloc_dirty_last_bytes"], "- Metal submissions / render FPS: %s / %s" % (gpu["metal_submission_count"], gpu["render_fps"]), "- Idle window proven: %s" % idle_proven, "- OS / hardware: %s / %s (%s)" % (version, hardware, platform.machine()), "", "GPU counters unavailable are reported as null, never inferred from process RSS or vmmap.", ""]
md_path.write_text("\n".join(lines))
md_path.chmod(0o600)
print("Resource ledger: " + str(json_path))
print("Markdown report: " + str(md_path))
if not valid or failures:
    raise SystemExit(1)
PY
