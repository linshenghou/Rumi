#!/usr/bin/env python3
"""Refresh vendored resource license texts; review resulting diff before release."""

import hashlib
import json
import urllib.request
from pathlib import Path
from urllib.parse import urlsplit

DESTINATION = Path(__file__).resolve().parents[1] / "packaging/licenses"
SOURCES = {
    "Flatbuffers-25.12.19-Apache-2.0.txt": "https://raw.githubusercontent.com/google/flatbuffers/v25.12.19/LICENSE",
    "tqdm-4.70.1-LICENCE.txt": "https://raw.githubusercontent.com/tqdm/tqdm/v4.70.1/LICENCE",
    "MPL-2.0.txt": "https://www.mozilla.org/media/MPL/2.0/index.815ca599c9df.txt",
    "GoNoto-OFL-and-script-Unlicense.txt": "https://raw.githubusercontent.com/satbyy/go-noto-universal/master/UNLICENSE.txt",
    "SourceHan-OFL.txt": "https://raw.githubusercontent.com/adobe-fonts/source-han-sans/release/LICENSE.txt",
    "Noto-OFL.txt": "https://raw.githubusercontent.com/notofonts/noto-fonts/main/LICENSE",
    "Klee-OFL.txt": "https://raw.githubusercontent.com/fontworks-fonts/Klee/master/OFL.txt",
    "LXGWWenKaiGB-OFL.txt": "https://raw.githubusercontent.com/lxgw/LxgwWenKaiGB/main/OFL.txt",
    "LXGWWenKaiTC-OFL.txt": "https://raw.githubusercontent.com/lxgw/LxgwWenkaiTC/main/OFL.txt",
    "MaruBuri-upstream-notice.md": "https://raw.githubusercontent.com/fonts-archive/MaruBuri/main/README.md",
    # The reviewed article text is vendored without the surrounding website scripts.
    "NAVER-font-OFL.txt": "https://help.naver.com/service/30016/contents/18088?osType=PC&lang=ko",
    "Adobe-CMap-BSD.txt": "https://raw.githubusercontent.com/adobe-type-tools/cmap-resources/master/LICENSE.md",
    "DocLayout-ONNX-model-card.md": "https://huggingface.co/wybxc/DocLayout-YOLO-DocStructBench-onnx/raw/main/README.md",
    "Apache-2.0.txt": "https://www.apache.org/licenses/LICENSE-2.0.txt",
    "DocLayout-YOLO-upstream-AGPL.txt": "https://raw.githubusercontent.com/opendatalab/DocLayout-YOLO/main/LICENSE",
}


def main():
    DESTINATION.mkdir(parents=True, exist_ok=True)
    records = []
    for filename, source in SOURCES.items():
        path = DESTINATION / filename
        if not path.is_file():
            if filename == "NAVER-font-OFL.txt":
                raise RuntimeError("Restore the reviewed NAVER article text from Git; do not save HTML as a license.")
            if urlsplit(source).scheme != "https":
                raise ValueError("License sources must use HTTPS")
            with urllib.request.urlopen(source, timeout=60) as response:  # noqa: S310 — HTTPS is enforced above.
                body = response.read()
            if len(body) < 80:
                raise RuntimeError(f"Unexpected license response: {filename}")
            path.write_bytes(body)
        records.append(
            {
                "file": filename,
                "url": source,
                "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
            }
        )
        print(filename, flush=True)
    (DESTINATION / "sources.json").write_text(json.dumps(records, indent=2) + "\n")


if __name__ == "__main__":
    main()
