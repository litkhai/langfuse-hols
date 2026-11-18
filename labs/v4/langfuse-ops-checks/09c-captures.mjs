// 09c-captures.mjs — screenshots for test 09 (Playwright, Chromium, 1440 x 900, light theme).
//   node 09c-captures.mjs keys|viewer|export|org-enforced|org-switch
// Signs in as the init user of _base/.env (LANGFUSE_INIT_USER_EMAIL / _PASSWORD from the environment) and
// writes captures/09-<name>.png. Needs the `playwright` package and an installed Chromium: PLAYWRIGHT is the
// path of its index.mjs when it is not installed next to this file (ES modules ignore NODE_PATH).
import { mkdirSync } from "node:fs";
const { chromium } = await import(process.env.PLAYWRIGHT ?? "playwright");

const H = process.env.LANGFUSE_HOST ?? "http://localhost:3000";
const P = process.env.LANGFUSE_INIT_PROJECT_ID ?? "llm-observability";
const O = process.env.LANGFUSE_INIT_ORG_ID ?? "ch-workshop";
const OUT = new URL("./captures/", import.meta.url).pathname;
mkdirSync(OUT, { recursive: true });

const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1440, height: 900 }, colorScheme: "light" });
await page.goto(`${H}/auth/sign-in`);
await page.getByPlaceholder("jsdoe@example.com").fill(process.env.LANGFUSE_INIT_USER_EMAIL);
await page.locator('input[type="password"]').fill(process.env.LANGFUSE_INIT_USER_PASSWORD);
await page.keyboard.press("Enter");
await page.waitForURL((u) => !u.pathname.startsWith("/auth"), { timeout: 30000 });

const shot = async (name) => {
  await page.waitForTimeout(800);
  await page.screenshot({ path: `${OUT}09-${name}.png` });
  console.log(`captures/09-${name}.png`);
};

for (const what of process.argv.slice(2)) {
  if (what === "keys") {
    await page.goto(`${H}/project/${P}/settings/api-keys`);
    await page.getByRole("button", { name: /Create new API keys/i }).click();
    await page.getByText("Debug traces, build datasets").first().click();
    await shot("api-key-presets");
    await page.keyboard.press("Escape");
    await page.keyboard.press("Escape");
  } else if (what === "viewer") {
    await page.goto(`${H}/project/${P}/settings/audit-logs`);
    await page.getByText("access").first().waitFor();
    await shot("project-audit-log");
  } else if (what === "export") {
    await page.goto(`${H}/project/${P}/settings/audit-logs`);
    await page.getByText("access").first().waitFor();
    await page.waitForTimeout(2000);   // the menu opens only once the page has hydrated
    await page.getByRole("button", { name: /Export/ }).last().click();
    await page.waitForTimeout(1500);
    await shot("audit-log-export-menu");
    await page.keyboard.press("Escape");
  } else if (what === "org-enforced" || what === "org-switch") {
    await page.goto(`${H}/organization/${O}/settings/audit-logs`);
    await page.getByText("Organization Audit Logs").waitFor();
    await shot(what === "org-switch" ? "org-access-logging-switch" : "org-audit-log-enforced");
  }
}
await browser.close();
