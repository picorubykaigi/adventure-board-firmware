// The page's link to a board, against a fake navigator.serial: connect, type
// at the shell, run a program (a PicoModem transfer), restart the board (the
// port drops and comes back three seconds later, with a boot log ending in
// the prompt), and read the terminal to see whether the page found its way
// back. The real browser is not in the loop, but everything on the Ruby side
// of the bridge is, and the fake board answers PicoModem's frames.
//
//   docker compose -f docker/compose.yml run --rm browser node /work/tools/browser-check/reconnect-check.cjs
const http = require('http');
const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright');

const ROOT = '/work';
const TYPES = { '.html': 'text/html', '.js': 'text/javascript', '.wasm': 'application/wasm', '.rb': 'text/plain', '.css': 'text/css' };

const FAKE_SERIAL = () => {
  const enc = new TextEncoder(), dec = new TextDecoder();
  // The line editor's redraw after PicoModem: it asks where the cursor is
  // before it draws the prompt. Nobody answers inside the page's binary
  // capture, so it gives up after a while and draws it anyway.
  const REDRAW = '\x1b[6n$> ';
  class FakePort extends EventTarget {
    constructor(name, shell) { super(); this.name = name; this.shell = shell; this.connected = true; this.opened = false;
      this.readable = null; this.writable = null; this.written = []; this.bootText = null;
      this.line = ''; this.asking = null; this.modem = null; this.file = null; this.files = {}; this.ran = []; }
    async open() {
      if (!this.connected) throw new DOMException('The device has been lost.', 'NetworkError');
      if (this.opened) throw new DOMException('The port is already open.', 'InvalidStateError');
      this.opened = true;
      const self = this;
      this.readable = new ReadableStream({ start(c) { self.ctrl = c; } });
      this.writable = new WritableStream({ write(chunk) { self.take(chunk); } });
      if (this.bootText) { const t = this.bootText; this.bootText = null; setTimeout(() => this.emit(t), 200); }
    }
    // The shell side of the fake board: echoes keys, answers Enter and Ctrl-C
    // with a prompt, `reboot` with a restart, and Ctrl-B with PicoModem.
    take(chunk) {
      this.written.push(dec.decode(chunk));
      if (!this.shell) return;
      if (this.modem) { this.modemBytes(chunk); return; }
      if (this.running) {           // a program has the console: only Ctrl-C gets through
        if (chunk.includes(0x03)) { this.running = false; this.emit('^C\r\n$> '); }
        return;
      }
      // Like the real shell's line editor: before redrawing the line after a
      // key, it asks the terminal where the cursor is (ESC [6n) and waits for
      // the answer, up to 500ms a key, throwing away whatever else comes in
      // meanwhile (window.__lost counts the bytes). Only then the echo.
      if (this.asking) {
        if (/\x1b\[\d+;\d+R/.test(dec.decode(chunk))) { this.answered(); return; }
        if (!chunk.includes(0x03)) { window.__lost = (window.__lost || 0) + chunk.length; return; }
        this.answered();
      }
      const before = this.line;
      let out = ''; const emit = this.emit; this.emit = (t) => { out += t; };
      try { this.shellBytes(chunk); } finally { this.emit = emit; }
      if (this.line.length > before.length) {
        const wait = 500 * (this.line.length - before.length);
        this.asking = { out, timer: setTimeout(() => this.answered(), wait) };
        this.emit('\x1b[6n');
      } else if (out) this.emit(out);
    }
    answered() {
      const a = this.asking; if (!a) return;
      this.asking = null; clearTimeout(a.timer); this.emit(a.out);
    }
    shellBytes(chunk) {
      for (let i = 0; i < chunk.length; i++) {
        const b = chunk[i];
        // Ctrl-B: PicoModem from here, including the rest of this chunk
        if (b === 0x02) { this.modem = { buf: [] }; this.emit('\x06'); this.modemBytes(chunk.slice(i + 1)); return; }
        if (b === 0x03) { this.line = ''; this.emit('^C\r\n$> '); continue; }
        if (b === 0x0d) {
          const line = this.line; this.line = '';
          if (line === 'reboot') { this.emit('\r\nRebooting in 500 ms\r\n'); setTimeout(() => window.__board.reboot(), 500); continue; }
          // The page's file operations (DeviceLink#file_ops): done here, the way
          // the script would on the board.
          if ((this.files[line] || '').startsWith('# Written by the console page')) {
            const say = [];
            const rename = (f, t) => {   // like the board's File.rename: will not write over a file
              if (t in this.files) { say.push(`File exists: ${t}. Can't overwrite`); return; }
              if (f in this.files) { this.files[t] = this.files[f]; delete this.files[f]; }
            };
            const remove = (p) => { delete this.files[p]; };
            for (const m of this.files[line].matchAll(/^(replace_file|remove_file)\(("[^"]*")(?:, ("[^"]*"))?\)$/gm)) {
              const a = JSON.parse(m[2]);
              if (m[1] === 'remove_file') { remove(a); continue; }
              const to = JSON.parse(m[3]), old = to + '.old';
              remove(old);
              if (to in this.files) rename(to, old);
              rename(a, to);
              if (to in this.files) remove(old); else if (old in this.files) rename(old, to);
            }
            (window.__ops = window.__ops || []).push(this.files[line]);   // what ran, for the checks
            delete this.files[line];
            if (say.length) this.emit('\r\n' + say.join('\r\n'));
            this.emit('\r\n[lib_ops] done\r\n$> '); continue;
          }
          if (line.startsWith('/home/')) { this.emit('\r\nLoading ' + line + '\r\n'); this.ran.push(line); continue; }
          if (line === 'free') { this.emit('\r\nfree: 176536\r\n$> '); continue; }
          const words = line.split(' ');
          if (words[0] === 'mv' && words.length === 3) {
            if (!(words[1] in this.files)) { this.emit(`\r\nmv: cannot stat '${words[1]}': No such file or directory\r\n$> `); continue; }
            this.files[words[2]] = this.files[words[1]]; delete this.files[words[1]]; this.emit('\r\n$> '); continue;
          }
          if (words[0] === 'rm') {
            let out = '';
            for (const f of words.slice(1)) { if (f in this.files) delete this.files[f]; else out += `rm: cannot remove '${f}': No such file\r\n`; }
            this.emit('\r\n' + out + '$> '); continue;
          }
          this.emit('\r\n$> '); continue;
        }
        this.line += String.fromCharCode(b); this.emit(String.fromCharCode(b));   // echo
      }
    }
    modemBytes(chunk) {
      const m = this.modem; for (const b of chunk) m.buf.push(b);
      // Like the board's session: anything but a frame ends it.
      if (m.buf.length > 0 && m.buf[0] !== 0x02) { this.modem = null; this.emit('[PicoModem] timeout\r\n' + REDRAW); return; }
      while (m.buf.length >= 3 && m.buf[0] === 0x02) {
        const len = (m.buf[1] << 8) | m.buf[2];
        if (m.buf.length < 3 + len + 2) return;
        const body = m.buf.slice(3, 3 + len); m.buf = m.buf.slice(3 + len + 2);
        const cmd = body[0];
        if (cmd === 0x01) {          // FILE_READ: the path; the file goes out a piece per CHUNK_ACK
          const p = dec.decode(new Uint8Array(body.slice(1)));
          if (!(p in this.files)) { this.fail('File not found: ' + p, 'read ' + p); continue; }
          const data = Array.from(enc.encode(this.files[p]));
          this.reading = { path: p, data, offset: 0 };
          this.sendPiece();
        } else if (cmd === 0x84 && this.reading) {   // the host took a piece
          this.sendPiece();
        } else if (cmd === 0x02) {   // FILE_WRITE: 4-byte size, then the path
          this.file = { size: (body[1] << 24) | (body[2] << 16) | (body[3] << 8) | body[4], path: dec.decode(new Uint8Array(body.slice(5))), data: [] };
          if ((window.__failWrite || []).includes(this.file.path)) { this.fail('No space left', 'write ' + this.file.path); continue; }
          this.reply(0x82, [0]);
        } else if (cmd === 0x04) {   // CHUNK
          for (const x of body.slice(1)) this.file.data.push(x);
          this.reply(0x84, [0]);
          if (this.file.data.length >= this.file.size) {
            const crc = window.__crc32(this.file.data);
            this.reply(0x8f, [0, (crc >>> 24) & 0xff, (crc >>> 16) & 0xff, (crc >>> 8) & 0xff, crc & 0xff]);
            this.files[this.file.path] = dec.decode(new Uint8Array(this.file.data));
            // The bytes as they came, for a check that a binary file arrived whole.
            (this.rawHex = this.rawHex || {})[this.file.path] = this.file.data.map((b) => (b < 16 ? '0' : '') + b.toString(16)).join('');
            this.modem = null;
            this.emit('[PicoModem] write ' + this.file.path + '\r\n' + REDRAW);   // as the shell prints on the way back
          }
        } else if (cmd === 0xff) {   // ABORT
          this.modem = null; this.emit('\r\n$> ');
        }
      }
    }
    sendPiece() {
      const r = this.reading;
      if (r.offset < r.data.length) {   // an empty file is only DONE, as on the board
        const piece = r.data.slice(r.offset, r.offset + 480);
        const head = r.offset === 0 ? [(r.data.length >>> 24) & 0xff, (r.data.length >>> 16) & 0xff, (r.data.length >>> 8) & 0xff, r.data.length & 0xff] : [];
        r.offset += piece.length;
        this.reply(0x81, [...head, ...piece]);
        return;
      }
      const crc = window.__crc32(r.data);
      this.reply(0x8f, [0, (crc >>> 24) & 0xff, (crc >>> 16) & 0xff, (crc >>> 8) & 0xff, crc & 0xff]);
      this.reading = null; this.modem = null;
      this.emit('[PicoModem] read ' + r.path + '\r\n' + REDRAW);
    }
    fail(message, info) {
      this.reply(0xfe, Array.from(enc.encode(message)));
      this.modem = null;
      this.emit('[PicoModem] ' + info + '\r\n' + REDRAW);
    }
    reply(cmd, payload) {
      // the CRC is not checked by the fake; the page checks the one it gets
      const body = [cmd, ...payload]; const crc = window.__crc16(body);
      this.emitBytes(new Uint8Array([0x02, body.length >> 8, body.length & 0xff, ...body, crc >> 8, crc & 0xff]));
    }
    emitBytes(u8) { try { this.ctrl && this.ctrl.enqueue(u8); } catch (e) {} }
    emit(text) { try { this.ctrl && this.ctrl.enqueue(enc.encode(text)); } catch (e) {} }
    async close() { this.opened = false; try { this.ctrl && this.ctrl.close(); } catch (e) {} this.readable = null; this.writable = null; }
    drop() { this.connected = false; this.opened = false;
      try { this.ctrl && this.ctrl.error(new DOMException('The device has been lost.', 'NetworkError')); } catch (e) {}
      this.readable = null; this.writable = null; this.dispatchEvent(new Event('disconnect')); }
  }
  class FakeSerial extends EventTarget {
    constructor() { super(); this.granted = []; }
    async requestPort() { return this.granted.find((p) => p.shell); }
    async getPorts() { return this.granted.filter((p) => p.connected); }
  }
  window.__crc32 = (bytes) => { let c = 0xffffffff; for (const b of bytes) { c ^= b; for (let k = 0; k < 8; k++) c = (c >>> 1) ^ (0xedb88320 & -(c & 1)); } return (c ^ 0xffffffff) >>> 0; };
  window.__crc16 = (bytes) => { let c = 0xffff; for (const b of bytes) { c ^= b << 8; for (let k = 0; k < 8; k++) c = (c & 0x8000) ? ((c << 1) ^ 0x1021) & 0xffff : (c << 1) & 0xffff; } return c; };
  const serial = new FakeSerial();
  const midi = new FakePort('MIDI', false), shell = new FakePort('shell', true);
  serial.granted = [midi, shell];              // both allowed at some point; MIDI listed first
  Object.defineProperty(navigator, 'serial', { value: serial, configurable: true });
  window.__board = {
    shell, midi, events: [],
    reboot() {
      this.events.push('drop'); shell.drop(); midi.drop();
      setTimeout(() => {
        this.events.push('back'); midi.connected = true; shell.connected = true;
        if (window.__appRuns) { shell.bootText = '....\r\nLoading app.rb\r\n'; shell.running = true; }   // app.rb runs on and on: no prompt
        else shell.bootText = '....\r\nLoading app.rb\r\nStarting shell...\r\n$> ';
        if (window.__announce) { serial.dispatchEvent(new Event('connect')); }
      }, 3000);
    },
  };
  window.__announce = !location.search.includes('noannounce');
  window.__appRuns = location.search.includes('appruns');
};

// What the terminal shows, line by line, from xterm's buffer.
async function termText(page) {
  return await page.evaluate(() => {
    const t = window.deviceTerminal(); if (!t) return '(no terminal)';
    const b = t.buffer.active; const lines = [];
    for (let i = 0; i < b.length; i++) lines.push(b.getLine(i).translateToString(true));
    return lines.join('\n');
  });
}

module.exports = { FAKE_SERIAL, termText, TYPES, ROOT };
if (require.main !== module) return;

(async () => {
  const server = http.createServer((req, res) => {
    const file = path.join(ROOT, decodeURIComponent(req.url.split('?')[0]).replace(/\/$/, '/index.html'));
    fs.readFile(file, (err, data) => {
      if (err) { res.writeHead(404); res.end(); return; }
      res.writeHead(200, { 'Content-Type': TYPES[path.extname(file)] || 'application/octet-stream' });
      res.end(data);
    });
  }).listen(8097);
  const browser = await chromium.launch({ args: ['--no-sandbox'] });
  for (const [announce, appRuns] of [[true, false], [false, false], [true, true]]) {
    const page = await browser.newPage({ viewport: { width: 1200, height: 900 } });
    const console_ = [];
    page.on('console', (m) => console_.push(`[${m.type()}] ${m.text()}`));
    page.on('pageerror', (e) => console_.push(`[pageerror] ${e.message}`));
    await page.addInitScript(FAKE_SERIAL);
    await page.goto('http://127.0.0.1:8097/sim/?' + (announce ? '' : 'noannounce') + (appRuns ? '&appruns' : ''));
    await page.waitForFunction(() => (document.getElementById('status') || {}).className === 'ok', null, { timeout: 60000 });
    console.log(`\n=== browser ${announce ? 'announces' : 'does not announce'} the returning port${appRuns ? '; app.rb runs on after the boot (no prompt)' : ''} ===`);
    await page.click('#device-connect');
    await page.waitForFunction(() => document.getElementById('status').textContent.includes('接続しました'), null, { timeout: 10000 });
    console.log('# connected:', await page.textContent('#status'));
    // Typing at the shell: click the terminal, type a command, Enter.
    await page.click('#devicelog');
    await page.keyboard.type('free');
    await page.keyboard.press('Enter');
    await page.waitForTimeout(500);
    console.log('# typed "free", the board got:', JSON.stringify(await page.evaluate(() => window.__board.shell.written.join(''))));
    console.log('# terminal shows:', JSON.stringify(await termText(page)).slice(0, 160));
    // A program: the transfer through PicoModem, then the run.
    await page.evaluate(() => { window.__board.shell.written = []; });
    await page.click('#device-run');
    await page.waitForFunction(() => document.getElementById('status').textContent.includes('実機で実行しています'), null, { timeout: 15000 })
      .catch(() => console.log('# run did not finish: ' + document.getElementById('status').textContent));
    console.log('# run:', await page.textContent('#status'));
    if (announce) await page.screenshot({ path: '/work/tmp/browser-check/terminal.png' });
    console.log('# board files:', await page.evaluate(() => Object.keys(window.__board.shell.files).map((k) => k + ' (' + window.__board.shell.files[k].length + ' bytes)').join(', ')), '| ran:', await page.evaluate(() => window.__board.shell.ran.join(' ')));
    await page.click('#device-install');
    await page.waitForFunction(() => document.getElementById('status').textContent.includes('電源を入れるたび'), null, { timeout: 15000 })
      .catch(() => console.log('# install did not finish'));
    console.log('# install:', await page.textContent('#status'));
    console.log('# board files:', await page.evaluate(() => Object.keys(window.__board.shell.files).join(', ')), '| ran:', await page.evaluate(() => window.__board.shell.ran.join(' ')));
    await page.evaluate(() => { window.__board.shell.written = []; });
    await page.click('#device-reboot');
    const t0 = Date.now();
    const ok = await page.waitForFunction(() => document.getElementById('status').textContent.includes('つなぎ直しました'), null, { timeout: 45000 })
      .then(() => true).catch(() => false);
    console.log(`# reconnected: ${ok} after ${((Date.now() - t0) / 1000).toFixed(1)} s`);
    console.log('# status:', await page.textContent('#status'));
    console.log('# board events:', await page.evaluate(() => window.__board.events.join(' ')));
    console.log('# shell was sent:', JSON.stringify(await page.evaluate(() => window.__board.shell.written.join(''))).slice(0, 200));
    await page.waitForTimeout(3000);
    console.log('# midi was sent:', JSON.stringify(await page.evaluate(() => window.__board.midi.written.join(''))));
    console.log('# terminal:');
    (await termText(page)).split('\n').filter((l) => l.trim()).forEach((l) => console.log('   ' + l));
    if (ok) {
      await page.evaluate(() => { window.__board.shell.written = []; window.__board.midi.written = []; });
      await page.click('#device-reboot');
      await page.waitForFunction(() => document.getElementById('status').textContent.includes('切れました'), null, { timeout: 15000 });
      const t1 = Date.now();
      const ok2 = await page.waitForFunction(() => document.getElementById('status').textContent.includes('つなぎ直しました'), null, { timeout: 45000 })
        .then(() => true).catch(() => false);
      console.log(`# second restart, reconnected: ${ok2} after ${((Date.now() - t1) / 1000).toFixed(1)} s; midi got ${JSON.stringify(await page.evaluate(() => window.__board.midi.written.join('')))}`);
      await page.click('#device-connect');   // now "disconnect"
      await page.waitForTimeout(500);
      console.log('# after disconnect:', await page.textContent('#status'), '| button:', await page.textContent('#device-connect'));
    }
    const errs = console_.filter((l) => l.startsWith('[error]') || l.startsWith('[pageerror]'));
    console.log('# console errors:', errs.length ? '' : '(none)'); errs.forEach((l) => console.log('   ' + l));
    await page.close();
  }
  await browser.close();
  server.close();
})();
