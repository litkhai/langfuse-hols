// shots.mjs — UI screenshots for the README and the article (optional; needs Playwright).
//   PLAYWRIGHT_DIR=<dir that has node_modules/playwright> node shots.mjs <baseURL> <outDir> name=/path ...
// Signs in with the lab's admin user, then saves <outDir>/<name>.png per page.
import { createRequire } from "node:module";

const require = createRequire(`${process.env.PLAYWRIGHT_DIR ?? process.cwd()}/`);
const { chromium } = require("playwright");

const [base, out, ...pages] = process.argv.slice(2);
const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1440, height: 900 }, deviceScaleFactor: 1 });
await page.goto(`${base}/auth/sign-in`);
await page.fill('input[name="email"]', process.env.LF_USER ?? "admin@example.com");
await page.fill('input[name="password"]', process.env.LF_PASSWORD ?? "upgrade-lab-password");
await Promise.all([page.waitForURL((u) => !u.pathname.startsWith("/auth"), { timeout: 30000 }),
                   page.click('button[type="submit"]')]);
for (const spec of pages) {
  const [name, path] = spec.split(/=(.*)/s);
  await page.goto(`${base}${path}`, { waitUntil: "networkidle", timeout: 60000 }).catch(() => {});
  await page.waitForTimeout(4000);
  await page.screenshot({ path: `${out}/${name}.png` });
  console.log(`${out}/${name}.png  <- ${path}`);
}
await browser.close();
