"""Build the pinned upstream release with one reviewed compatibility patch.

Only synthetic loopback tests run here. No cluster or operator credentials are used.
"""

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import tarfile
import urllib.request
from pathlib import Path


def run(args, cwd, **kwargs):
    return subprocess.run(args, cwd=cwd, check=True, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path, help="new, empty build directory")
    args = parser.parse_args()
    inputs = Path(__file__).resolve().parent
    pin = json.loads((inputs / "source.json").read_text())
    if (inputs / "Dockerfile").read_text().splitlines()[0] != "FROM " + pin["base_image"]:
        raise RuntimeError("container base does not match the reviewed source pin")
    destination = args.directory.resolve()
    destination.mkdir(parents=True, exist_ok=False)
    for tool, expected in (("go", "go version go" + pin["go"]),
                           ("node", "v" + pin["node"]), ("pnpm", pin["pnpm"])):
        command = [tool, "version" if tool == "go" else "--version"]
        actual = run(command, inputs, capture_output=True, text=True).stdout.strip()
        if not (actual.startswith(expected + " ") if tool == "go" else actual == expected):
            raise RuntimeError("build tool version mismatch: " + tool)

    archive = destination / "source.tar.gz"
    url = "https://codeload.github.com/openbao/openbao/tar.gz/" + pin["commit"]
    with urllib.request.urlopen(url, timeout=60) as response, archive.open("wb") as output:
        shutil.copyfileobj(response, output)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != pin["archive_sha256"]:
        raise RuntimeError("upstream source checksum mismatch")
    with tarfile.open(archive) as source:
        source.extractall(destination, filter="data")
    source = destination / ("openbao-" + pin["commit"])
    package = "./internal/builtin/logical/kubernetes"
    shutil.copyfile(inputs / "token_rotation_regression_test.go",
                    source / package / "token_rotation_regression_test.go")
    red = subprocess.run(["go", "test", package, "-run", "^TestLocalTokenRotationKeepsIssuing$",
                          "-count=1"], cwd=source, capture_output=True, text=True, check=False)
    (destination / "rotation-before.log").write_text(red.stdout + red.stderr)
    if red.returncode != 1 or "issuance after token rotation" not in red.stdout:
        raise RuntimeError("unmodified upstream did not reproduce the expected defect")
    run(["patch", "--batch", "--fuzz=0", "-p1", "-i", str(inputs / "token-rotation.patch")], source)
    with (destination / "rotation-after.log").open("w") as output:
        run(["go", "test", package, "-count=1"], source, stdout=output, stderr=subprocess.STDOUT)
    run(["pnpm", "install", "--frozen-lockfile"], source / "ui")
    run(["pnpm", "build"], source / "ui")
    if not (source / "internal/http/web_ui/index.html").is_file():
        raise RuntimeError("upstream UI assets were not built")

    context = destination / "container"
    context.mkdir()
    fingerprint = hashlib.sha256((inputs / "token-rotation.patch").read_bytes()).hexdigest()
    flags = (f"-X github.com/openbao/openbao/v2/internal/version.fullVersion={pin['version']} "
             f"-X github.com/openbao/openbao/v2/internal/version.GitCommit={pin['commit']}-patch-{fingerprint[:12]}")
    run(["go", "build", "-trimpath", "-buildvcs=false", "-tags=ui", "-ldflags", flags,
         "-o", str(context / "bao"), "."], source, env={**os.environ, "CGO_ENABLED": "0"})
    for name in ("Dockerfile", "source.json", "token-rotation.patch"):
        shutil.copyfile(inputs / name, context / name)
    print("Patched OpenBao binary and image context ready: " + str(context))


if __name__ == "__main__":
    main()
