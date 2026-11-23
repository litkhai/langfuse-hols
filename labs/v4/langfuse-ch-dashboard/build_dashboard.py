#!/usr/bin/env python3
"""Write grafana/dashboards/langfuse-kr.json from sql/*.sql.tmpl — the SQL files are the single source. They end in .sql.tmpl, not
.sql: Grafana macros and ${variables} are not ClickHouse syntax, and the CI parses every tracked .sql.

Each panel's rawSql is the file's text as is (Grafana macros and ${variables} included); 04-measure.py
expands the same files the way the datasource plugin does. Run after editing a panel's SQL:

  python3 build_dashboard.py          # write
  python3 build_dashboard.py --check  # fail if the JSON is out of date
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

LAB = Path(__file__).resolve().parent
OUT = LAB / "grafana" / "dashboards" / "langfuse-kr.json"
DS = {"type": "grafana-clickhouse-datasource", "uid": "langfuse-ch"}
TRACE_LINK = "${langfuse_url}/project/${project}/traces/${__value.raw}"


def sql(name: str) -> str:
    return (LAB / "sql" / f"{name}.sql.tmpl").read_text()


def target(name: str, fmt: int) -> dict:
    # format: 0 = time series, 1 = table (grafana-clickhouse-datasource editor types)
    return {"refId": "A", "datasource": DS, "editorType": "sql", "format": fmt, "queryType": "sql",
            "rawSql": sql(name)}


def ts(pid, title, name, grid, unit, desc, draw="line", stack=False, overrides=None, display=None):
    return {
        "id": pid, "type": "timeseries", "title": title, "description": desc, "datasource": DS,
        "gridPos": grid, "targets": [target(name, 0)],
        "fieldConfig": {"defaults": {"unit": unit, **({"displayName": display} if display else {}), "custom": {
            "drawStyle": draw, "lineWidth": 2, "fillOpacity": 70 if draw == "bars" else 0,
            "showPoints": "always" if draw == "line" else "never", "pointSize": 5,
            "stacking": {"mode": "normal" if stack else "none", "group": "A"}}},
            "overrides": overrides or []},
        "options": {"legend": {"displayMode": "table", "placement": "right", "calcs": ["mean", "max"]},
                    "tooltip": {"mode": "multi", "sort": "desc"}},
    }


def table(pid, title, name, grid, desc, link_col=None, overrides=None):
    ov = list(overrides or [])
    if link_col:
        ov.append({"matcher": {"id": "byName", "options": link_col}, "properties": [
            {"id": "custom.width", "value": 290},
            {"id": "links", "value": [{"title": "Langfuse에서 trace 열기", "url": TRACE_LINK,
                                       "targetBlank": True}]}]})
    return {"id": pid, "type": "table", "title": title, "description": desc, "datasource": DS,
            "gridPos": grid, "targets": [target(name, 1)],
            "fieldConfig": {"defaults": {"custom": {"align": "auto"}}, "overrides": ov},
            "options": {"showHeader": True, "cellHeight": "sm"}}


def unit(col, u):
    return {"matcher": {"id": "byName", "options": col}, "properties": [{"id": "unit", "value": u}]}


def color_cell(col, steps):
    return {"matcher": {"id": "byName", "options": col}, "properties": [
        {"id": "custom.cellOptions", "value": {"type": "color-background", "mode": "basic"}},
        {"id": "thresholds", "value": {"mode": "absolute", "steps": steps}}]}


def build() -> dict:
    panels = [
        ts(1, "서비스별 트래픽 (KST 일)", "p1-traffic-kst-day", {"x": 0, "y": 0, "w": 12, "h": 8}, "short",
           "root observation 수 = trace 수. 하루 경계는 Asia/Seoul 자정.", draw="bars", stack=True,
           display="${__field.labels.service_name}"),
        ts(2, "팀별 모델 비용 (KRW, KST 일)", "p3-cost-team-krw", {"x": 12, "y": 0, "w": 12, "h": 8},
           "currencyKRW", "Langfuse가 계산한 USD 비용 × 환율 변수 krw_per_usd.", draw="bars", stack=True,
           display="${__field.labels.team}"),
        ts(3, "서비스별 지연 p50 / p95 (초, KST 일)", "p2-latency-kst-day", {"x": 0, "y": 8, "w": 12, "h": 9}, "s",
           "root observation의 end_time − start_time.",
           overrides=[{"matcher": {"id": "byRegexp", "options": "^p50.*"}, "properties": [
               {"id": "custom.lineStyle", "value": {"fill": "dash", "dash": [6, 4]}},
               {"id": "custom.lineWidth", "value": 1}]}]),
        ts(4, "점수 추이: judge 평균 · 👍 비율 (KST 일)", "p7-score-trend", {"x": 12, "y": 8, "w": 12, "h": 9},
           "percentunit", "judge-faithfulness 평균과 user-feedback 1 비율. 서비스는 trace의 root observation에서.",
           overrides=[{"matcher": {"id": "byRegexp", "options": "^thumbs.*"}, "properties": [
               {"id": "custom.lineStyle", "value": {"fill": "dash", "dash": [6, 4]}}]}]),
        table(5, "프롬프트 버전별 실패율 · judge 점수", "p4-failure-by-prompt", {"x": 0, "y": 17, "w": 24, "h": 8},
              "generation의 level = ERROR 비율. judge_avg는 같은 trace의 judge-faithfulness 평균.",
              overrides=[color_cell("failure_pct", [{"color": "green", "value": None},
                                                    {"color": "orange", "value": 4},
                                                    {"color": "red", "value": 7}])]),
        table(6, "느린 trace 20개", "p5-slow-traces", {"x": 0, "y": 25, "w": 24, "h": 9},
              "trace_id를 누르면 Langfuse trace 화면이 열린다.", link_col="trace_id",
              overrides=[unit("seconds", "s")]),
        table(7, "비싼 trace 20개 (KRW)", "p6-costly-traces", {"x": 0, "y": 34, "w": 24, "h": 9},
              "trace_id를 누르면 Langfuse trace 화면이 열린다.", link_col="trace_id",
              overrides=[unit("cost_krw", "currencyKRW")]),
    ]
    variables = [
        {"name": "project", "label": "Langfuse project id", "type": "textbox", "query": "llm-observability",
         "current": {"text": "llm-observability", "value": "llm-observability"}},
        {"name": "environment", "label": "environment", "type": "query", "datasource": DS,
         "query": "SELECT DISTINCT environment FROM ${db}.events_core WHERE project_id = '${project}' "
                  "AND start_time > now() - INTERVAL 90 DAY ORDER BY environment",
         "multi": True, "includeAll": False, "refresh": 1,
         "current": {"text": ["lab-ch-dashboard"], "value": ["lab-ch-dashboard"]}},
        {"name": "krw_per_usd", "label": "KRW / USD", "type": "textbox", "query": "1400",
         "current": {"text": "1400", "value": "1400"}},
        {"name": "db", "label": "database", "type": "custom", "query": "default,lab_langfuse_ch_dashboard",
         "current": {"text": "default", "value": "default"},
         "options": [{"text": "default", "value": "default", "selected": True},
                     {"text": "lab_langfuse_ch_dashboard", "value": "lab_langfuse_ch_dashboard",
                      "selected": False}]},
        {"name": "langfuse_url", "label": "Langfuse URL", "type": "textbox", "query": "http://localhost:3000",
         "current": {"text": "http://localhost:3000", "value": "http://localhost:3000"}},
    ]
    return {
        "uid": "langfuse-kr", "title": "Langfuse · ClickHouse SQL (KST · KRW)", "editable": False,
        "timezone": "Asia/Seoul", "weekStart": "monday", "schemaVersion": 41, "version": 1,
        "time": {"from": "now-14d/d", "to": "now/d"}, "refresh": "",
        "tags": ["langfuse", "clickhouse"], "templating": {"list": variables}, "panels": panels,
    }


def main() -> int:
    text = json.dumps(build(), ensure_ascii=False, indent=2) + "\n"
    if "--check" in sys.argv:
        if not OUT.exists() or OUT.read_text() != text:
            print(f"✗ {OUT.relative_to(LAB)} is out of date: run python3 build_dashboard.py", file=sys.stderr)
            return 1
        print("✓ dashboard JSON matches sql/")
        return 0
    OUT.write_text(text)
    print(f"✓ wrote {OUT.relative_to(LAB)} ({len(build()['panels'])} panels)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
