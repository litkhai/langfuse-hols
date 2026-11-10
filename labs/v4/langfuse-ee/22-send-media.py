#!/usr/bin/env python3
"""22-send-media.py — send ONE trace that carries a synthetic PNG, for lab 22 (media on AWS S3).

    22-send-media.py sdk  <seed>    Python SDK + LangfuseMedia: the SDK uploads the image itself
                                    through the presigned PUT URL that Langfuse hands out
    22-send-media.py otlp <seed>    raw OTLP/HTTP JSON with the image as a base64 data URI inside the
                                    input attribute: no SDK media handling (the worker may extract it)
    22-send-media.py png <seed> <file>   only write the PNG; prints SHA256, SHA256B64, LENGTH

The PNG is random noise (no real document), different for each seed, so two runs never share a
media id through content deduplication.

From the environment (set by 22-ee-aws-s3-sse-kms.sh, never printed):
    LAB22_PK / LAB22_SK   the project's API keys
    LANGFUSE_HOST         default http://localhost:3000
Prints `TRACE_ID <id>`, `SHA256 <hex>` and `MARKER <base64 substring>`; in otlp mode also
`HTTP <status>` of the OTLP request. Python 3.10+, the langfuse SDK (see _base/v4/requirements.txt).
"""
import base64
import hashlib
import json
import os
import random
import struct
import sys
import time
import urllib.error
import urllib.request
import zlib


def synthetic_png(seed: str, size: int = 96) -> bytes:
    rng = random.Random(seed)
    raw = b"".join(b"\x00" + bytes(rng.getrandbits(8) for _ in range(size * 3)) for _ in range(size))

    def chunk(tag: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


mode, seed = sys.argv[1], sys.argv[2]
host = os.environ.get("LANGFUSE_HOST", "http://localhost:3000")
pk, sk = os.environ["LAB22_PK"], os.environ["LAB22_SK"]
png = synthetic_png(seed)
b64 = base64.b64encode(png).decode()
print(f"SHA256 {hashlib.sha256(png).hexdigest()}")
print(f"MARKER {b64[200:248]}")  # past the PNG header, unique to this image

if mode == "png":  # only write the image (for a hand-made presigned PUT) and print its hashes
    open(sys.argv[3], "wb").write(png)
    print(f"SHA256B64 {base64.b64encode(hashlib.sha256(png).digest()).decode()}")
    print(f"LENGTH {len(png)}")

elif mode == "sdk":
    from langfuse import Langfuse
    try:
        from langfuse.media import LangfuseMedia
    except ImportError:  # moved between SDK versions
        from langfuse import LangfuseMedia

    lf = Langfuse(base_url=host, public_key=pk, secret_key=sk)
    if not lf.auth_check():
        raise SystemExit("auth check failed")
    media = LangfuseMedia(content_bytes=png, content_type="image/png")
    with lf.start_as_current_observation(as_type="generation", name="lab22-sdk-media",
                                         input={"text": "synthetic scan", "image": media}) as gen:
        trace_id = lf.get_current_trace_id()
        gen.update(output="ok")
    lf.flush()
    lf.shutdown()
    print(f"TRACE_ID {trace_id}")

elif mode == "otlp":
    trace_id = os.urandom(16).hex()
    now = time.time_ns()
    content = [{"type": "text", "text": "synthetic scan"},
               {"type": "image_url", "image_url": {"url": f"data:image/png;base64,{b64}"}}]
    attr = lambda k, v: {"key": k, "value": {"stringValue": v}}  # noqa: E731
    body = {"resourceSpans": [{
        "resource": {"attributes": [attr("service.name", "lab22")]},
        "scopeSpans": [{"scope": {"name": "lab22"}, "spans": [{
            "traceId": trace_id, "spanId": os.urandom(8).hex(), "name": "lab22-otlp-media",
            "kind": 1, "startTimeUnixNano": str(now - 1_000_000), "endTimeUnixNano": str(now),
            "attributes": [attr("langfuse.observation.type", "generation"),
                           attr("langfuse.observation.input", json.dumps([{"role": "user", "content": content}])),
                           attr("langfuse.observation.output", json.dumps("ok"))],
        }]}],
    }]}
    req = urllib.request.Request(
        f"{host}/api/public/otel/v1/traces", data=json.dumps(body).encode(), method="POST",
        headers={"Content-Type": "application/json",
                 "Authorization": "Basic " + base64.b64encode(f"{pk}:{sk}".encode()).decode()})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            status = r.status
    except urllib.error.HTTPError as e:
        status = e.code
    print(f"HTTP {status}")
    print(f"TRACE_ID {trace_id}")
else:
    raise SystemExit("mode: sdk | otlp | png <file>")
