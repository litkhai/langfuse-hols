// 09-captures.mjs — screenshots for the README and the notes article (Playwright, Chromium, light theme).
//   node 09-captures.mjs traces|rollup|review|bench|upgrade ...   (09-captures.sh sets up what upgrade needs)
// traces: Langfuse's trace list filtered to this lab's tag, signed in as the init user of _base/.env
// (LANGFUSE_INIT_USER_EMAIL / _PASSWORD from the environment). rollup, review, bench, upgrade: ClickHouse's Play UI
// (CH_URL, default http://localhost:8123/play) with CLICKHOUSE_USER / _PASSWORD, running one query each.
// Writes captures/09-<name>.png. Needs the `playwright` package and an installed Chromium: PLAYWRIGHT is the
// path of its index.mjs when it is not installed next to this file (ES modules ignore NODE_PATH).
import { mkdirSync } from "node:fs";
const { chromium } = await import(process.env.PLAYWRIGHT ?? "playwright");

const H = process.env.LANGFUSE_HOST ?? "http://localhost:3000";
const P = process.env.LANGFUSE_INIT_PROJECT_ID ?? "llm-observability";
const CH = (process.env.CH_URL ?? "http://localhost:8123") + "/play";
const OUT = new URL("./captures/", import.meta.url).pathname;
mkdirSync(OUT, { recursive: true });

const QUERIES = {
  rollup: `-- per service, from the hourly rollup (lab_langfuse_ch_mv.obs_hourly_by_service)
SELECT service_name, sum(traces) AS traces, sum(observations) AS observations, sum(errors) AS errors,
       sum(total_tokens) AS tokens, round(sum(cost_usd), 4) AS cost_usd,
       round(quantilesTDigestMergeIf(0.5, 0.95, 0.99)(latency_ms, type = 'GENERATION')[2]) AS gen_p95_ms
FROM lab_langfuse_ch_mv.obs_hourly_by_service
GROUP BY service_name ORDER BY service_name`,
  review: `-- traces tagged review:needed, copied with their full input (lab_langfuse_ch_mv.review_observations)
SELECT min(start_time) AS started, any(service_name) AS service, count() AS observations,
       countIf(level = 'ERROR') AS errors, anyIf(JSONExtractString(input, '질문'), parent_span_id = '') AS question
FROM lab_langfuse_ch_mv.review_observations FINAL
GROUP BY trace_id ORDER BY started DESC LIMIT 12`,
  bench: `-- 05-bench.sh, from system.query_log: raw copy of events_full vs the views' tables (median of 3 runs, latest run of today)
SELECT replaceRegexpOne(query_id, '^05-[0-9]+-(.*)-[0-9]$', '\\\\1') AS step, median(query_duration_ms) AS ms,
       any(read_rows) AS read_rows, formatReadableSize(any(read_bytes)) AS read
FROM system.query_log
WHERE type = 'QueryFinish' AND query_id LIKE '05-%-Q%' AND event_date = today()
  AND query_id LIKE concat('05-', (SELECT argMax(splitByChar('-', query_id)[2], event_time) FROM system.query_log WHERE query_id LIKE '05-%-Q%' AND event_date = today()), '-%')
GROUP BY step ORDER BY step`,
  upgrade: `-- a copy of events_full with the per-service view attached, after RENAME COLUMN provided_model_name TO model_name
INSERT INTO lab_langfuse_ch_mv_upgrade.probe (project_id, trace_id, span_id, start_time, model_name, tags)
VALUES ('llm-observability', 't1', 's1', now64(6), 'gpt-4o-mini', ['lab:langfuse-ch-mv'])`,
};

const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1440, height: 900 }, colorScheme: "light" });
const shot = async (name, clip) => {
  await page.waitForTimeout(800);
  await page.screenshot({ path: `${OUT}09-${name}.png`, ...(clip ? { clip } : {}) });
  console.log(`captures/09-${name}.png`);
};

for (const what of process.argv.slice(2)) {
  if (what === "traces") {
    await page.goto(`${H}/auth/sign-in`);
    await page.getByPlaceholder("jsdoe@example.com").fill(process.env.LANGFUSE_INIT_USER_EMAIL);
    await page.locator('input[type="password"]').fill(process.env.LANGFUSE_INIT_USER_PASSWORD);
    await page.keyboard.press("Enter");
    await page.waitForURL((u) => !u.pathname.startsWith("/auth"), { timeout: 30000 });
    // The v4 trace list keeps its filter in the URL: traceTags;arrayOptions;;any of;<value, URL-encoded once more>
    await page.goto(`${H}/project/${P}/traces?filter=traceTags%3BarrayOptions%3B%3Bany+of%3Blab%253Alangfuse-ch-mv`);
    await page.getByText('traceTags:"lab:langfuse-ch-mv"').first().waitFor({ timeout: 30000 });
    await page.waitForTimeout(4000);
    await shot("traces");
  } else {
    await page.setViewportSize({ width: 1440, height: what === "upgrade" ? 420 : 640 });
    await page.goto(CH);
    await page.locator("#user").fill(process.env.CLICKHOUSE_USER);
    await page.locator("#password").fill(process.env.CLICKHOUSE_PASSWORD);
    await page.locator("#query").fill(QUERIES[what]);
    await page.locator("#run").click();
    await page.getByText(/rows in result|Code: \d+/).first().waitFor({ timeout: 30000 });
    await page.waitForTimeout(1500);
    await shot(what);
  }
}
await browser.close();
