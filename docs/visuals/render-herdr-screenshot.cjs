#!/usr/bin/env node
// Render actual native Herdr terminal cells captured in an isolated home.
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { chromium } = require('playwright');

const root = path.resolve(__dirname, '../..');
const destination = path.join(root, 'docs/assets/screenshots');
const escape = text => text.replace(/[&<>"']/g, char => ({
  '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
})[char]);
const palette = {
  black: '#272e33', red: '#e67e80', green: '#a7c080', brown: '#dbbc7f',
  blue: '#7fbbb3', magenta: '#d699b6', cyan: '#83c092', white: '#d3c6aa',
  brightblack: '#7a8478', brightred: '#e67e80', brightgreen: '#a7c080',
  brightbrown: '#dbbc7f', brightblue: '#7fbbb3', brightmagenta: '#d699b6',
  brightcyan: '#83c092', brightwhite: '#dfddc7',
};
const color = (value, background) => value === 'default'
  ? (background ? '#272e33' : '#d3c6aa') : (palette[value] || `#${value}`);

async function main() {
  const binary = process.argv[2] || process.env.LOCAL_AI_DOCS_HERDR;
  if (!binary) throw new Error('Supply a reviewed native Herdr 0.9.0 executable as the first argument or LOCAL_AI_DOCS_HERDR.');
  const capture = spawnSync(process.env.PYTHON || 'python3',
    [path.join(__dirname, 'capture-herdr.py'), '--binary', binary],
    { encoding: 'utf8', maxBuffer: 8 * 1024 * 1024 });
  if (capture.error) throw capture.error;
  if (capture.status !== 0) throw new Error(capture.stderr || capture.stdout);
  const terminal = JSON.parse(capture.stdout);
  const grid = terminal.cells.map(row => row.map(cell => {
    let foreground = color(cell.fg, false), background = color(cell.bg, true);
    if (cell.reverse) [foreground, background] = [background, foreground];
    return `<span style="color:${foreground};background:${background};font-weight:${cell.bold ? 700 : 400};font-style:${cell.italics ? 'italic' : 'normal'};text-decoration:${cell.underscore ? 'underline' : 'none'}">${escape(cell.data || ' ')}</span>`;
  }).join('')).join('\n');
  const browser = await chromium.launch({ headless: true, executablePath: process.env.LOCAL_AI_DOCS_BROWSER || undefined });
  try {
    const page = await browser.newPage({ viewport: { width: 1320, height: 860 }, deviceScaleFactor: 2 });
    await page.setContent(`<!doctype html><html lang="en"><meta charset="utf-8">
<title>Herdr golf workspace — native isolated preview</title><style>
* { box-sizing: border-box; }
body { margin: 0; padding: 32px; background: #232a2e; color: #d3c6aa; font-family: 'SFMono-Regular', Consolas, monospace; }
main { border: 1px solid #59665f; background: #272e33; }
header { padding: 20px 24px; border-bottom: 1px solid #475258; display: flex; justify-content: space-between; font-size: 14px; letter-spacing: 1.5px; color: #a7c080; }
header span:last-child { color: #9da9a0; }
pre { margin: 0; padding: 20px; font: 14px/1.55 'SFMono-Regular', Consolas, monospace; white-space: pre; }
footer { padding: 18px 24px; border-top: 1px solid #475258; background: #2e383c; color: #dbbc7f; font-size: 12px; letter-spacing: 1px; }
</style><main><header><span>HERDR / GOLF WORKSPACE</span><span>REAL TERMINAL UI · 0.9.0</span></header>
<pre>${grid}</pre><footer>ISOLATED ${escape(terminal.platform.toUpperCase())} FIXTURE / TWO PROJECTS / NO MODELS OR AGENTS STARTED</footer></main></html>`);
    await page.evaluate(() => document.fonts.ready);
    const height = Math.ceil(await page.evaluate(() => document.body.getBoundingClientRect().height));
    await page.setViewportSize({ width: 1320, height });
    fs.mkdirSync(destination, { recursive: true });
    await page.screenshot({ path: path.join(destination, 'herdr-golf-workspace.png'), fullPage: true });
    fs.writeFileSync(path.join(destination, 'herdr-golf-workspace.txt'),
      terminal.display.map(line => line.trimEnd()).join('\n') + '\n');
    console.log(`Captured native Herdr 0.9.0 on ${terminal.platform}.`);
  } finally {
    await browser.close();
  }
}

main().catch(error => { console.error(error); process.exitCode = 1; });
