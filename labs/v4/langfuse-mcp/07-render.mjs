// 07-render.mjs <id> [...] — replay .run/tty/<id>.bin (07-tty-capture.py) in xterm.js and save
// captures/07-<id>.png. XTERM = directory of the @xterm/xterm 5.5.0 package (lib/, css/);
// PLAYWRIGHT = path of playwright's index.mjs. The terminal is 120 x 50 like the capture.
import { readFileSync, mkdirSync } from "node:fs";
const { chromium } = await import(process.env.PLAYWRIGHT ?? "playwright");
const here = new URL(".", import.meta.url).pathname;
const X = process.env.XTERM;
const js = readFileSync(`${X}/lib/xterm.js`, "utf8"), css = readFileSync(`${X}/css/xterm.css`, "utf8");
mkdirSync(`${here}captures`, { recursive: true });
const b = await chromium.launch();
for (const id of process.argv.slice(2)) {
  const data = readFileSync(`${here}.run/tty/${id}.bin`).toString("base64");
  const page = await b.newPage({ viewport: { width: 1200, height: 1000 }, deviceScaleFactor: 1 });
  await page.setContent(`<!doctype html><html><head><meta charset="utf-8"><style>${css}
    body{margin:0;background:#1e1e1e} #t{padding:12px}</style></head><body><div id="t"></div>
    <script>${js}</script></body></html>`);
  await page.evaluate(async (b64) => {
    const term = new window.Terminal({ cols: 120, rows: 50, fontSize: 14, fontFamily: "Menlo, monospace",
      theme: { background: "#1e1e1e" }, allowProposedApi: true });
    term.open(document.getElementById("t"));
    const bytes = Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
    await new Promise((r) => term.write(bytes, r));
  }, data);
  await page.waitForTimeout(500);
  const box = await page.locator(".xterm-screen").boundingBox();
  await page.screenshot({ path: `${here}captures/07-${id}.png`, clip: { x: 0, y: 0, width: box.width + 24, height: box.height + 24 } });
  console.log(`captures/07-${id}.png`);
  await page.close();
}
await b.close();
