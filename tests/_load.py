"""Import the pieces under test from where they actually live.

`bin/noren` has no .py extension, and `reflow` / `siteHostOf` live inside a
QML file and the service worker. Nothing is copied into the tests: a copy would
pass while the real function drifted.
"""

import importlib.machinery
import importlib.util
import json
import pathlib
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "host"))


def cli():
    loader = importlib.machinery.SourceFileLoader("noren_cli", str(ROOT / "bin" / "noren"))
    spec = importlib.util.spec_from_loader("noren_cli", loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


def js_function(path, name):
    """The source of `function name(...) {...}` in `path`, by brace matching."""
    text = (ROOT / path).read_text()
    start = text.index(f"function {name}(")
    depth = 0
    for i in range(text.index("{", start), len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return text[start:i + 1]
    raise ValueError(f"unbalanced braces in {name}")


NODE = shutil.which("node")


def run_js(source, name, inputs):
    """Call a JS function on each input under node; returns the outputs."""
    program = (
        source
        + f"\nconst inputs = JSON.parse(require('fs').readFileSync(0, 'utf8'));"
        + f"\nprocess.stdout.write(JSON.stringify(inputs.map((x) => {name}(x))));"
    )
    out = subprocess.run([NODE, "-e", program], input=json.dumps(inputs),
                         capture_output=True, text=True, check=True)
    return json.loads(out.stdout)
