// 09-captures.mjs — screenshots for the README and the article (Playwright, Chromium, 1440 x 900, light theme).
//   node labs/v4/langfuse-ch-vector/09-captures.mjs
// Signs in to Langfuse as the init user of _base/.env and opens the ClickHouse Play UI of the shared stack
// (LANGFUSE_INIT_USER_EMAIL / _PASSWORD, CLICKHOUSE_USER / _PASSWORD from the environment; source _base/.env first).
// Writes captures/*.png. PLAYWRIGHT is the path of playwright's index.mjs when it is not installed next to this file.
import { mkdirSync, readFileSync } from "node:fs";
const { chromium } = await import(process.env.PLAYWRIGHT ?? "playwright");

const H = process.env.LANGFUSE_HOST ?? "http://localhost:3000";
const P = process.env.LANGFUSE_INIT_PROJECT_ID ?? "llm-observability";
const CH = process.env.CH_URL ?? "http://localhost:8123";
const DIR = new URL("./", import.meta.url).pathname;
const OUT = `${DIR}captures/`;
mkdirSync(OUT, { recursive: true });
const failing = readFileSync(`${DIR}.run/failing_trace_id`, "utf8").trim();

const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1440, height: 900 }, colorScheme: "light" });
const shot = async (name, opts = {}) => {
  await page.waitForTimeout(1200);
  await page.screenshot({ path: `${OUT}${name}.png`, ...opts });
  console.log(`captures/${name}.png`);
};

// Langfuse
await page.goto(`${H}/auth/sign-in`);
await page.getByPlaceholder("jsdoe@example.com").fill(process.env.LANGFUSE_INIT_USER_EMAIL);
await page.locator('input[type="password"]').fill(process.env.LANGFUSE_INIT_USER_PASSWORD);
await page.keyboard.press("Enter");
await page.waitForURL((u) => !u.pathname.startsWith("/auth"), { timeout: 30000 });

await page.goto(`${H}/project/${P}/traces/${failing}`);
await page.getByText("banking-support").first().waitFor();
await shot("01-failing-trace");

// ClickHouse Play UI: the query goes in the URL hash (base64), credentials in the query string.
const play = async (name, sqlFile, height = 900) => {
  const sql = readFileSync(`${DIR}${sqlFile}`, "utf8").split("\n").filter((l) => !l.startsWith("--")).join("\n").trim();
  const q = new URLSearchParams({ user: process.env.CLICKHOUSE_USER, password: process.env.CLICKHOUSE_PASSWORD });
  await page.setViewportSize({ width: 1440, height });
  await page.goto(`${CH}/play?${q}#${Buffer.from(sql).toString("base64")}`);
  await page.locator("#run").click();
  await page.locator("#data-table tr").nth(1).waitFor({ timeout: 30000 });
  await shot(name);
};
await play("02-similar-to-failing", "04-similar.sql", 1000);
await play("03-topics", "05-topics.sql", 900);
await play("04-postfilter-trap", "04-postfilter.sql", 760);

// Langfuse: the topic score written back by 05-topics.py --scores, on the trace table
await page.setViewportSize({ width: 1440, height: 900 });
await page.goto(`${H}/project/${P}/traces/${failing}`);
await page.getByText("banking-support").first().waitFor();
await page.getByRole("tab", { name: /Scores/ }).first().click().catch(() => {});
await shot("05-topic-score");

await browser.close();
