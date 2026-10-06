"""Run in every frozen process, before package imports and spawn dispatch."""

import os
import sys
from pathlib import Path

# This override is for isolated integration tests; the app uses the macOS location.
cache = Path(
    os.environ.get(
        "PDFTRANSLATE_CACHE_DIR",
        str(Path.home() / "Library" / "Caches" / "PDFTranslate" / "Engine"),
    )
)
os.environ["PDFTRANSLATE_CACHE_DIR"] = str(cache)
os.environ["PDFTRANSLATE_CONFIG_DIR"] = str(cache / "configuration")
os.environ["TIKTOKEN_CACHE_DIR"] = str(cache / "babeldoc" / "tiktoken")
os.environ["HF_HUB_OFFLINE"] = "1"
os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"
os.environ["PYTHONNOUSERSITE"] = "1"

# Spawn workers inherit the JSON protocol pipe but must never write to it.
if "--multiprocessing-fork" in sys.argv or any(
    "multiprocessing.resource_tracker" in arg for arg in sys.argv
):
    sink = os.open(os.devnull, os.O_WRONLY)
    os.dup2(sink, 1)
    os.dup2(sink, 2)
    os.close(sink)
