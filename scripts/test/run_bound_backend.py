"""Stream a bound backend and relay interruption to its owned process group."""

import os
import signal
import subprocess
import sys
from pathlib import Path


def run(log_path: Path, argv: list[str]) -> int:
    child = None
    interrupted = 0

    def relay(number, _frame):
        nonlocal interrupted
        interrupted = number
        if child is not None and child.poll() is None:
            try:
                os.killpg(child.pid, number)
            except ProcessLookupError:
                pass

    previous = {number: signal.signal(number, relay) for number in (signal.SIGINT, signal.SIGTERM)}
    try:
        if interrupted:
            return 128 + interrupted
        with log_path.open("wb") as log:
            try:
                child = subprocess.Popen(
                    argv,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    start_new_session=True,
                    bufsize=0,
                )
            except OSError:
                print("Backend could not start.", file=sys.stderr)
                return 1
            if interrupted:
                relay(interrupted, None)
            while chunk := child.stdout.read(65536):
                log.write(chunk)
                log.flush()
                sys.stdout.buffer.write(chunk)
                sys.stdout.buffer.flush()
            code = child.wait()
            return 128 + interrupted if interrupted else (128 - code if code < 0 else code)
    finally:
        if child is not None:
            if child.poll() is None:
                relay(signal.SIGTERM, None)
                child.wait()
            child.stdout.close()
        for number, handler in previous.items():
            signal.signal(number, handler)


def main(argv: list[str]) -> int:
    if len(argv) < 4 or argv[2] != "--":
        print("Usage: run_bound_backend <log-path> -- <command> [args...]", file=sys.stderr)
        return 2
    return run(Path(argv[1]), argv[3:])


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
