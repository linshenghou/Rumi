# Reproducible arm64 helper. Run through macos/scripts/build_engine.py.
from pathlib import Path
import os
from PyInstaller.utils.hooks import collect_data_files, collect_dynamic_libs, collect_submodules, copy_metadata

root = Path(SPECPATH).parent.parent
stage = Path(os.environ["PDFTRANSLATE_ENGINE_STAGE"])
data = [(str(stage / "assets"), "assets")]
for package in ("babeldoc", "certifi", "pymupdf", "tiktoken"):
    data += collect_data_files(package)
for distribution in ("babeldoc", "openai", "pydantic", "pymupdf", "tiktoken"):
    data += copy_metadata(distribution)

a = Analysis(
    [str(Path(SPECPATH) / "engine_entry.py")],
    pathex=[str(stage / "source")],
    binaries=collect_dynamic_libs("onnxruntime") + collect_dynamic_libs("rtree"),
    datas=data,
    hiddenimports=["pdf2zh_next.translator.translator_impl.openai", "tiktoken_ext.openai_public"] + collect_submodules("bitstring"),
    hookspath=[],
    runtime_hooks=[str(Path(SPECPATH) / "runtime_hook.py")],
    excludes=["gradio", "gradio_pdf", "gradio_i18n", "tkinter", "matplotlib", "pandas", "pytest", "IPython", "notebook", "torch", "tensorflow", "pdf2zh_next.gui"],
    noarchive=False,
)
pyz = PYZ(a.pure)
exe = EXE(
    pyz, a.scripts, [], exclude_binaries=True, name="pdftranslate-engine",
    debug=False, bootloader_ignore_signals=False, strip=False, upx=False,
    console=True, target_arch="arm64", codesign_identity=None, entitlements_file=None,
)
coll = COLLECT(exe, a.binaries, a.datas, strip=False, upx=False, name="pdftranslate-engine")
