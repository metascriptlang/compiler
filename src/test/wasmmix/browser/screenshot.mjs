// Opens a page in headless Chrome, waits for the page to set window[signal] = true, and writes a
// Page.captureScreenshot PNG of the viewport.
//
//   node screenshot.mjs <url> <png> [--frame-signal name] [--timeout-ms N]
//
// The signal defaults to __wasmmixFrame. Chrome keeps its GPU, so a WebGL or WebGPU page is a GPU
// run: do it in a quiet window. CHROME overrides the Chrome path.
import { spawn } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const args = process.argv.slice(2);
const option = (name, fallback) => {
	const at = args.indexOf(name);
	return at < 0 ? fallback : args.splice(at, 2)[1];
};
const signal = option('--frame-signal', '__wasmmixFrame');
const timeoutMs = Number(option('--timeout-ms', 30000));
const [url, png] = args;
if (!url || !png) {
	console.error('usage: node screenshot.mjs <url> <png> [--frame-signal name] [--timeout-ms N]');
	process.exit(2);
}

const profile = mkdtempSync(join(tmpdir(), 'wasmmix-shot-'));
const browser = spawn(process.env.CHROME || 'C:/Program Files/Google/Chrome/Application/chrome.exe', [
	'--headless=new', '--remote-debugging-port=0', `--user-data-dir=${profile}`,
	'--force-device-scale-factor=1', '--window-size=800,600', '--no-first-run', 'about:blank',
], { stdio: 'ignore' });
try {
	let port = null;
	for (let i = 0; i < 200 && port === null; i++) {
		try { port = Number(readFileSync(join(profile, 'DevToolsActivePort'), 'utf8').split('\n')[0]); } catch { await sleep(100); }
	}
	if (port === null) throw new Error('Chrome did not open its DevTools port');
	let page = null;
	for (let i = 0; i < 100 && page === null; i++) {
		try { page = (await (await fetch(`http://127.0.0.1:${port}/json/list`)).json()).find((t) => t.type === 'page') ?? null; } catch {}
		if (page === null) await sleep(100);
	}
	if (page === null) throw new Error('Chrome has no page target');
	const ws = new WebSocket(page.webSocketDebuggerUrl);
	let next = 1;
	const pending = new Map();
	let exception = null;
	ws.onmessage = (event) => {
		const msg = JSON.parse(event.data);
		if (msg.id && pending.has(msg.id)) { pending.get(msg.id)(msg); pending.delete(msg.id); }
		else if (msg.method === 'Runtime.exceptionThrown') exception ??= msg.params.exceptionDetails.exception?.description ?? msg.params.exceptionDetails.text;
	};
	const send = (method, params = {}) => new Promise((r) => {
		const id = next++;
		pending.set(id, r);
		ws.send(JSON.stringify({ id, method, params }));
	});
	await new Promise((r, j) => { ws.onopen = r; ws.onerror = j; });
	await send('Runtime.enable');
	await send('Page.enable');
	await send('Page.navigate', { url });
	let ready = false;
	for (let waited = 0; waited < timeoutMs && !ready && exception === null; waited += 50) {
		await sleep(50);
		ready = (await send('Runtime.evaluate', { expression: `window[${JSON.stringify(signal)}] === true`, returnByValue: true })).result?.result?.value === true;
	}
	if (exception !== null) throw new Error(exception);
	if (!ready) throw new Error(`window.${signal} not set within ${timeoutMs} ms`);
	const shot = await send('Page.captureScreenshot', { format: 'png' });
	writeFileSync(png, Buffer.from(shot.result.data, 'base64'));
	await send('Browser.close');
	ws.close();
	console.log(`wrote ${png}`);
} catch (e) {
	console.error(`FAIL  ${url}: ${e.message}`);
	process.exitCode = 1;
} finally {
	browser.kill();
	await new Promise((r) => (browser.exitCode === null ? browser.once('exit', r) : r()));
	rmSync(profile, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
}
