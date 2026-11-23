#!/usr/bin/env python3
"""01 — the prompts the seeded generations point at, so the trace page links each one to its version.

Creates text prompts ch-dash-<service> in the init project through the public API, one version per
entry below, and stops at the count listed (re-running creates nothing new). Version numbers are
assigned by Langfuse in creation order, so a prompt that already has more versions is left alone.
"""

from __future__ import annotations

import sys

from lablib import api

PROMPTS = {
    "ch-dash-loan-advisor": [
        "당신은 은행 대출 상담 도우미입니다. 상품 설명서 근거로만 답하고, 금리는 범위로 안내합니다.",
        "당신은 은행 대출 상담 도우미입니다. 상품 설명서 근거로만 답하고, 금리는 범위로 안내하며, 필요한 서류를 목록으로 덧붙입니다.",
        "당신은 은행 대출 상담 도우미입니다. 상품 설명서 근거로 자세히 답하고, 비슷한 상품 두 가지를 비교표(JSON)로 함께 제시합니다.",
    ],
    "ch-dash-card-faq": [
        "카드 고객 FAQ 도우미입니다. 약관 조항을 인용해 세 문장 이내로 답합니다.",
        "카드 고객 FAQ 도우미입니다. 약관 조항을 인용해 세 문장 이내로 답하고, 고객센터 연결이 필요한 경우를 먼저 판별합니다.",
    ],
    "ch-dash-doc-summary": [
        "사내 문서를 다섯 줄로 요약합니다. 수치와 결정 사항은 빠뜨리지 않습니다.",
    ],
    "ch-dash-policy-search": [
        "사내 규정 검색 도우미입니다. 조항 번호와 함께 답합니다.",
        "사내 규정 검색 도우미입니다. 조항 번호와 시행일을 함께 답하고, 개정 이력이 있으면 알려 줍니다.",
    ],
}


def versions(name: str) -> int:
    r = api("GET", "/api/public/v2/prompts", params={"name": name, "limit": 1})
    r.raise_for_status()
    rows = r.json().get("data", [])
    return max(rows[0]["versions"]) if rows and rows[0].get("versions") else 0


def main() -> int:
    for name, texts in PROMPTS.items():
        have = versions(name)
        for i, text in enumerate(texts[have:], start=have + 1):
            r = api("POST", "/api/public/v2/prompts",
                    json={"name": name, "type": "text", "prompt": text,
                          "labels": ["production"] if i == len(texts) else [],
                          "tags": ["lab:langfuse-ch-dashboard"]})
            r.raise_for_status()
            print(f"  + {name} v{r.json()['version']}")
        print(f"✓ {name}: {max(have, len(texts))} versions")
    return 0


if __name__ == "__main__":
    sys.exit(main())
