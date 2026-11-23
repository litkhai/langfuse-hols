// 06-viewer-key.mjs — create a project API key with the Viewer role on the side web container
// (06-viewer-key.sh starts it with API_AUTH_MIGRATION=enforce and API_KEY_PROJECT_ROLES_ENABLE=true)
// and write it to .run/viewer-key.env. Captures: captures/06-mcp-settings.png, 06-key-role.png.
// Signs in as the init user of _base/.env. PLAYWRIGHT = path of playwright's index.mjs.
import { mkdirSync, writeFileSync } from "node:fs";
const { chromium } = await import(process.env.PLAYWRIGHT ?? "playwright");
const H = process.env.ROLES_HOST ?? "http://localhost:48300";
const P = process.env.LANGFUSE_INIT_PROJECT_ID;
const here = new URL(".", import.meta.url).pathname;
mkdirSync(`${here}captures`, { recursive: true });
mkdirSync(`${here}.run`, { recursive: true });

const b = await chromium.launch();
const page = await b.newPage({ viewport: { width: 1440, height: 900 }, colorScheme: "light" });
await page.goto(`${H}/auth/sign-in`);
await page.getByPlaceholder("jsdoe@example.com").fill(process.env.LANGFUSE_INIT_USER_EMAIL);
await page.locator('input[type="password"]').fill(process.env.LANGFUSE_INIT_USER_PASSWORD);
await page.keyboard.press("Enter");
await page.waitForURL((u) => !u.pathname.startsWith("/auth"), { timeout: 30000 });

await page.goto(`${H}/project/${P}/settings/developer-tools`);   // "MCP & CLI"
await page.waitForTimeout(2500);
await page.screenshot({ path: `${here}captures/06-mcp-settings.png` });

await page.goto(`${H}/project/${P}/settings/api-keys`);
await page.getByRole("button", { name: /create new api key/i }).first().click();
const dlg = page.locator('[role="dialog"]');
await dlg.getByPlaceholder("e.g. Production server").fill("lab-langfuse-mcp viewer");
await dlg.getByText("All read and write privileges.").click();
await page.getByText("Read-only privileges.").last().click();
await page.waitForTimeout(500);
await page.screenshot({ path: `${here}captures/06-key-role.png` });
await dlg.getByRole("button", { name: "Create API key" }).click();
await page.waitForTimeout(2000);
const text = await page.locator('[role="dialog"]').innerText();
const sk = text.match(/sk-lf-[0-9a-f-]+/)?.[0], pk = text.match(/pk-lf-[0-9a-f-]+/)?.[0];
if (!sk || !pk) { console.error("✗ key not found in dialog:\n" + text.slice(0, 600)); process.exit(1); }
writeFileSync(`${here}.run/viewer-key.env`, `VIEWER_PUBLIC_KEY=${pk}\nVIEWER_SECRET_KEY=${sk}\n`, { mode: 0o600 });
console.log(`✓ Viewer key ${pk} → .run/viewer-key.env`);
await b.close();
