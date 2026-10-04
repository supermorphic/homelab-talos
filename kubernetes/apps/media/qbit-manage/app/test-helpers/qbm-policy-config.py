"""Write one reviewed, run-scoped qbit_manage policy into a fresh config volume."""

import re
import sys
from pathlib import Path

TEMPLATE_RUN = "qbmscopetemplatenonce"
TEMPLATES = {
    "cz-apply": "cz-isolation.yml",
    "cz-repeat": "cz-isolation.yml",
    "private": "standard-cleanup.yml",
    "limits": "standard-limits.yml",
    "cleanup": "standard-cleanup.yml",
    "cleanup-repeat": "standard-cleanup.yml",
}


def render_policy(run_id: str, phase: str) -> str:
    if not re.fullmatch(r"[a-z0-9]{8,24}", run_id) or phase not in TEMPLATES:
        raise ValueError("expected a bounded run ID and a registered policy phase")
    template = (Path(__file__).resolve().parent / TEMPLATES[phase]).read_text()
    return template.replace(TEMPLATE_RUN, run_id)


def main() -> None:
    if len(sys.argv) != 3:
        raise ValueError("expected exactly RUN_ID PHASE")
    rendered = render_policy(sys.argv[1], sys.argv[2])
    Path("/config/config.yml").write_text(rendered)


if __name__ == "__main__":
    main()
