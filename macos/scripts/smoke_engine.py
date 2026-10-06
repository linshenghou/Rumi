#!/usr/bin/env python3
"""No-billing integration smoke: frozen worker + local API + actual PDF layout."""

import argparse
import json
import subprocess
import threading
from http.server import BaseHTTPRequestHandler
from http.server import ThreadingHTTPServer
from pathlib import Path


class FixtureAPI(BaseHTTPRequestHandler):
    calls = 0

    def log_message(self, *_args):
        pass

    def do_POST(self):
        payload = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        FixtureAPI.calls += 1
        messages = payload.get("messages", [])
        prompt = "\n".join(str(message.get("content", "")) for message in messages)
        reply = "测试译文：Hello world."
        if "expert multilingual terminologist" in prompt:
            reply = "[]"
        elif "## Here is the input:" in prompt:
            items = json.loads(prompt.rsplit("## Here is the input:", 1)[1].strip())
            reply = json.dumps(
                [
                    {"id": item["id"], "output": "测试译文：" + item["input"]}
                    for item in items
                ],
                ensure_ascii=False,
            )
        result = {
            "id": "fixture",
            "object": "chat.completion",
            "created": 0,
            "model": "fixture-translation",
            "choices": [
                {
                    "index": 0,
                    "finish_reason": "stop",
                    "message": {"role": "assistant", "content": reply},
                }
            ],
            "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2},
        }
        body = json.dumps(result).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def main():
    import pymupdf

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("engine", type=Path)
    parser.add_argument("--work", type=Path, required=True)
    parser.add_argument(
        "--timeout",
        type=float,
        default=600,
        help="Allow first-run macOS signature validation before translation",
    )
    args = parser.parse_args()
    work = args.work.absolute()
    work.mkdir(parents=True, exist_ok=True)
    source = work / "Source paper.pdf"
    document = pymupdf.open()
    page = document.new_page()
    page.insert_text((72, 72), "A small research paper", fontsize=20)
    page.insert_textbox(
        pymupdf.Rect(72, 110, 510, 370),
        "This experiment evaluates a local document translation pipeline. "
        "The generated file should preserve paragraphs and page structure while including Chinese text. "
        "This artificial fixture contains no personal information and uses no external translation service.\n\n"
        "The second paragraph checks that multiple text blocks survive analysis and typesetting. "
        "Results are inspected after the isolated worker exits normally.",
        fontsize=12,
    )
    document.save(source)
    document.close()
    server = ThreadingHTTPServer(("127.0.0.1", 0), FixtureAPI)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    environment = {
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "LANG": "en_US.UTF-8",
        "PDFTRANSLATE_CACHE_DIR": str(work / "clean-cache"),
    }
    request = {
        "operation": "translate",
        "input": str(source),
        "output": str(work / "output"),
        "source": "en",
        "target": "zh-CN",
        "pages": "1",
        "mode": "both",
        "provider": {
            "kind": "compatible",
            "base_url": f"http://127.0.0.1:{server.server_port}/v1",
            "model": "fixture-translation",
            "api_key": "fixture-key",
            "thinking_mode": "",
            "reasoning_effort": "",
        },
    }
    process = subprocess.Popen(
        [str(args.engine.absolute()), "--request-stdin"],
        cwd=work,
        env=environment,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    watchdog = threading.Timer(args.timeout, process.kill)
    watchdog.start()
    events = []
    try:
        process.stdin.write(json.dumps(request) + "\n")
        process.stdin.flush()
        for line in process.stdout:
            events.append(json.loads(line))
        returncode = process.wait()
        diagnostics = process.stderr.read()
    finally:
        watchdog.cancel()
        if process.poll() is None:
            process.kill()
            process.wait()
        server.shutdown()
        server.server_close()
    if returncode != 0:
        raise RuntimeError(
            f"Frozen translation failed ({returncode}): {events[-3:]}; diagnostics: {diagnostics[:1000]}"
        )
    finished = [event for event in events if event.get("type") == "finish"]
    assert finished and FixtureAPI.calls > 0, (
        "Frozen worker must invoke the local API and finish"
    )
    outputs = finished[-1]["outputs"]
    pdfs = [Path(path) for name, path in outputs.items() if name.endswith("pdf_path")]
    assert len(pdfs) >= 2, "Both translated and bilingual PDF outputs are required"
    for path in pdfs:
        with pymupdf.open(path) as pdf:
            assert pdf.page_count >= 1
            assert "测试译文" in "".join(page.get_text() for page in pdf), (
                f"Missing CJK text in {path.name}"
            )
    assert not diagnostics.strip(), "Frozen worker leaked raw diagnostics"
    print(
        json.dumps(
            {
                "result": "passed",
                "api_calls": FixtureAPI.calls,
                "events": len(events),
                "pdf_outputs": len(pdfs),
                "billing": "none",
            }
        )
    )


if __name__ == "__main__":
    main()
