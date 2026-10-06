import argparse
import asyncio
import json
from types import SimpleNamespace

import pytest
from pdf2zh_next import desktop_bridge as bridge


def options(**kwargs):
    defaults = {
        "config": None,
        "source": None,
        "target": None,
        "output": None,
        "pages": None,
        "mode": None,
    }
    return argparse.Namespace(**(defaults | kwargs))


def test_settings_reuse_service_without_rewriting_config(tmp_path, monkeypatch):
    from pdf2zh_next.config.main import ConfigManager

    config = tmp_path / "config.toml"
    content = 'bing = true\n[translation]\nlang_in = "de"\nlang_out = "en"\n[pdf]\nwatermark_output_mode = "no_watermark"\n'
    config.write_text(content)
    monkeypatch.setattr(ConfigManager, "parse_env_vars", lambda _self: {})
    settings, service = bridge.load_settings(
        options(
            config=str(config),
            source="en",
            target="zh-CN",
            output=str(tmp_path),
            pages="1-3",
            mode="mono",
        )
    )
    assert service == "Bing"
    assert settings.translation.lang_out == "zh-CN"
    assert settings.pdf.pages == "1-3"
    assert settings.pdf.no_dual and not settings.pdf.no_mono
    assert settings.pdf.watermark_output_mode == "no_watermark"
    assert config.read_text() == content


def test_finish_includes_only_existing_outputs(tmp_path):
    mono = tmp_path / "中文译文.pdf"
    mono.write_bytes(b"%PDF-test")
    result = SimpleNamespace(mono_pdf_path=mono, dual_pdf_path=tmp_path / "missing.pdf")
    event = bridge.normalize_event({"type": "finish", "translate_result": result})
    assert event == {"type": "finish", "outputs": {"mono_pdf_path": str(mono)}}
    json.dumps(event)


def test_missing_result_is_not_reported_as_success():
    with pytest.raises(RuntimeError):
        bridge.normalize_event(
            {"type": "finish", "translate_result": SimpleNamespace()}
        )


def test_engine_errors_do_not_expose_credentials():
    event = bridge.normalize_event(
        {"type": "error", "error": "request failed api_key=secret", "details": "secret"}
    )
    assert "secret" not in json.dumps(event)


def test_translation_stream_closes_and_returns_real_result(tmp_path, monkeypatch):
    import babeldoc.assets.assets
    import pdf2zh_next.high_level

    source = tmp_path / "input.pdf"
    source.write_bytes(b"%PDF-test")
    output = tmp_path / "output.pdf"
    output.write_bytes(b"%PDF-result")
    events = []
    closed = []

    async def stream(_settings, file):
        assert file == source
        try:
            yield {
                "type": "progress_update",
                "stage": "Translate Paragraphs",
                "overall_progress": 50,
            }
            yield {
                "type": "finish",
                "translate_result": SimpleNamespace(mono_pdf_path=output),
            }
        finally:
            closed.append(True)

    monkeypatch.setattr(bridge, "load_settings", lambda _args: (object(), "Bing"))
    monkeypatch.setattr(bridge, "emit", events.append)

    async def warmup():
        pass

    monkeypatch.setattr(babeldoc.assets.assets, "async_warmup", warmup)
    monkeypatch.setattr(pdf2zh_next.high_level, "do_translate_async_stream", stream)
    assert (
        asyncio.run(bridge.translate(options(input=str(source), output=str(tmp_path))))
        == 0
    )
    assert events[-1]["outputs"]["mono_pdf_path"] == str(output)
    assert closed == [True]


def test_cancelled_translation_closes_stream(tmp_path, monkeypatch):
    import babeldoc.assets.assets
    import pdf2zh_next.high_level

    source = tmp_path / "input.pdf"
    source.write_bytes(b"%PDF-test")
    started = asyncio.Event()
    closed = []

    async def stream(_settings, _file):
        try:
            started.set()
            await asyncio.sleep(60)
            yield {}
        finally:
            closed.append(True)

    monkeypatch.setattr(bridge, "load_settings", lambda _args: (object(), "Bing"))
    monkeypatch.setattr(bridge, "emit", lambda _event: None)

    async def warmup():
        pass

    monkeypatch.setattr(babeldoc.assets.assets, "async_warmup", warmup)
    monkeypatch.setattr(pdf2zh_next.high_level, "do_translate_async_stream", stream)

    async def cancel():
        task = asyncio.create_task(
            bridge.translate(options(input=str(source), output=str(tmp_path)))
        )
        await started.wait()
        task.cancel()
        with pytest.raises(asyncio.CancelledError):
            await task

    asyncio.run(cancel())
    assert closed == [True]


def request(**updates):
    return {
        "operation": "translate",
        "input": "/example/input.pdf",
        "output": "/example/output",
        "source": "en",
        "target": "zh-CN",
        "mode": "both",
        "provider": {
            "kind": "deepseek",
            "model": "deepseek-v4-flash",
            "api_key": "private-key",
            "thinking_mode": "enabled",
            "reasoning_effort": "high",
        },
    } | updates


def test_request_settings_ignore_ambient_config_and_environment(monkeypatch):
    from pdf2zh_next.config.main import ConfigManager

    def forbidden(*_args):
        pytest.fail("Request settings must not load environment or TOML")

    monkeypatch.setattr(ConfigManager, "parse_env_vars", forbidden)
    monkeypatch.setattr(ConfigManager, "_read_toml_file", forbidden)
    monkeypatch.setenv("PDF2ZH_DEEPSEEK_API_KEY", "ambient-secret")
    monkeypatch.setenv("OPENAI_API_KEY", "ambient-secret")
    settings, service = bridge.load_settings(options(request=request()))
    engine = settings.translate_engine_settings
    assert service == "deepseek"
    assert engine.openai_api_key == "private-key"
    assert engine.openai_base_url == "https://api.deepseek.com/v1"
    assert engine._openai_extra_body == {"thinking": {"type": "enabled"}}
    assert engine.openai_reasoning_effort == "high"
    assert settings.pdf.watermark_output_mode == "watermarked"
    assert settings.gui_settings.disable_config_auto_save


@pytest.mark.parametrize(
    "address",
    [
        "http://example.com/v1",
        "ftp://example.com",
        "https://key:secret@example.com",
        "https://example.com?key=secret",
        "https://example.com/#fragment",
        "https://example.com:invalid",
        "https://",
        "http://localhost.evil.com/v1",
    ],
)
def test_custom_api_rejects_insecure_or_credential_urls(address):
    with pytest.raises(bridge.BridgeError) as failure:
        bridge.normalize_provider(
            {
                "kind": "compatible",
                "base_url": address,
                "model": "test",
                "api_key": "secret",
            }
        )
    assert failure.value.code == "configuration"
    assert "secret" not in json.dumps(bridge.error_event(failure.value))


@pytest.mark.parametrize(
    "address",
    [
        "https://example.com/v1",
        "http://localhost:11434/v1",
        "http://127.0.0.1:8888/v1",
        "http://[::1]:8888/v1",
    ],
)
def test_custom_api_accepts_https_and_loopback(address):
    provider = bridge.normalize_provider(
        {
            "kind": "compatible",
            "base_url": address + "/chat/completions/",
            "model": "test",
            "api_key": "secret",
        }
    )
    assert provider["base_url"] == address


@pytest.mark.parametrize("pages", ["0", "5-2", "1,,3", "-", "1;2", "1-a"])
def test_request_rejects_invalid_page_ranges(pages):
    with pytest.raises(bridge.BridgeError):
        bridge.request_settings(request(pages=pages))


def test_compatible_settings_preserve_imported_reasoning():
    settings, _ = bridge.request_settings(
        request(
            provider={
                "kind": "compatible",
                "base_url": "https://example.com/v1",
                "model": "reasoner",
                "api_key": "secret",
                "reasoning_effort": "medium",
            }
        )
    )
    assert settings.translate_engine_settings.openai_reasoning_effort == "medium"
    assert settings.translate_engine_settings.openai_send_reasoning_effort


@pytest.mark.parametrize(
    "kind,prefix",
    [
        ("deepseek", "deepseek"),
        ("openai", "openai"),
        ("openaicompatible", "openai_compatible"),
    ],
)
def test_explicit_config_import_does_not_load_env_or_rewrite_file(
    tmp_path, monkeypatch, kind, prefix
):
    from pdf2zh_next.config.main import ConfigManager

    path = tmp_path / "旧配置.toml"
    content = f'{kind} = true\n[{kind}_detail]\n{prefix}_model = "test-model"\n{prefix}_api_key = "old-key"\n'
    if kind == "deepseek":
        content += (
            'deepseek_thinking_mode = "enabled"\ndeepseek_reasoning_effort = "max"\n'
        )
    else:
        content += f'{prefix}_base_url = "https://example.com/v1"\n{prefix}_reasoning_effort = "medium"\n{prefix}_send_reasoning_effort = true\n'
    path.write_text(content)

    def forbidden(*_args):
        pytest.fail("Explicit config import must not read environment")

    monkeypatch.setattr(ConfigManager, "parse_env_vars", forbidden)
    result = bridge.import_config({"config_path": str(path)})
    provider = result["provider"]
    assert result["type"] == "imported_config"
    assert provider["api_key"] == "old-key"
    assert provider["kind"] == ("deepseek" if kind == "deepseek" else "compatible")
    assert provider["reasoning_effort"] == ("max" if kind == "deepseek" else "medium")
    if kind == "deepseek":
        assert provider["thinking_mode"] == "enabled"
    assert path.read_text() == content


def test_import_missing_or_unsupported_config_fails(tmp_path):
    with pytest.raises(bridge.BridgeError):
        bridge.import_config({"config_path": str(tmp_path / "missing.toml")})
    config = tmp_path / "bing.toml"
    config.write_text("bing = true\n")
    with pytest.raises(bridge.BridgeError):
        bridge.import_config({"config_path": str(config)})


@pytest.mark.parametrize(
    "status,code",
    [
        (401, "invalid_key"),
        (403, "invalid_key"),
        (429, "rate_limit"),
        (402, "rate_limit"),
        (503, "network"),
        (404, "configuration"),
    ],
)
def test_http_errors_are_actionable_without_response_secrets(status, code):
    import httpx

    response = httpx.Response(
        status, request=httpx.Request("POST", "https://example.com"), text="private-key"
    )
    error = httpx.HTTPStatusError(
        "private-key", request=response.request, response=response
    )
    event = bridge.error_event(error)
    assert event["code"] == code
    assert "private-key" not in json.dumps(event)


def test_wrapped_engine_error_classifies_without_leaking_key():
    event = bridge.normalize_event(
        {
            "type": "error",
            "error": "AuthenticationError: Error code: 401 - invalid_api_key private-key",
        }
    )
    assert event["code"] == "invalid_key"
    assert "private-key" not in json.dumps(event)


def test_connection_sends_minimal_request_and_never_echoes_key(monkeypatch):
    import httpx

    events = []
    captured = []
    original_client = httpx.AsyncClient

    def handler(req):
        captured.append(req)
        return httpx.Response(200, json={"choices": [{"message": {"content": "OK"}}]})

    def make_client(**kwargs):
        assert kwargs["trust_env"] is False
        assert kwargs["follow_redirects"] is False
        return original_client(transport=httpx.MockTransport(handler), **kwargs)

    monkeypatch.setattr(httpx, "AsyncClient", make_client)
    monkeypatch.setattr(bridge, "emit", events.append)
    assert (
        asyncio.run(bridge.test_connection(request(operation="test_connection"))) == 0
    )
    assert captured[0].headers["Authorization"] == "Bearer private-key"
    body = json.loads(captured[0].content)
    assert body["thinking"] == {"type": "enabled"}
    assert body["reasoning_effort"] == "high"
    assert body["max_tokens"] == 32
    assert len(body["messages"]) == 1
    assert events[0]["type"] == "connection_ok"
    assert "private-key" not in json.dumps(events)


def test_connection_rejects_html_success_page(monkeypatch):
    import httpx

    original_client = httpx.AsyncClient
    monkeypatch.setattr(
        httpx,
        "AsyncClient",
        lambda **kwargs: original_client(
            transport=httpx.MockTransport(
                lambda _req: httpx.Response(200, text="<html>login</html>")
            ),
            **kwargs,
        ),
    )
    with pytest.raises(bridge.BridgeError) as failure:
        asyncio.run(bridge.test_connection(request(operation="test_connection")))
    assert failure.value.code == "configuration"


def test_invalid_pdf_is_rejected_before_translation(tmp_path):
    path = tmp_path / "fake.pdf"
    path.write_text("not a PDF")
    with pytest.raises(bridge.BridgeError) as failure:
        bridge._validate_pdf(path, None)
    assert failure.value.code == "invalid_pdf"


def test_pdf_page_range_and_password_are_validated(tmp_path):
    import pymupdf

    path = tmp_path / "valid.pdf"
    with pymupdf.open() as document:
        document.new_page()
        document.save(path)
    bridge._validate_pdf(path, "1")
    with pytest.raises(bridge.BridgeError) as failure:
        bridge._validate_pdf(path, "2-")
    assert failure.value.code == "configuration"
    encrypted = tmp_path / "encrypted.pdf"
    with pymupdf.open(path) as document:
        document.save(
            encrypted,
            encryption=pymupdf.PDF_ENCRYPT_AES_256,
            owner_pw="owner",
            user_pw="secret",
        )
    with pytest.raises(bridge.BridgeError) as failure:
        bridge._validate_pdf(encrypted, None)
    assert failure.value.code == "invalid_pdf"


def test_output_permission_classification(tmp_path):
    file = tmp_path / "file"
    file.write_text("occupied")
    with pytest.raises(bridge.BridgeError) as failure:
        bridge._check_output(str(file / "cannot-be-a-directory"))
    assert failure.value.code == "output_permission"


@pytest.mark.parametrize(
    "stdin", ["", "null\n", "[]\n", '{"operation":"not-supported"}\n', '{"operation": ']
)
def test_protocol_rejects_invalid_requests(monkeypatch, stdin):
    import io

    monkeypatch.setattr(bridge.sys, "stdin", io.StringIO(stdin))
    with pytest.raises(bridge.BridgeError):
        bridge.read_request()


def test_protocol_reads_exactly_one_line(monkeypatch):
    import io

    stdin = io.StringIO(json.dumps(request()) + "\ncancel\n")
    monkeypatch.setattr(bridge.sys, "stdin", stdin)
    assert bridge.read_request()["operation"] == "translate"
    assert stdin.readline() == "cancel\n"


@pytest.mark.parametrize("command", ["cancel\n", ""])
def test_request_cancel_and_parent_eof_wait_for_cleanup(monkeypatch, command):
    import io

    events = []
    cleaned = []

    async def slow_translation(_args):
        try:
            await asyncio.sleep(30)
        finally:
            await asyncio.sleep(0)
            cleaned.append(True)

    def record(event):
        assert cleaned == [True]
        events.append(event)

    monkeypatch.setattr(bridge, "translate", slow_translation)
    monkeypatch.setattr(bridge, "emit", record)
    monkeypatch.setattr(bridge.sys, "stdin", io.StringIO(command))
    assert asyncio.run(bridge.run(options(request=request()))) == 2
    assert events == [{"type": "cancelled"}]


def test_legacy_cli_does_not_cancel_on_stdin_eof(monkeypatch):
    import io

    async def done(_args):
        await asyncio.sleep(0.01)
        return 0

    monkeypatch.setattr(bridge, "translate", done)
    monkeypatch.setattr(bridge.sys, "stdin", io.StringIO(""))
    assert asyncio.run(bridge.run(options())) == 0


def test_runtime_check_is_independent_of_api_config(monkeypatch):
    from pdf2zh_next.config.main import ConfigManager

    def forbidden(*_args):
        pytest.fail("Runtime check must not access API config")

    monkeypatch.setattr(bridge, "load_settings", forbidden)
    monkeypatch.setattr(ConfigManager, "parse_env_vars", forbidden)
    monkeypatch.setattr(ConfigManager, "_read_toml_file", forbidden)
    assert bridge.runtime_check() == {"type": "ready", "protocol_version": 2}


def test_default_import_uses_legacy_location_even_in_frozen_app(tmp_path, monkeypatch):
    from pathlib import Path

    from pdf2zh_next.config.main import ConfigManager
    from pdf2zh_next.const import __config_file_version__

    config = tmp_path / ".config" / "pdf2zh" / f"config.v{__config_file_version__}.toml"
    config.parent.mkdir(parents=True)
    config.write_text(
        'deepseek = true\n[deepseek_detail]\ndeepseek_api_key = "legacy-key"\n'
    )
    monkeypatch.setattr(Path, "home", lambda: tmp_path)
    monkeypatch.setattr(
        ConfigManager, "_default_config_file_path", tmp_path / "frozen-config.toml"
    )
    event = bridge.import_config({"config_path": ""})
    assert event["provider"]["api_key"] == "legacy-key"


def test_default_deepseek_model_preserves_explicit_thinking_choice():
    provider = {
        "kind": "deepseek",
        "api_key": "fixture-key",
        "thinking_mode": "disabled",
    }
    settings, _ = bridge.request_settings(request(provider=provider))
    assert settings.translate_engine_settings.openai_model == "deepseek-flash"
    assert settings.translate_engine_settings._openai_extra_body == {
        "thinking": {"type": "disabled"}
    }
    explicit = provider | {"model": "deepseek-v4-flash"}
    settings, _ = bridge.request_settings(request(provider=explicit))
    assert settings.translate_engine_settings.openai_model == "deepseek-v4-flash"
