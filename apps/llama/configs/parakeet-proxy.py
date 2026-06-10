#!/usr/bin/env python3
"""
Thin reverse proxy for parakeet-server.

Accepts POST /v1/audio/transcriptions with any audio format,
converts the audio to 16 kHz mono WAV via ffmpeg, then forwards
the converted file to the real parakeet-server running on PARAKEET_PORT.

Also proxies GET /health straight through.

Usage:
    PROXY_PORT=<port>  PARAKEET_PORT=<upstream>  python3 parakeet-proxy.py
"""

import http.server
import io
import os
import subprocess
import sys
import tempfile
import urllib.request
import urllib.error

PROXY_PORT    = int(os.environ.get("PROXY_PORT", "8080"))
PARAKEET_PORT = PROXY_PORT + 1
FFMPEG        = os.environ.get("FFMPEG_BIN", "ffmpeg")
MODEL         = os.environ.get("PARAKEET_MODEL", "tdt_ctc-1.1b-q4_k.gguf")
CACHE_DIR     = os.environ.get("PARAKEET_CACHE_DIR", "/root/.cache/parakeet.cpp/models")


def convert_to_wav(data: bytes) -> bytes:
    """Convert any audio bytes to 16 kHz mono PCM WAV via ffmpeg."""
    with tempfile.NamedTemporaryFile(suffix=".input", delete=False) as inf:
        inf.write(data)
        inf_path = inf.name
    out_path = inf_path + ".wav"
    try:
        subprocess.run(
            [
                FFMPEG, "-y",
                "-i", inf_path,
                "-ar", "16000",
                "-ac", "1",
                "-f", "wav",
                out_path,
            ],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        with open(out_path, "rb") as f:
            return f.read()
    finally:
        os.unlink(inf_path)
        if os.path.exists(out_path):
            os.unlink(out_path)


def parse_multipart(content_type: str, body: bytes):
    """
    Parse a multipart/form-data body.
    Returns a dict of field_name -> (filename_or_None, content_type, data).
    """
    import email
    from email import policy as email_policy

    # email.parser needs the full MIME headers to parse multipart
    raw = b"Content-Type: " + content_type.encode() + b"\r\n\r\n" + body
    msg = email.message_from_bytes(raw, policy=email_policy.compat32)
    parts = {}
    for part in msg.get_payload():
        cd = part.get("Content-Disposition", "")
        name = None
        filename = None
        for item in cd.split(";"):
            item = item.strip()
            if item.startswith('name='):
                name = item[5:].strip('"')
            elif item.startswith('filename='):
                filename = item[9:].strip('"')
        if name is not None:
            parts[name] = (filename, part.get_content_type(), part.get_payload(decode=True))
    return parts


def build_multipart(fields: dict) -> tuple[bytes, str]:
    """
    Build a multipart/form-data body from fields dict:
      field_name -> (filename_or_None, content_type, data_bytes)
    Returns (body_bytes, content_type_header_value).
    """
    boundary = b"----ParakeetProxyBoundary0xDEADBEEF"
    body = b""
    for name, (filename, ct, data) in fields.items():
        body += b"--" + boundary + b"\r\n"
        if filename:
            body += (
                f'Content-Disposition: form-data; name="{name}"; filename="{filename}"\r\n'
            ).encode()
        else:
            body += f'Content-Disposition: form-data; name="{name}"\r\n'.encode()
        body += f"Content-Type: {ct}\r\n\r\n".encode()
        body += data + b"\r\n"
    body += b"--" + boundary + b"--\r\n"
    return body, f"multipart/form-data; boundary={boundary.decode()}"


class ProxyHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        print(f"[parakeet-proxy] {self.address_string()} - {fmt % args}", flush=True)

    def do_GET(self):
        if self.path == "/health":
            self._forward_get("/health")
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        if self.path.rstrip("/") == "/v1/audio/transcriptions":
            self._handle_transcription()
        else:
            self.send_response(404)
            self.end_headers()

    def _forward_get(self, path):
        try:
            url = f"http://127.0.0.1:{PARAKEET_PORT}{path}"
            with urllib.request.urlopen(url, timeout=5) as resp:
                body = resp.read()
                self.send_response(resp.status)
                self.send_header("Content-Type", resp.headers.get("Content-Type", "application/json"))
                self.end_headers()
                self.wfile.write(body)
        except Exception as e:
            self.send_response(502)
            self.end_headers()
            self.wfile.write(str(e).encode())

    def _handle_transcription(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length)
        ct = self.headers.get("Content-Type", "")

        try:
            fields = parse_multipart(ct, body)
        except Exception as e:
            self._error(400, f"failed to parse multipart: {e}")
            return

        if "file" not in fields:
            self._error(400, "missing required field 'file'")
            return

        filename, file_ct, audio_data = fields["file"]

        # Convert to WAV regardless of what we received
        try:
            wav_data = convert_to_wav(audio_data)
        except subprocess.CalledProcessError:
            self._error(400, "ffmpeg could not decode audio")
            return
        except Exception as e:
            self._error(500, f"conversion error: {e}")
            return

        # Rebuild multipart with converted WAV, preserve other fields
        new_fields = {}
        for name, (fn, fct, data) in fields.items():
            if name == "file":
                new_fields[name] = ("recording.wav", "audio/wav", wav_data)
            else:
                new_fields[name] = (fn, fct, data)

        new_body, new_ct = build_multipart(new_fields)

        # Forward to parakeet-server
        try:
            url = f"http://127.0.0.1:{PARAKEET_PORT}/v1/audio/transcriptions"
            req = urllib.request.Request(
                url,
                data=new_body,
                headers={"Content-Type": new_ct},
                method="POST",
            )
            with urllib.request.urlopen(req, timeout=300) as resp:
                resp_body = resp.read()
                self.send_response(resp.status)
                self.send_header("Content-Type", resp.headers.get("Content-Type", "application/json"))
                self.end_headers()
                self.wfile.write(resp_body)
        except urllib.error.HTTPError as e:
            resp_body = e.read()
            self.send_response(e.code)
            self.send_header("Content-Type", e.headers.get("Content-Type", "application/json"))
            self.end_headers()
            self.wfile.write(resp_body)
        except Exception as e:
            self._error(502, f"upstream error: {e}")

    def _error(self, code: int, msg: str):
        body = f'{{"error":{{"message":"{msg}","type":"proxy_error"}}}}'.encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(body)


if __name__ == "__main__":
    proc = subprocess.Popen([
        "parakeet-server",
        "--host", "127.0.0.1",
        "--port", str(PARAKEET_PORT),
        "--model", MODEL,
        "--cache-dir", CACHE_DIR,
    ])
    print(f"[parakeet-proxy] started parakeet-server pid={proc.pid} on :{PARAKEET_PORT}", flush=True)

    server = http.server.HTTPServer(("0.0.0.0", PROXY_PORT), ProxyHandler)
    print(f"[parakeet-proxy] listening on :{PROXY_PORT}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        proc.terminate()
        proc.wait()
