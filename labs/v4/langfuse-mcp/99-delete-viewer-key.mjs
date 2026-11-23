// 99-delete-viewer-key.mjs — delete the project API keys named "lab-langfuse-mcp viewer"
// (06-viewer-key.mjs) in the UI of the shared web. PLAYWRIGHT = path of playwright's index.mjs.
const { chromium } = await import(process.env.PLAYWRIGHT ?? "playwright");
const H = process.env.LANGFUSE_HOST ?? "http://localhost:3000";
const P = process.env.LANGFUSE_INIT_PROJECT_ID;
const b = await chromium.launch();
const page = await b.newPage({ viewport: { width: 1440, height: 900 } });
await page.goto(`${H}/auth/sign-in`);
await page.getByPlaceholder("jsdoe@example.com").fill(process.env.LANGFUSE_INIT_USER_EMAIL);
await page.locator('input[type="password"]').fill(process.env.LANGFUSE_INIT_USER_PASSWORD);
await page.keyboard.press("Enter");
await page.waitForURL((u) => !u.pathname.startsWith("/auth"), { timeout: 30000 });
await page.goto(`${H}/project/${P}/settings/api-keys`);
await page.waitForTimeout(2500);
let n = 0;
for (;;) {
  const row = page.locator("tr", { hasText: "lab-langfuse-mcp viewer" });
  if ((await row.count()) === 0) break;
  await row.first().locator("button").last().click();
  await page.getByRole("menuitem", { name: /Delete API key/ }).click();
  const dlg = page.locator('[role="alertdialog"], [role="dialog"]').last();
  await dlg.getByRole("button", { name: /delete/i }).last().click();
  await page.waitForTimeout(1500);
  n += 1;
  if (n > 5) throw new Error("still listed after 5 deletions");
}
console.log(`✓ deleted ${n} Viewer key(s)`);
await b.close();
