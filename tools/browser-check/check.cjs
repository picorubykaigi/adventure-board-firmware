// Drives sim/index.html in a headless Chromium and reports what actually
// happened: console output, page errors, and the panel read back out of the
// canvas as text so a result can be asserted on rather than eyeballed.
//
//   rake sim:check              all examples
//   rake sim:check[01_light]    one example
//
// Screenshots land in tmp/browser-check/ (git-ignored).

// CommonJS on purpose: playwright lives in the image at /opt/browser-check,
// this file is bind-mounted under /work, and NODE_PATH is honoured by require
// but not by ESM import, which resolves only by walking up from the importing
// file.
const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const { chromium } = require('playwright');

const ROOT = '/work';
const OUT = path.join(ROOT, 'tmp', 'browser-check');
const PORT = 8099;
const ONLY = process.argv[2] || null;

// Geometry of the panel, mirroring the constants in sim/index.html.
const CELL = 26, GAP = 2, PAD = 4, N = 16;

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.rb': 'text/plain; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json',
  // Without this the browser refuses to compile the module by streaming and
  // falls back to an ArrayBuffer, which works but is slower and noisy.
  '.wasm': 'application/wasm',
  '.webp': 'image/webp',
};

function serve() {
  const server = http.createServer((req, res) => {
    const url = decodeURIComponent(req.url.split('?')[0]);
    let file = path.join(ROOT, url);
    if (url.endsWith('/')) file = path.join(file, 'index.html');
    if (!file.startsWith(ROOT)) { res.writeHead(403); res.end(); return; }
    fs.readFile(file, (err, data) => {
      if (err) { res.writeHead(404); res.end('not found: ' + url); return; }
      const type = MIME[path.extname(file)] || 'application/octet-stream';
      // The page probes for a local wasm build with HEAD; answering it with a
      // body makes the browser abort the request.
      if (req.method === 'HEAD') {
        res.writeHead(200, { 'Content-Type': type, 'Content-Length': data.length });
        res.end();
        return;
      }
      res.writeHead(200, { 'Content-Type': type });
      res.end(data);
    });
  });
  return new Promise((resolve) => server.listen(PORT, '127.0.0.1', () => resolve(server)));
}

// Read the canvas back as a 16x16 map. The renderer paints an unlit dot as a
// dark well and a lit one towards white, so the red channel at the centre of a
// cell separates them cleanly.
// The coloured copy under the code box: whether it is on, whether it says the
// same thing as the box, and how many spans of each category it was cut into
// (k1 keyword, k2 string, k3 comment, k4 number, k5 symbol, k6 constant,
// k7 @ivar/$gvar, k8 method name). Text and counts, so nobody has to look.
async function readCodeColors(page) {
  return await page.evaluate(() => {
    const pre = document.getElementById('code-colors');
    const box = document.getElementById('code');
    if (!pre || !box) return 'no #code-colors element';
    if (!pre.parentElement.classList.contains('colored')) return 'off (no SyntaxHighlight in this wasm?)';
    const want = box.value.endsWith('\n') ? box.value + ' ' : box.value;
    const same = pre.textContent === want;
    const counts = {};
    pre.querySelectorAll('span').forEach((el) => { counts[el.className] = (counts[el.className] || 0) + 1; });
    const list = Object.keys(counts).sort().map((k) => `${k}=${counts[k]}`).join(' ');
    const first = pre.querySelector('.k1');
    return `on, text ${same ? 'matches the box' : 'DIFFERS from the box'}, ${list}` +
           (first ? `, first keyword "${first.textContent}"` : '');
  });
}

async function readPanel(page) {
  return await page.evaluate(({ CELL, GAP, PAD, N }) => {
    const canvas = document.getElementById('panel');
    const ctx = canvas.getContext('2d');
    const rows = [];
    for (let y = 0; y < N; y++) {
      let row = '';
      for (let x = 0; x < N; x++) {
        const px = PAD + x * (CELL + GAP) + Math.floor(CELL / 2);
        const py = PAD + y * (CELL + GAP) + Math.floor(CELL / 2);
        const d = ctx.getImageData(px, py, 1, 1).data;
        const r = d[0];
        row += r > 170 ? '#' : (r > 90 ? '+' : (r > 45 ? '-' : '.'));
      }
      rows.push(row);
    }
    return rows;
  }, { CELL, GAP, PAD, N });
}

function show(label, rows) {
  console.log(`--- ${label} ---`);
  console.log('    0123456789012345');
  rows.forEach((row, i) => console.log(String(i + 1).padStart(3, ' ') + ' ' + row));
}

// Hold a button down, let a few ticks go by, then let go. mousedown/mouseup
// rather than click, because the board's buttons are momentary and the page
// models that.
async function press(page, selector, ms = 500, whileHeld = null) {
  await page.hover(selector);
  await page.mouse.down();
  await page.waitForTimeout(ms);
  // Anything that only shows while the button is down has to be read before
  // letting go.
  if (whileHeld) await whileHeld();
  await page.mouse.up();
  await page.waitForTimeout(300);
}

async function showNotes(page, label) {
  const text = await page.textContent('#notelog');
  const lines = (text || '').trim().split('\n').filter((l) => l.length);
  console.log(`--- ${label}: ${lines.length} note events ---`);
  lines.slice(0, 14).forEach((l) => console.log('  ' + l));
  if (lines.length > 14) console.log(`  ... and ${lines.length - 14} more`);
  return lines;
}

// The status LED is a class on a span, so it can be read the same way the
// panel is: sampled a few times to see it actually blinking.
async function watchStatusLed(page, samples = 8, gapMs = 120) {
  const seen = [];
  for (let i = 0; i < samples; i++) {
    const cls = await page.getAttribute('#status-led', 'class');
    seen.push(cls && !cls.includes('off') ? 'on' : 'off');
    await page.waitForTimeout(gapMs);
  }
  console.log(`--- status led over ${samples} samples ---`);
  console.log('  ' + seen.join(' '));
  return seen;
}

// The breadboard's LEDs: renderParts leaves their brightness (0..1, linear in
// current) on the #parts canvas, sampled here like the status LED.
async function watchBreadboardLeds(page, samples = 8, gapMs = 150) {
  const seen = [];
  for (let i = 0; i < samples; i++) {
    seen.push(await page.getAttribute('#parts', 'data-leds'));
    await page.waitForTimeout(gapMs);
  }
  console.log(`--- breadboard LEDs over ${samples} samples ---`);
  console.log('  ' + seen.join(' '));
  return seen;
}

const INTERACTIVE = {
  life: async (page) => {
    // Generations are 150 ms apart: two reads a second apart should differ,
    // and both should have cells alive.
    const a = await readPanel(page);
    await page.waitForTimeout(1000);
    const b = await readPanel(page);
    show('life: a second later', b);
    const lit = (rows) => rows.join('').replace(/\./g, '').length;
    console.log(`# life: ${lit(a)} then ${lit(b)} cells lit, changed: ${a.join('') !== b.join('')}`);
  },
  '07_breadboard_led': async (page) => {
    // Loading the example wires the breadboard from its comments.
    console.log(`# wiring: ${JSON.stringify(await page.evaluate(() => {
      const t = document.getElementById('bb-text'); return t ? t.value : '(text box closed)';
    }))}`);
    const seen = (await watchBreadboardLeds(page)).map((v) => parseFloat(v || '0'));
    const lit = seen.filter((v) => v > 0.2);
    console.log(`# blinking: ${lit.length > 0 && seen.some((v) => v === 0)}, ` +
      `lit at ${lit.length ? lit[0] : '-'} (1 kOhm: about 0.31)`);
    const w = await page.$('#bb-warnings');
    console.log(`# warnings: ${w ? await w.textContent() : '(none)'}`);
    // A switch plugged in, then a sample for the LED matrix: the view goes
    // back to the whole board, and the matrix still lights. (A switch used
    // to make Funicular build the matrix's canvas anew, and nothing drew
    // into the new one.)
    await page.click('#bb-text-toggle');
    await page.waitForTimeout(300);
    await page.fill('#bb-text', 'switch e12\n');
    await page.click('#bb-text-apply');
    await page.waitForTimeout(300);
    await page.selectOption('#examples', '01_light.rb');
    await page.waitForFunction(() => document.getElementById('code').value.includes('matrix.set'));
    await page.click('#run');
    await page.waitForTimeout(1000);
    console.log(`# view after loading 01_light: ${await page.textContent('.zoom-tabs .tab.on')}`);
    show('01_light after a switch was plugged in (expect the top-left dot)', await readPanel(page));
  },
  status_led: async (page) => {
    const seen = await watchStatusLed(page);
    const blinked = seen.includes('on') && seen.includes('off');
    console.log(`# blinking: ${blinked}`);
    await press(page, '[data-pin="22"]', 700, async () => {
      const held = await page.getAttribute('#status-led', 'class');
      console.log(`# while A is held: ${held && !held.includes('off') ? 'on' : 'off'}`);
    });
  },
  harmony: async (page) => {
    // The player runs as its own task, so the notes arrive over time.
    await page.waitForTimeout(2500);
    await showNotes(page, 'harmony');
  },
  sound_and_light: async (page) => {
    await page.waitForTimeout(2000);
    await showNotes(page, 'sound_and_light');
    show('sound_and_light: panel', await readPanel(page));
  },
  '04_buttons': async (page) => {
    // A very short click must still move exactly one cell: the press is an
    // event on a queue, so it cannot fall between two loop ticks.
    await press(page, '[data-pin="19"]', 20); // right, a flick
    show('04_buttons: after a 20ms click on right (expect one step)', await readPanel(page));
    await press(page, '[data-pin="19"]', 120); // right, briefly
    show('04_buttons: after a short tap on right (expect one step)', await readPanel(page));
    await press(page, '[data-pin="19"]', 900); // right, held: no repeat in this one
    show('04_buttons: after holding right (expect one step)', await readPanel(page));
    await press(page, '[data-pin="20"]', 120); // down, briefly
    show('04_buttons: after a short tap on down', await readPanel(page));
    await page.keyboard.down('ArrowLeft');
    await page.waitForTimeout(500);
    await page.keyboard.up('ArrowLeft');
    await page.waitForTimeout(300);
    show('04_buttons: after holding the left arrow key (expect one step)', await readPanel(page));
  },
  '04_buttons_held': async (page) => {
    await press(page, '[data-pin="22"]', 700, async () => {
      show('04_buttons_held: A held (expect all lit)', await readPanel(page));
    });
    await page.waitForTimeout(200);
    show('04_buttons_held: A released (expect blank)', await readPanel(page));
  },
};

const messages = [];
const errors = [];

function summary() {
  console.log('\n# console output');
  if (messages.length === 0) console.log('  (none)');
  messages.forEach((m) => console.log('  ' + m));
  console.log('\n# errors');
  if (errors.length === 0) console.log('  (none)');
  else errors.forEach((e) => console.log('  ' + e));
}

async function main() {
  fs.mkdirSync(OUT, { recursive: true });
  const server = await serve();
  const browser = await chromium.launch({ args: ['--no-sandbox'] });
  const page = await browser.newPage({ viewport: { width: 1200, height: 900 } });

  // Every AudioContext the page makes is kept where the check can see it: Run
  // is what switches the sound on, and that only works from inside the click.
  await page.addInitScript(() => {
    const Real = window.AudioContext;
    window.__audioContexts = [];
    if (Real) {
      window.AudioContext = function (...args) {
        const ctx = new Real(...args);
        window.__audioContexts.push(ctx);
        return ctx;
      };
      window.AudioContext.prototype = Real.prototype;
    }
  });

  page.on('console', (m) => {
    const line = `[${m.type()}] ${m.text()}`;
    messages.push(line);
    // games/link_pong.mrb is looked for when the page opens and is there only
    // once the game has been committed; its 404 until then is not a fault.
    const missingGame = (m.location().url || '').endsWith('/games/link_pong.mrb');
    if (m.type() === 'error' && !missingGame) errors.push(line);
  });
  page.on('pageerror', (e) => errors.push(`[pageerror] ${e.message}`));
  page.on('requestfailed', (r) => errors.push(`[requestfailed] ${r.url()} ${r.failure()?.errorText}`));

  console.log(`# loading http://127.0.0.1:${PORT}/sim/`);
  await page.goto(`http://127.0.0.1:${PORT}/sim/`, { waitUntil: 'load', timeout: 60000 });

  // The Ruby task enables the buttons once it has set the page up.
  let ready = true;
  try {
    await page.waitForFunction(() => {
      const run = document.getElementById('run');
      return run && !run.disabled;
    }, null, { timeout: 60000 });
  } catch (e) {
    ready = false;
    console.log('# the page never became ready');
  }

  // Read what we can even when the page never came up: a status element that
  // is missing is itself the finding, and the console output below is what
  // says why.
  try {
    const status = await page.textContent('#status', { timeout: 2000 });
    const statusClass = await page.getAttribute('#status', 'class', { timeout: 2000 });
    console.log(`# status (${statusClass}): ${status}`);
  } catch (e) {
    console.log('# no #status element on the page');
    const body = await page.evaluate(() => document.body.innerHTML.slice(0, 400));
    console.log(`# body starts: ${body}`);
  }

  await page.screenshot({ path: path.join(OUT, '00-startup.png') });
  try {
    // A board at rest shows nothing; the examples below are what prove the
    // drawing path works.
    show('startup (expected blank)', await readPanel(page));
  } catch (e) {
    console.log(`# could not read the panel: ${e.message}`);
  }

  let deviceOnly = [];
  if (ready) {
    const all = await page.$$eval('#examples option', (els) =>
      els.map((el) => ({ value: el.value, label: el.textContent })));
    // examples/ are listed too, for reading and sending to a board; they
    // cannot run here and are checked on their own below.
    const options = all.filter((o) => !o.value.startsWith('device:'));
    deviceOnly = all.filter((o) => o.value.startsWith('device:'));
    console.log(`# ${options.length} examples, ${deviceOnly.length} device-only`);

    for (const [i, opt] of options.entries()) {
      const name = opt.value.replace(/\.rb$/, '');
      if (ONLY && name !== ONLY) continue;

      // Each example starts from a fresh board. Run alone keeps the board's
      // state, as a real one does, so whatever one example left in the chips
      // or the interrupt table would show in the next.
      await page.click('#reset');
      await page.waitForTimeout(300);

      const before = await page.inputValue('#code');
      await page.selectOption('#examples', opt.value);
      // The example is fetched by the Ruby task, so wait for the new text to
      // land rather than for the box to be merely non-empty.
      await page.waitForFunction(
        (prev) => {
          const v = document.getElementById('code').value;
          return v.trim().length > 0 && v !== prev;
        }, before, { timeout: 15000 }).catch(() => {});
      const code = await page.inputValue('#code');
      await page.click('#run');
      await page.waitForTimeout(1200);
      const st = await page.textContent('#status');
      const cls = await page.getAttribute('#status', 'class');
      const file = path.join(OUT, `${String(i + 1).padStart(2, '0')}-${name}.png`);
      await page.screenshot({ path: file });
      console.log(`\n# example: ${opt.label} (${opt.value})  [${code.length} bytes of code]`);
      console.log(`# status (${cls}): ${st}`);
      console.log(`# code colours: ${await readCodeColors(page)}`);
      console.log(`# audio after Run: ${await page.evaluate(() =>
        (window.__audioContexts || []).map((c) => c.state).join(' ') || 'no AudioContext')}, ` +
        `audio button: ${(await page.$('#audio')) ? 'STILL THERE' : 'gone'}`);
      show(name, await readPanel(page));


      // Examples that read the buttons need someone to press them.
      if (INTERACTIVE[name]) await INTERACTIVE[name](page);
    }
  }

  // Device-only examples: they load, and Run says to send them to a board
  // rather than running them.
  if (ready && !ONLY) {
    for (const opt of deviceOnly) {
      const before = await page.inputValue('#code');
      await page.selectOption('#examples', opt.value);
      // Until the box holds the new file, not the one before it.
      await page.waitForFunction((prev) => {
        const v = document.getElementById('code').value;
        return v.length > 0 && v !== prev;
      }, before, { timeout: 10000 }).catch(() => {});
      const loaded = (await page.inputValue('#code')).length;
      await page.click('#run');
      await page.waitForTimeout(400);
      const st = await page.textContent('#status');
      console.log(`# device-only: ${opt.label} (${opt.value})  [${loaded} chars]  Run says: ${st.includes('実機専用') ? 'device-only' : st}`);
    }
  }

  await browser.close();
  server.close();

  summary();
  console.log(`\n# screenshots in tmp/browser-check/`);
  process.exit(errors.length === 0 && ready ? 0 : 1);
}

main().catch((e) => { console.error(e); summary(); process.exit(2); });
