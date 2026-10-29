// Runs a bundle's entry module in headless Chrome and prints its console.log lines as node would.
//
//   node runPage.mjs <dir> <entry.mjs> [--timeout-ms N]
//
// <dir> is served on a free localhost port; <entry.mjs> is a path inside it. The page imports the
// entry, then signals done; an uncaught error or a timeout prints FAIL on stderr and exits 1.
// CHROME overrides the Chrome path. Console-only: the page gets no GPU (--disable-gpu).
import { spawn } from 'node:child_process';
import { createServer } from 'node:http';
import { mkdtempSync, readFileSync, rmSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { extname, join, resolve, sep } from 'node:path';

const types = {
	'.html': 'text/html', '.js': 'text/javascript', '.mjs': 'text/javascript', '.wasm': 'application/wasm',
	'.json': 'application/json', '.css': 'text/css', '.png': 'image/png', '.txt': 'text/plain',
};

const pageScript = (entry) => `
const show = (v) => typeof v === 'string' ? v
	: typeof v === 'bigint' ? v + 'n'
	: Object.is(v, -0) ? '-0'
	: v !== null && typeof v === 'object' ? (() => { try { return JSON.stringify(v); } catch { return String(v); } })()
	: String(v);
console.log = (...args) => window.__wasmmixLine(args.map(show).join(' '));
window.addEventListener('error', (e) => window.__wasmmixError(String(e.error?.stack ?? e.message)));
window.addEventListener('unhandledrejection', (e) => window.__wasmmixError(String(e.reason?.stack ?? e.reason)));
try {
	await import(${JSON.stringify('./' + entry)});
	window.__wasmmixDone = true;
} catch (e) {
	window.__wasmmixError(String(e?.stack ?? e));
}
`;

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

export async function runPage(dir, entry, timeoutMs = 30000) {
	const root = resolve(dir);
	const server = createServer((req, res) => {
		const path = decodeURIComponent(new URL(req.url, 'http://x').pathname);
		if (path === '/__wasmmix.html') {
			res.writeHead(200, { 'content-type': 'text/html' });
			res.end(`<!doctype html><meta charset="utf-8"><script type="module">${pageScript(entry)}</script>`);
			return;
		}
		const file = resolve(root, '.' + path);
		if (!file.startsWith(root + sep) || !statSync(file, { throwIfNoEntry: false })?.isFile()) {
			res.writeHead(404).end();
			return;
		}
		res.writeHead(200, { 'content-type': types[extname(file)] ?? 'application/octet-stream' });
		res.end(readFileSync(file));
	});
	await new Promise((r) => server.listen(0, '127.0.0.1', r));
	const profile = mkdtempSync(join(tmpdir(), 'wasmmix-page-'));
	const chrome = process.env.CHROME || 'C:/Program Files/Google/Chrome/Application/chrome.exe';
	const browser = spawn(chrome, [
		'--headless=new', '--disable-gpu', '--remote-debugging-port=0', `--user-data-dir=${profile}`,
		'--no-first-run', 'about:blank',
	], { stdio: 'ignore' });
	const lines = [];
	let error = null;
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
		ws.onmessage = (event) => {
			const msg = JSON.parse(event.data);
			if (msg.id && pending.has(msg.id)) { pending.get(msg.id)(msg); pending.delete(msg.id); }
			else if (msg.method === 'Runtime.bindingCalled') {
				if (msg.params.name === '__wasmmixLine') lines.push(msg.params.payload);
				else error ??= msg.params.payload;
			} else if (msg.method === 'Runtime.exceptionThrown') {
				const d = msg.params.exceptionDetails;
				error ??= d.exception?.description ?? d.text;
			}
		};
		const send = (method, params = {}) => new Promise((r) => {
			const id = next++;
			pending.set(id, r);
			ws.send(JSON.stringify({ id, method, params }));
		});
		await new Promise((r, j) => { ws.onopen = r; ws.onerror = j; });
		await send('Runtime.enable');
		await send('Runtime.addBinding', { name: '__wasmmixLine' });
		await send('Runtime.addBinding', { name: '__wasmmixError' });
		await send('Page.navigate', { url: `http://127.0.0.1:${server.address().port}/__wasmmix.html` });
		let done = false;
		for (let waited = 0; waited < timeoutMs && !done && error === null; waited += 50) {
			await sleep(50);
			done = (await send('Runtime.evaluate', { expression: 'window.__wasmmixDone === true', returnByValue: true })).result?.result?.value === true;
		}
		if (error === null && !done) error = `timeout after ${timeoutMs} ms without __wasmmixDone`;
		await send('Browser.close');
		ws.close();
	} catch (e) {
		error ??= e.message;
	} finally {
		browser.kill();
		await new Promise((r) => (browser.exitCode === null ? browser.once('exit', r) : r()));
		server.close();
		rmSync(profile, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
	}
	return { lines, error };
}

const [dir, entry, ...rest] = process.argv.slice(2);
if (!dir || !entry) {
	console.error('usage: node runPage.mjs <dir> <entry.mjs> [--timeout-ms N]');
	process.exit(2);
}
const at = rest.indexOf('--timeout-ms');
const { lines, error } = await runPage(dir, entry, at >= 0 ? Number(rest[at + 1]) : 30000);
for (const line of lines) console.log(line);
if (error !== null) {
	console.error(`FAIL  ${entry}: ${error}`);
	process.exitCode = 1;
}
