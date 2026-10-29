// "ライブラリを最新にする" (in the advanced part at the bottom) against the fake board of reconnect-check.cjs. The
// board starts with an old speaker.rb, a led_matrix.mrb that would hide the
// .rb, and no grove_link.rb; the rest matches lib/. Then:
//   1. update: the three are put right, nothing is left as .new, the board restarts
//   2. update again, once it is back: "変更はありません", nothing written
//   3. a board whose disk fills up at the second file: the error is reported,
//      the .new already written is taken away, and the library is as it was
//   4. "ライブラリを初期設定に戻す": a .new
//      left over, the .mrb and the firmware's stamp go, the board restarts
//   5. ".mrb にして実機で実行" / "実機の app.mrb にする": the code goes over compiled,
//      and "app.rb にする" / "app.rb を空にする" take an app.mrb away
//   6. "対戦ゲームを実機の app.mrb にする": sim/games/link_pong.mrb goes over as it is, whole
//      (a .mrb has zero bytes, which the bridge to JS would cut a string at). The page is
//      handed tools/game-mrb/hello_game.mrb as games/link_pong.mrb, whether or not the game is there
// The fake shell throws away what comes in while it waits for the terminal
// to say where the cursor is, as the real one does; no byte may be lost.
//
//   docker compose -f docker/compose.yml run --rm browser node /work/tools/browser-check/lib-update-check.cjs
const http = require('http');
const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright');
const { FAKE_SERIAL, termText, TYPES, ROOT } = require('./reconnect-check.cjs');
const GAME_MRB = `${ROOT}/tools/game-mrb/hello_game.mrb`;

const LIB = {};
for (const f of ['adventure_board.rb', ...fs.readdirSync(`${ROOT}/lib/adventure_board`).map((f) => `adventure_board/${f}`)]) {
  LIB[`/lib/${f}`] = fs.readFileSync(`${ROOT}/lib/${f}`, 'utf8');
}

// The board's files before the page touches them.
const VERSION = LIB['/lib/adventure_board.rb'].match(/VERSION = "([^"]*)"/)[1];

function seed(lib) {
  const files = { ...lib };
  files['/lib/adventure_board/speaker.rb'] = '# an old speaker\n';
  // The first firmware's library has no VERSION.
  files['/lib/adventure_board.rb'] = lib['/lib/adventure_board.rb'].replace(/^  VERSION = .*\n/m, '');
  files['/lib/adventure_board/led_matrix.mrb'] = 'RITE0300...';
  delete files['/lib/adventure_board/grove_link.rb'];
  files['/home/app.rb'] = '# untouched\n';
  files['/etc/adventure-board-files'] = 'stamp\n';
  return files;
}

function compare(files) {
  const wrong = Object.keys(LIB).filter((p) => files[p] !== LIB[p]);
  const extra = Object.keys(files).filter((p) => p.endsWith('.new') || p.endsWith('.mrb'));
  return { wrong, extra };
}

async function waitStatus(page, text, ms) {
  return page.waitForFunction((t) => document.getElementById('status').textContent.includes(t), text, { timeout: ms })
    .then(() => true).catch(() => false);
}

(async () => {
  const server = http.createServer((req, res) => {
    const file = path.join(ROOT, decodeURIComponent(req.url.split('?')[0]).replace(/\/$/, '/index.html'));
    fs.readFile(file, (err, data) => {
      if (err) { res.writeHead(404); res.end(); return; }
      res.writeHead(200, { 'Content-Type': TYPES[path.extname(file)] || 'application/octet-stream' });
      res.end(data);
    });
  }).listen(8098);
  const browser = await chromium.launch({ args: ['--no-sandbox'] });
  let failed = false;
  const check = (label, ok) => { console.log(`${ok ? 'ok  ' : 'FAIL'} ${label}`); if (!ok) failed = true; };

  for (const scenario of ['update', 'disk full', 'reset', 'mrb', 'game']) {
    const page = await browser.newPage({ viewport: { width: 1200, height: 900 } });
    const log = [];
    // games/link_pong.mrb is looked for when the page opens; its 404 until the
    // game has been committed is not a fault (the game scenario hands one in).
    page.on('console', (m) => {
      if ((m.location().url || '').endsWith('/games/link_pong.mrb')) return;
      log.push(`[${m.type()}] ${m.text()}`);
    });
    page.on('pageerror', (e) => log.push(`[pageerror] ${e.message}`));
    await page.addInitScript(FAKE_SERIAL);
    if (scenario === 'game') {
      await page.route('**/games/link_pong.mrb', (route) => route.fulfill({
        status: 200, contentType: 'application/octet-stream', body: fs.readFileSync(GAME_MRB) }));
    }
    await page.goto('http://127.0.0.1:8098/sim/');
    await page.waitForFunction(() => (document.getElementById('status') || {}).className === 'ok', null, { timeout: 60000 });
    const files = seed(LIB);
    await page.evaluate(([f, fail]) => { window.__board.shell.files = f; window.__failWrite = fail; },
      [files, scenario === 'disk full' ? ['/lib/adventure_board/grove_link.rb.new'] : []]);
    console.log(`\n=== ${scenario} ===`);
    await page.click('#device-connect');
    await waitStatus(page, '接続しました', 10000);
    const board = () => page.evaluate(() => window.__board.shell.files);
    await page.click('#advanced-toggle');   // both buttons are in the advanced part at the bottom
    await page.waitForSelector('#device-reset-lib');
    check('the advanced part names the version', (await page.textContent('#device-advanced')).includes(`${VERSION} 版`));

    if (scenario === 'game') {
      await page.waitForSelector('#device-install-game', { timeout: 10000 });
      await page.click('#device-install-game');
      check('game: reports', await waitStatus(page, '/home/app.mrb に書いて実行しています', 30000));
      const sent = await page.evaluate(() => (window.__board.shell.rawHex || {})['/home/app.mrb'] || '');
      const want = fs.readFileSync(GAME_MRB).toString('hex');
      check(`game: /home/app.mrb is the .mrb byte for byte (${sent.length / 2} of ${want.length / 2} bytes)`, sent === want);
    }

    if (scenario === 'mrb') {
      const ran = () => page.evaluate(() => window.__board.shell.ran.join(' '));
      await page.fill('#code', 'puts "hello from mrb"\n');
      await page.click('#device-run-mrb');
      check('run .mrb: reports', await waitStatus(page, '実機で実行しています', 30000));
      let f = await board();
      check('run .mrb: /home/run.mrb is bytecode', (f['/home/run.mrb'] || '').startsWith('RITE'));
      check('run .mrb: and it was run', (await ran()).includes('/home/run.mrb'));
      await page.evaluate(() => { window.__board.shell.files['/home/app.mrb'] = 'RITE0300...'; });
      await page.click('#device-install');
      check('app.rb: reports', await waitStatus(page, '/home/app.rb に書いて実行しています', 30000));
      check('app.rb: app.mrb is gone', !('/home/app.mrb' in await board()));
      await page.click('#device-install-mrb');
      check('app.mrb: reports', await waitStatus(page, '/home/app.mrb に書いて実行しています', 30000));
      f = await board();
      check('app.mrb: is bytecode, app.rb stays', (f['/home/app.mrb'] || '').startsWith('RITE') && '/home/app.rb' in f);
      await page.click('#device-clear');
      check('clear: reports', await waitStatus(page, '何もしない', 30000));
      check('clear: app.mrb is gone', !('/home/app.mrb' in await board()));
      await page.fill('#code', 'def broken(\n');
      await page.click('#device-run-mrb');
      check('a syntax error is reported, nothing sent', await waitStatus(page, 'コンパイルできませんでした', 30000));
    } else if (scenario === 'reset') {
      await page.evaluate(() => { window.__board.shell.files['/lib/adventure_board/speaker.rb.new'] = '# half way\n'; });
      await page.click('#device-reset-lib');
      check('reports the reset', await waitStatus(page, 'ファームウェアがライブラリを書き直します', 60000));
      console.log('# status:', await page.textContent('#status'));
      const after = await board();
      const left = Object.keys(after).filter((p) => p.endsWith('.new') || p.endsWith('.mrb'));
      check(`no .new or .mrb left (left: ${left.join(', ') || 'none'})`, left.length === 0);
      check('the stamp is gone', !('/etc/adventure-board-files' in after));
      check('/home/app.rb untouched', after['/home/app.rb'] === '# untouched\n');
      check('the board restarted and the page came back', await waitStatus(page, 'つなぎ直しました', 45000));
    } else {
      await page.click('#device-update-lib');
    }

    if (scenario === 'update') {
      check('reports what it rewrote', await waitStatus(page, '新しくしました', 60000));
      check('says from which version to which', (await page.textContent('#status')).includes(`2026.10.25 版から ${VERSION} 版`));
      console.log('# status:', await page.textContent('#status'));
      const after = compare(await board());
      check(`every lib file matches lib/ (wrong: ${after.wrong.join(', ') || 'none'})`, after.wrong.length === 0);
      check(`no .new or .mrb left (left: ${after.extra.join(', ') || 'none'})`, after.extra.length === 0);
      check('/home/app.rb untouched', (await board())['/home/app.rb'] === '# untouched\n');
      check('the board restarted and the page came back', await waitStatus(page, 'つなぎ直しました', 45000));
      check('and says again what it did', (await page.textContent('#status')).includes(`${VERSION} 版にしました`));
      await page.evaluate(() => { window.__board.shell.written = []; });
      await page.click('#device-update-lib');
      check('second time: up to date', await waitStatus(page, '変更はありません', 60000));
      const sent = await page.evaluate(() => window.__board.shell.written.join('').replace(/\x1b\[\d+;\d+R/g, ''));
      check('second time: nothing written, no restart', !sent.includes('.new') && !sent.includes('reboot'));
    } else if (scenario === 'disk full') {
      check('reports the failure', await waitStatus(page, 'ライブラリは変えていません', 60000));
      console.log('# status:', await page.textContent('#status'));
      const after = await board();
      const untouched = Object.keys(files).every((p) => after[p] === files[p]);
      check('the board\'s files are as they were', untouched);
      check(`no .new left (${Object.keys(after).filter((p) => p.endsWith('.new')).join(', ') || 'none'})`,
        !Object.keys(after).some((p) => p.endsWith('.new')));
      const sent = await page.evaluate(() => window.__board.shell.written.join('').replace(/\x1b\[\d+;\d+R/g, ''));
      check('no restart', !sent.includes('reboot'));
      const ops = await page.evaluate(() => (window.__ops || []).join(''));
      check('the .new written before the failure was removed', ops.includes('remove_file("/lib/adventure_board/speaker.rb.new")'));
    }
    const lost = await page.evaluate(() => window.__lost || 0);
    check(`the shell lost no bytes (${lost})`, lost === 0);
    console.log('# terminal:');
    (await termText(page)).split('\n').filter((l) => l.trim()).slice(-12).forEach((l) => console.log('   ' + l));
    // The page reports its own failure on the console too; that one is expected.
    const errs = log.filter((l) => (l.startsWith('[error]') || l.startsWith('[pageerror]')) &&
                                   !(scenario === 'disk full' && l.includes('ライブラリは変えていません')) &&
                                   !(scenario === 'mrb' && l.includes('コンパイルできませんでした')));
    check(`no page errors${errs.length ? ': ' + errs.join(' / ') : ''}`, errs.length === 0);
    await page.close();
  }
  await browser.close();
  server.close();
  process.exit(failed ? 1 : 0);
})();
