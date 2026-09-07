#!/usr/bin/env node
// Development-only: render actual PTY transcripts, never invented UI states.
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { chromium } = require('playwright');

const root = path.resolve(__dirname, '../..');
const destination = path.join(root, 'docs/assets/screenshots');
const escape = text => text.replace(/[&<>"']/g, value => ({
  '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
})[value]);

function ansiHtml(text) {
  const colors = ['#272e33', '#e67e80', '#a7c080', '#dbbc7f', '#7fbbb3', '#d699b6', '#83c092', '#d3c6aa'];
  let bold = false, dim = false, foreground = '#d3c6aa', html = '', cursor = 0;
  const codes = /\x1b\[([0-9;?]*)([A-Za-z])/g;
  const append = content => {
    html += `<span style="color:${foreground};font-weight:${bold ? 700 : 400};opacity:${dim ? 0.82 : 1}">${escape(content)}</span>`;
  };
  for (const match of text.matchAll(codes)) {
    append(text.slice(cursor, match.index));
    if (match[2] === 'm') {
      for (const code of (match[1] || '0').split(';').map(Number)) {
        if (code === 0) { bold = false; dim = false; foreground = '#d3c6aa'; }
        if (code === 1) bold = true;
        if (code === 2) dim = true;
        if (code === 22) { bold = false; dim = false; }
        if (code === 39) foreground = '#d3c6aa';
        if (code >= 30 && code <= 37) foreground = colors[code - 30];
      }
    }
    cursor = match.index + match[0].length;
  }
  append(text.slice(cursor));
  return html;
}

async function main() {
  const capture = spawnSync(process.env.PYTHON || 'python3', [path.join(__dirname, 'capture-terminal.py')], { encoding: 'utf8' });
  if (capture.error) throw capture.error;
  if (capture.status !== 0) throw new Error(capture.stderr || capture.stdout);
  const transcripts = JSON.parse(capture.stdout);
  fs.mkdirSync(destination, { recursive: true });
  const browser = await chromium.launch({ headless: true, executablePath: process.env.LOCAL_AI_DOCS_BROWSER || undefined });
  try {
    const page = await browser.newPage({ viewport: { width: 1200, height: 1000 }, deviceScaleFactor: 2 });
    for (const [name, transcript] of Object.entries(transcripts)) {
      const menu = name === 'local-ai-menu';
      await page.setContent(`<!doctype html><html lang="en"><meta charset="utf-8">
<title>Local AI · ${menu ? 'The menu' : 'Preview the plan'}</title>
<style>
* { box-sizing: border-box; }
body { margin: 0; padding: 32px; background: #232a2e; color: #d3c6aa; font-family: 'DejaVu Sans Mono', 'SFMono-Regular', Consolas, monospace; }
main { border: 1px solid #59665f; background: #272e33; }
header { display: flex; justify-content: space-between; align-items: center; padding: 19px 25px; border-bottom: 1px solid #475258; font-size: 14px; letter-spacing: 1.6px; }
.title { color: #a7c080; } .index { color: #9da9a0; }
.body { padding: 25px 25px 29px; }
.prompt { margin: 0 0 22px; color: #7fbbb3; font-size: 17px; }
.prompt b { color: #a7c080; font-weight: 400; }
pre { margin: 0; white-space: pre-wrap; overflow-wrap: anywhere; font: 15px/1.65 'DejaVu Sans Mono', 'SFMono-Regular', Consolas, monospace; }
footer { padding: 16px 25px; display: flex; justify-content: space-between; gap: 24px; background: #2e383c; border-top: 1px solid #475258; font-size: 12px; letter-spacing: 1px; color: #9da9a0; }
footer strong { color: #dbbc7f; font-weight: 400; }
</style><main><header><span class="title">LOCAL AI / ${menu ? 'THE MENU' : 'PREVIEW CHANGES'}</span><span class="index">${menu ? '01' : '02'} — EVERFOREST</span></header>
<div class="body"><p class="prompt">~/github/local-ai-setup <b>❯ ${escape(transcript.command)}</b></p><pre>${ansiHtml(transcript.output.trimEnd())}</pre></div>
<footer><strong>PRE-INSTALL DEMO · NO MODELS OR SERVICES</strong><span>REAL CLI OUTPUT / ISOLATED HOME</span></footer></main></html>`);
      await page.evaluate(() => document.fonts.ready);
      const height = Math.ceil(await page.evaluate(() => document.body.getBoundingClientRect().height));
      await page.setViewportSize({ width: 1200, height });
      await page.screenshot({ path: path.join(destination, `${name}.png`), fullPage: true });
      const plain = transcript.output.replace(/\x1b\[[0-9;?]*[A-Za-z]/g, '').replace(/[ \t]+$/gm, '').trimEnd();
      fs.writeFileSync(path.join(destination, `${name}.txt`), plain + '\n');
      console.log(`Captured ${name}.png`);
    }
  } finally {
    await browser.close();
  }
}

main().catch(error => { console.error(error); process.exitCode = 1; });
