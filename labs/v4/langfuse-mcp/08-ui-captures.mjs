// 08-ui-captures.mjs — the Langfuse UI next to the model's answers (Playwright, 1440 x 900, light):
//   captures/08-slowest-trace.png   the trace 02-seed-traces.py planted as the slow generation
//   captures/08-prompt-versions.png prompt lab-langfuse-mcp-answer (versions, labels)
// Reads the trace id from .run/seed.json. Signs in as the init user of _base/.env.
// PLAYWRIGHT = path of playwright's index.mjs.
import { readFileSync } from "node:fs";
const { chromium } = await import(process.env.PLAYWRIGHT ?? "playwright");
const H = process.env.LANGFUSE_HOST ?? "http://localhost:3000";
const P = process.env.LANGFUSE_INIT_PROJECT_ID;
const here = new URL(".", import.meta.url).pathname;
const seed = JSON.parse(readFileSync(`${here}.run/seed.json`, "utf8"));
const b = await chromium.launch();
const page = await b.newPage({ viewport: { width: 1440, height: 900 }, colorScheme: "light" });
await page.goto(`${H}/auth/sign-in`);
await page.getByPlaceholder("jsdoe@example.com").fill(process.env.LANGFUSE_INIT_USER_EMAIL);
await page.locator('input[type="password"]').fill(process.env.LANGFUSE_INIT_USER_PASSWORD);
await page.keyboard.press("Enter");
await page.waitForURL((u) => !u.pathname.startsWith("/auth"), { timeout: 30000 });
await page.goto(`${H}/project/${P}/traces/${seed.slow_generation}`);
await page.waitForTimeout(4000);
await page.screenshot({ path: `${here}captures/08-slowest-trace.png` });
await page.goto(`${H}/project/${P}/prompts/lab-langfuse-mcp-answer`);
await page.waitForTimeout(3000);
await page.screenshot({ path: `${here}captures/08-prompt-versions.png` });
console.log("captures/08-slowest-trace.png captures/08-prompt-versions.png");
await b.close();
