// 08-captures.mjs — screenshots for the README and the article (Playwright, Chromium, light theme).
//   node 08-captures.mjs [langfuse] [grafana]
// Langfuse: signs in as the init user of _base/.env (LANGFUSE_INIT_USER_EMAIL / _PASSWORD from the
// environment). Grafana: anonymous viewer on 127.0.0.1:$GRAFANA_PORT. Writes captures/*.png.
// Needs the `playwright` package and an installed Chromium: PLAYWRIGHT is the path of its index.mjs
// when it is not installed next to this file (ES modules ignore NODE_PATH).
import { mkdirSync } from "node:fs";
const { chromium } = await import(process.env.PLAYWRIGHT ?? "playwright");

const H = process.env.LANGFUSE_HOST ?? "http://localhost:3000";
const P = process.env.LANGFUSE_INIT_PROJECT_ID ?? "llm-observability";
const G = `http://127.0.0.1:${process.env.GRAFANA_PORT ?? "58300"}`;
const OUT = new URL("./captures/", import.meta.url).pathname;
mkdirSync(OUT, { recursive: true });
const what = process.argv.slice(2).length ? process.argv.slice(2) : ["langfuse", "grafana"];

const browser = await chromium.launch();
const shot = async (page, name, opts = {}) => {
  await page.waitForTimeout(1200);
  await page.screenshot({ path: `${OUT}${name}.png`, ...opts });
  console.log(`captures/${name}.png`);
};

if (what.includes("langfuse")) {
  const page = await browser.newPage({ viewport: { width: 1440, height: 900 }, colorScheme: "light" });
  await page.goto(`${H}/auth/sign-in`);
  await page.getByPlaceholder("jsdoe@example.com").fill(process.env.LANGFUSE_INIT_USER_EMAIL);
  await page.locator('input[type="password"]').fill(process.env.LANGFUSE_INIT_USER_PASSWORD);
  await page.keyboard.press("Enter");
  await page.waitForURL((u) => !u.pathname.startsWith("/auth"), { timeout: 30000 });

  // Built-in Cost Dashboard: environment = lab-ch-dashboard, past 14 days.
  await page.goto(`${H}/project/${P}/dashboards`);
  await page.getByRole("link", { name: "Langfuse Cost Dashboard" }).first().click();
  await page.getByText("Cost by Model Name").first().waitFor({ timeout: 30000 });
  // No 14-day preset in 4.56.0 (5 min … 1 year): 30 days covers the seeded window.
  await page.getByRole("button", { name: /Past \d/ }).first().click();
  await page.getByText("Past 30 days", { exact: true }).first().click();
  await page.waitForTimeout(1500);
  await page.getByRole("button", { name: /^Env/ }).first().click();
  const opt = (v) => page.locator(`[role=option][data-value="${v}"]`).first();
  if (await opt("Clear filters").count()) await opt("Clear filters").click();
  await opt("lab-ch-dashboard").click();
  await page.locator("button").filter({ hasText: /^Env\s*1\s*lab-ch-dashboard$/ }).first().waitFor({ timeout: 10000 });
  await page.keyboard.press("Escape");
  await page.waitForTimeout(4000);
  await shot(page, "langfuse-cost-dashboard");

  // Widget editor: the breakdown dimensions of the observations view (one dimension, no metadata key).
  await page.goto(`${H}/project/${P}/widgets/new`);
  await page.getByText("Breakdown Dimension").first().waitFor({ timeout: 30000 });
  await page.getByRole("combobox", { name: /Breakdown Dimension/ }).click();
  await shot(page, "langfuse-widget-breakdown");
  await page.keyboard.press("Escape");
  await page.close();
}

if (what.includes("grafana")) {
  // The seeded window, 2026-11-09 00:00 … 2026-11-22 23:59:59 KST, as epoch milliseconds.
  const from = Date.parse(process.env.CAPTURE_FROM ?? "2026-11-09T00:00:00+09:00");
  const to = Date.parse(process.env.CAPTURE_TO ?? "2026-11-22T23:59:59+09:00");
  const page = await browser.newPage({ viewport: { width: 1440, height: 1940 }, colorScheme: "light" });
  const url = `${G}/d/langfuse-kr?orgId=1&from=${from}&to=${to}&theme=light&kiosk`;
  await page.goto(url);
  await page.getByText("프롬프트 버전별 실패율").first().waitFor({ timeout: 30000 });
  await page.waitForTimeout(4000);
  await shot(page, "grafana-dashboard");

  // The trace link: click a trace_id in the costly-traces table, capture the link menu.
  const panel = page.locator("section").filter({ hasText: "비싼 trace 20개" }).last();
  await panel.scrollIntoViewIfNeeded();
  const cell = panel.getByText(/^[0-9a-f]{32}$/).first();
  const traceId = (await cell.textContent()).trim();
  await cell.click();
  await shot(page, "grafana-trace-link", { clip: await panel.boundingBox() });

  // …and the Langfuse page that link opens (signed in as the init user).
  const lf = await browser.newPage({ viewport: { width: 1440, height: 900 }, colorScheme: "light" });
  await lf.goto(`${H}/auth/sign-in`);
  await lf.getByPlaceholder("jsdoe@example.com").fill(process.env.LANGFUSE_INIT_USER_EMAIL);
  await lf.locator('input[type="password"]').fill(process.env.LANGFUSE_INIT_USER_PASSWORD);
  await lf.keyboard.press("Enter");
  await lf.waitForURL((u) => !u.pathname.startsWith("/auth"), { timeout: 30000 });
  await lf.goto(`${H}/project/${P}/traces/${traceId}`);
  await lf.getByText("answer").first().waitFor({ timeout: 30000 });
  await shot(lf, "langfuse-trace-from-link");
  console.log(`trace ${traceId}`);
}
await browser.close();
