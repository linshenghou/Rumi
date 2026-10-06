"""JSON-lines bridge for the native macOS app.

``--request-stdin`` reads one JSON request from stdin. The app keeps the pipe
open while a job runs and sends ``cancel\n`` to stop it. Credentials are accepted
only through that pipe. The legacy command-line translation interface remains
available for local development and existing integrations.
"""

from __future__ import annotations

import argparse
import asyncio
import ipaddress
import json
import logging
import multiprocessing
import os
import re
import signal
import sys
import tempfile
import threading
from contextlib import aclosing
from contextlib import suppress
from pathlib import Path
from urllib.parse import urlsplit

PROTOCOL_OUTPUT = sys.stdout
PROTOCOL_VERSION = 2
MAX_REQUEST_SIZE = 1024 * 1024
ERROR_MESSAGES = {
    "invalid_key": "API Key 无效或没有访问权限，请在翻译服务设置中更新。",
    "rate_limit": "服务请求过于频繁或额度不足，请稍后重试或检查服务账户。",
    "network": "无法连接翻译服务，请检查网络和服务地址后重试。",
    "configuration": "翻译服务配置无效，请检查服务地址、模型和 API Key。",
    "invalid_pdf": "无法翻译这份 PDF，请选择未加密、内容完整且包含可选择文字的 PDF。",
    "output_permission": "无法写入结果文件夹，请重新选择可写入的保存位置。",
    "engine": "翻译引擎或资源缺失、损坏，请重新安装应用。",
    "unexpected": "翻译未能完成，请重试或检查翻译服务与文档。",
}


class BridgeError(Exception):
    """A public error category; never carries provider response text."""

    def __init__(self, code: str):
        self.code = code
        super().__init__(ERROR_MESSAGES[code])


def emit(event: dict) -> None:
    PROTOCOL_OUTPUT.write(json.dumps(event, ensure_ascii=False) + "\n")
    PROTOCOL_OUTPUT.flush()


def error_event(error: object) -> dict:
    """Classify failures without returning raw exception/request details."""
    if isinstance(error, BridgeError):
        code = error.code
    else:
        status = getattr(error, "status_code", None) or getattr(
            getattr(error, "response", None), "status_code", None
        )
        # The engine serializes exceptions between processes. Examine this text
        # for classification only; never send it to the app or a log.
        detail = str(error).lower()
        name = type(error).__name__.lower()
        if status in (401, 403) or any(
            token in detail + name
            for token in (
                "authenticationerror",
                "permissiondeniederror",
                "invalid_api_key",
                "invalid api key",
                "incorrect api key",
                "error code: 401",
                "error code: 403",
            )
        ):
            code = "invalid_key"
        elif status in (402, 429) or any(
            token in detail + name
            for token in (
                "ratelimiterror",
                "rate limit",
                "insufficient_quota",
                "insufficient balance",
                "error code: 429",
                "error code: 402",
            )
        ):
            code = "rate_limit"
        elif status is not None and status >= 500:
            code = "network"
        elif isinstance(error, (ConnectionError, TimeoutError)) or any(
            token in detail + name
            for token in (
                "connectionerror",
                "connecterror",
                "connecttimeout",
                "readtimeout",
                "apitimeouterror",
                "connection error",
                "timed out",
                "networkerror",
                "network is unreachable",
                "certificate verify failed",
            )
        ):
            code = "network"
        elif isinstance(error, PermissionError):
            code = "output_permission"
        elif isinstance(error, (ImportError, ModuleNotFoundError)):
            code = "engine"
        elif any(
            token in detail + name
            for token in (
                "filedataerror",
                "emptyfileerror",
                "password",
                "encrypted pdf",
                "invalid pdf",
                "no pages",
                "scannedpdferror",
                "scanned pdf",
            )
        ):
            code = "invalid_pdf"
        elif isinstance(error, ValueError) or status in (400, 404, 422):
            code = "configuration"
        else:
            code = "unexpected"
    return {"type": "error", "code": code, "message": ERROR_MESSAGES[code]}


def _text(data: dict, key: str, default: str = "") -> str:
    value = data.get(key, default)
    if value is None:
        return default
    if not isinstance(value, str) or "\x00" in value:
        raise BridgeError("configuration")
    return value.strip()


def normalize_provider(value: object, *, require_key: bool = True) -> dict:
    if not isinstance(value, dict):
        raise BridgeError("configuration")
    kind = _text(value, "kind")
    if kind not in ("deepseek", "compatible"):
        raise BridgeError("configuration")
    model = _text(value, "model", "deepseek-flash" if kind == "deepseek" else "")
    key = _text(value, "api_key")
    base_url = _text(value, "base_url").rstrip("/")
    if kind == "deepseek":
        # Choosing DeepSeek always uses its own endpoint; custom servers belong
        # to the compatible provider and cannot silently receive this Key.
        base_url = "https://api.deepseek.com/v1"
    elif base_url.endswith("/chat/completions"):
        base_url = base_url.removesuffix("/chat/completions")
    try:
        url = urlsplit(base_url)
        hostname = url.hostname
        local = hostname == "localhost"
        if hostname:
            with suppress(ValueError):
                local = ipaddress.ip_address(hostname).is_loopback
        valid_scheme = url.scheme == "https" or (url.scheme == "http" and local)
        if (
            not valid_scheme
            or not hostname
            or url.username
            or url.password
            or url.query
            or url.fragment
        ):
            raise ValueError
        _ = url.port
    except ValueError:
        raise BridgeError("configuration") from None
    thinking = _text(value, "thinking_mode")
    reasoning = _text(value, "reasoning_effort")
    if not model or (require_key and not key) or any(c in key for c in "\r\n"):
        raise BridgeError("configuration")
    if thinking not in ("", "enabled", "disabled") or reasoning not in (
        "",
        "high",
        "max",
        "minimal",
        "low",
        "medium",
    ):
        raise BridgeError("configuration")
    if kind == "deepseek" and reasoning not in ("", "high", "max"):
        raise BridgeError("configuration")
    return {
        "kind": kind,
        "base_url": base_url,
        "model": model,
        "api_key": key,
        "thinking_mode": thinking,
        "reasoning_effort": reasoning,
    }


def provider_engine(provider: dict):
    from pdf2zh_next.config.translate_engine_model import DeepSeekSettings
    from pdf2zh_next.config.translate_engine_model import OpenAISettings

    if provider["kind"] == "deepseek":
        return DeepSeekSettings(
            deepseek_model=provider["model"],
            deepseek_api_key=provider["api_key"],
            deepseek_thinking_mode=provider["thinking_mode"] or None,
            deepseek_reasoning_effort=provider["reasoning_effort"] or None,
        )
    engine = OpenAISettings(
        openai_model=provider["model"],
        openai_api_key=provider["api_key"],
        openai_base_url=provider["base_url"],
        openai_timeout="120",
        openai_reasoning_effort=provider["reasoning_effort"] or None,
        openai_send_reasoning_effort=bool(provider["reasoning_effort"]),
    )
    if provider["thinking_mode"]:
        engine._openai_extra_body = {"thinking": {"type": provider["thinking_mode"]}}
    return engine


def request_settings(request: dict):
    """Construct settings from the request alone; no TOML/env precedence."""
    from pdf2zh_next.config.model import SettingsModel

    provider = normalize_provider(request.get("provider"))
    settings = SettingsModel(translate_engine_settings=provider_engine(provider))
    settings.gui_settings.disable_config_auto_save = True
    settings.translation.lang_in = _text(request, "source", "en") or "en"
    settings.translation.lang_out = _text(request, "target", "zh-CN") or "zh-CN"
    settings.translation.output = str(
        Path(_text(request, "output")).expanduser().resolve()
    )
    pages = _text(request, "pages")
    if pages:
        for part in pages.split(","):
            part = part.strip()
            if not re.fullmatch(
                r"(?:[1-9]\d*|[1-9]\d*-[1-9]\d*|[1-9]\d*-|-[1-9]\d*)", part
            ):
                raise BridgeError("configuration")
            if "-" in part:
                start, end = part.split("-")
                if start and end and int(start) > int(end):
                    raise BridgeError("configuration")
        pages = ",".join(part.strip() for part in pages.split(","))
    settings.pdf.pages = pages or None
    mode = _text(request, "mode", "both")
    if mode not in ("both", "mono", "dual"):
        raise BridgeError("configuration")
    settings.pdf.no_mono = mode == "dual"
    settings.pdf.no_dual = mode == "mono"
    settings.validate_settings()
    return settings, provider["kind"]


def load_settings(args):
    """Read CLI-compatible configuration without rewriting the user's files."""
    request = getattr(args, "request", None)
    if request is not None:
        return request_settings(request)
    from pdf2zh_next.config.cli_env_model import CLIEnvSettingsModel
    from pdf2zh_next.config.main import ConfigManager

    manager = ConfigManager()
    config_path = (
        Path(args.config).expanduser()
        if args.config
        else manager._default_config_file_path
    )
    if args.config and not config_path.is_file():
        raise BridgeError("configuration")
    config = manager._read_toml_file(config_path)
    merged = manager.merge_settings([manager.parse_env_vars(), config])
    settings = manager._build_model_from_args(
        CLIEnvSettingsModel, merged
    ).to_settings_model()
    settings.basic.input_files = set()
    settings.basic.debug = False
    settings.basic.gui = False
    settings.basic.warmup = False
    settings.basic.generate_offline_assets = None
    settings.basic.restore_offline_assets = None
    settings.basic.version = False
    if args.source:
        settings.translation.lang_in = args.source
    if args.target:
        settings.translation.lang_out = args.target
    if args.output:
        settings.translation.output = str(Path(args.output).expanduser().resolve())
    if args.pages is not None:
        settings.pdf.pages = args.pages or None
    if args.mode:
        settings.pdf.no_mono = args.mode == "dual"
        settings.pdf.no_dual = args.mode == "mono"
    service = settings.translate_engine_settings.translate_engine_type
    settings.validate_settings()
    return settings, service


def import_config(request: dict) -> dict:
    """Explicit one-shot migration; caller must store the returned Key securely."""
    from pdf2zh_next.config.cli_env_model import CLIEnvSettingsModel
    from pdf2zh_next.config.main import ConfigManager
    from pdf2zh_next.const import __config_file_version__

    manager = ConfigManager()
    value = _text(request, "config_path")
    # Frozen builds relocate their internal config/cache directories. Migration
    # still reads the existing command-line app's original default location.
    path = (
        Path(value).expanduser()
        if value
        else Path.home()
        / ".config"
        / "pdf2zh"
        / f"config.v{__config_file_version__}.toml"
    )
    if not path.is_file():
        raise BridgeError("configuration")
    config = manager._read_toml_file(path)
    settings = manager._build_model_from_args(
        CLIEnvSettingsModel, config
    ).to_settings_model()
    engine = settings.translate_engine_settings
    kind = engine.translate_engine_type
    if kind == "DeepSeek":
        provider = {
            "kind": "deepseek",
            "model": engine.deepseek_model,
            "api_key": engine.deepseek_api_key,
            "thinking_mode": engine.deepseek_thinking_mode,
            "reasoning_effort": engine.deepseek_reasoning_effort,
        }
    elif kind in ("OpenAI", "OpenAICompatible"):
        prefix = "openai" if kind == "OpenAI" else "openai_compatible"
        provider = {
            "kind": "compatible",
            "model": getattr(engine, prefix + "_model"),
            "api_key": getattr(engine, prefix + "_api_key"),
            "base_url": getattr(engine, prefix + "_base_url")
            or "https://api.openai.com/v1",
            "reasoning_effort": getattr(engine, prefix + "_reasoning_effort")
            if getattr(engine, prefix + "_send_reasoning_effort")
            else "",
        }
    else:
        raise BridgeError("configuration")
    return {
        "type": "imported_config",
        "provider": normalize_provider(provider, require_key=False),
    }


def normalize_event(event: dict) -> dict:
    """Expose only the stable, JSON-serializable portion of BabelDOC events."""
    kind = event.get("type", "")
    if kind == "finish":
        result = event["translate_result"]
        outputs = {}
        for key in (
            "mono_pdf_path",
            "dual_pdf_path",
            "no_watermark_mono_pdf_path",
            "no_watermark_dual_pdf_path",
            "auto_extracted_glossary_path",
        ):
            value = getattr(result, key, None)
            if value is not None and Path(value).is_file():
                outputs[key] = str(Path(value).resolve())
        if not any(key.endswith("pdf_path") for key in outputs):
            raise RuntimeError("Translation did not create a PDF")
        return {"type": "finish", "outputs": outputs}
    if kind == "error":
        return error_event(event.get("error", ""))
    return {
        key: event[key]
        for key in ("type", "stage", "overall_progress", "part_index", "total_parts")
        if key in event
    }


def runtime_check() -> dict:
    # Imports validate the native libraries and translation entry point without
    # requiring an account or making network requests.
    import pymupdf  # noqa: F401

    from pdf2zh_next.high_level import do_translate_async_stream  # noqa: F401

    return {"type": "ready", "protocol_version": PROTOCOL_VERSION}


async def test_connection(request: dict) -> int:
    import httpx

    provider = normalize_provider(request.get("provider"))
    engine = provider_engine(provider)
    engine.validate_settings()
    if hasattr(engine, "transform"):
        engine = engine.transform()
    body = {
        "model": provider["model"],
        "messages": [{"role": "user", "content": "Reply only: OK."}],
        "max_tokens": 32,
    }
    if engine._openai_extra_body:
        body.update(engine._openai_extra_body)
    if engine.openai_send_reasoning_effort:
        body["reasoning_effort"] = engine.openai_reasoning_effort
    async with httpx.AsyncClient(
        timeout=30, trust_env=False, follow_redirects=False
    ) as client:
        response = await client.post(
            provider["base_url"] + "/chat/completions",
            headers={"Authorization": "Bearer " + provider["api_key"]},
            json=body,
        )
        response.raise_for_status()
        try:
            choices = response.json()["choices"]
            if not choices or not isinstance(choices[0]["message"], dict):
                raise ValueError
        except (ValueError, KeyError, IndexError, TypeError):
            raise BridgeError("configuration") from None
    emit(
        {
            "type": "connection_ok",
            "service": provider["kind"],
            "model": provider["model"],
        }
    )
    return 0


def _validate_pdf(file: Path, pages: str | None) -> None:
    import pymupdf

    try:
        with pymupdf.open(file) as document:
            if not document.is_pdf or document.needs_pass or document.page_count == 0:
                raise BridgeError("invalid_pdf")
            if pages:
                # Reject ranges entirely outside the paper before an API call.
                starts = [int(part.split("-")[0] or "1") for part in pages.split(",")]
                if any(start > document.page_count for start in starts):
                    raise BridgeError("configuration")
    except BridgeError:
        raise
    except Exception:
        raise BridgeError("invalid_pdf") from None


def _check_output(output: str) -> None:
    try:
        folder = Path(output)
        folder.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryFile(dir=folder):
            pass
    except OSError:
        raise BridgeError("output_permission") from None


def _cleanup_children(previous: set[int]) -> None:
    """Do not report completion/cancellation while an owned worker survives."""
    for child in multiprocessing.active_children():
        if child.pid in previous:
            continue
        child.join(timeout=2)
        if child.is_alive():
            child.terminate()
            child.join(timeout=1)
        if child.is_alive():
            child.kill()
            child.join(timeout=1)


async def translate(args) -> int:
    from babeldoc.assets.assets import async_warmup

    from pdf2zh_next.high_level import do_translate_async_stream

    file = Path(args.input).expanduser().resolve()
    if not file.is_file() or file.suffix.lower() != ".pdf":
        raise BridgeError("invalid_pdf")
    settings, _ = load_settings(args)
    if getattr(args, "request", None) is not None:
        _validate_pdf(file, settings.pdf.pages)
        _check_output(settings.translation.output)
    emit(
        {"type": "progress_start", "stage": "准备字体与版面模型", "overall_progress": 0}
    )
    previous = {child.pid for child in multiprocessing.active_children()}
    final_event = None
    try:
        await async_warmup()
        async with aclosing(do_translate_async_stream(settings, file)) as events:
            async for event in events:
                normalized = normalize_event(event)
                if normalized["type"] in ("error", "finish"):
                    final_event = normalized
                    break
                emit(normalized)
    finally:
        # Give nested async generators an opportunity to execute their cleanup
        # before the final worker guard. This also covers interrupted warmup.
        await asyncio.sleep(0)
        await asyncio.to_thread(_cleanup_children, previous)
    if final_event is None:
        raise RuntimeError("Translation ended without a PDF result")
    emit(final_event)
    return 0 if final_event["type"] == "finish" else 1


async def run(args) -> int:
    request = getattr(args, "request", None)
    operation = request["operation"] if request is not None else "translate"
    task = asyncio.create_task(
        test_connection(request) if operation == "test_connection" else translate(args)
    )
    loop = asyncio.get_running_loop()
    cancellation_requested = False

    def cancel_once():
        nonlocal cancellation_requested
        if not cancellation_requested and not task.done():
            cancellation_requested = True
            task.cancel()

    def read_commands():
        try:
            for line in sys.stdin:
                if line.strip() == "cancel":
                    loop.call_soon_threadsafe(cancel_once)
                    return
            # In the GUI protocol EOF means the owner has exited. Preserve the
            # legacy CLI's ability to run with redirected/closed stdin.
            if request is not None:
                loop.call_soon_threadsafe(cancel_once)
        except (OSError, RuntimeError):
            pass

    threading.Thread(target=read_commands, daemon=True).start()
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, cancel_once)
    try:
        return await task
    except asyncio.CancelledError:
        emit({"type": "cancelled"})
        return 2
    finally:
        for sig in (signal.SIGTERM, signal.SIGINT):
            loop.remove_signal_handler(sig)


def read_request() -> dict:
    line = sys.stdin.readline(MAX_REQUEST_SIZE + 1)
    if not line or len(line) > MAX_REQUEST_SIZE:
        raise BridgeError("configuration")
    try:
        request = json.loads(line)
    except (ValueError, TypeError):
        raise BridgeError("configuration") from None
    if not isinstance(request, dict) or request.get("operation") not in (
        "check",
        "translate",
        "test_connection",
        "import_config",
    ):
        raise BridgeError("configuration")
    return request


def silence_library_diagnostics() -> None:
    """Keep third-party output out of protocol and credential-bearing logs."""
    diagnostics = Path(os.devnull).open("w")
    sys.stdout = diagnostics
    sys.stderr = diagnostics
    logging.basicConfig(handlers=[logging.NullHandler()], force=True)
    logging.disable(logging.CRITICAL)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--request-stdin", action="store_true")
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--config")
    parser.add_argument("--input")
    parser.add_argument("--output")
    parser.add_argument("--source")
    parser.add_argument("--target")
    parser.add_argument("--pages")
    parser.add_argument("--mode", choices=("both", "mono", "dual"))
    args = parser.parse_args()
    if args.request_stdin and hasattr(os, "setsid"):
        # Give the native owner's final cancellation deadline an isolated group
        # to terminate, including workers that inherit the protocol pipe. The
        # owner must verify getpgid(helper_pid) == helper_pid before signalling
        # the group; legacy terminal invocations keep their foreground group.
        with suppress(OSError):
            if os.getpgrp() != os.getpid():
                os.setsid()
    # Third-party exceptions/loggers can echo headers and document text. Only
    # our stable protocol is public. Workers' queued records are discarded too.
    silence_library_diagnostics()
    try:
        if args.request_stdin:
            args.request = read_request()
            operation = args.request["operation"]
            if operation == "import_config":
                emit(import_config(args.request))
                return 0
            if operation == "check":
                emit(runtime_check())
                return 0
            if operation == "translate":
                args.input = _text(args.request, "input")
                args.output = _text(args.request, "output")
                if not args.input or not args.output:
                    raise BridgeError("configuration")
        elif args.check:
            emit(runtime_check())
            return 0
        elif not args.input or not args.output:
            raise BridgeError("configuration")
        return asyncio.run(run(args))
    except Exception as error:
        emit(error_event(error))
    return 1


if __name__ == "__mp_main__":
    # spawn imports the development CLI entry before unpickling the settings.
    # Frozen workers receive the same protection in their bootstrap hook.
    silence_library_diagnostics()
elif __name__ == "__main__":
    multiprocessing.freeze_support()
    sys.exit(main())
