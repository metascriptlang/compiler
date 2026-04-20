// msc login / msc logout — GitHub device-flow OAuth + registry token.
//
// Device flow (RFC 8628):
// 1. POST github.com/login/device/code → device_code + user_code + verification_uri
// 2. Display user_code + URL to user
// 3. Poll github.com/login/oauth/access_token every <interval> seconds
// 4. Exchange GitHub token for registry token via POST /auth/github/token
// 5. Store registry token at ~/.metascript/credentials

import { exists, readFile, writeFile, chmod } from "std/fs";
import { env } from "std/process";
import { join } from "std/fs/path";
import { HttpResponse } from "std/http/types";
import { HttpError } from "std/http/errors";
import { createHeaders, setHeader } from "std/http/headers";

const GITHUB_CLIENT_ID = "Ov23liXkaph4TDPP19yd";
const REGISTRY_HOST = "api.metascriptlang.org";
const API_BASE = "https://" + REGISTRY_HOST;

function credentialsPath(): string {
	const home = env.get("HOME");
	if (home === "") return "";
	return join(join(home, ".metascript"), "credentials");
}

export function loadToken(): string {
	const path = credentialsPath();
	if (path === "" || !exists(path)) return "";
	const content = try readFile(path) catch "";
	return content.trim();
}

export function saveToken(token: string): boolean {
	const path = credentialsPath();
	if (path === "") return false;
	const result = writeFile(path, token + "\n");
	if (!result.ok) return false;
	// Tighten perms to 0600 (owner rw only) — 384 decimal.
	// Spec (docs/PACKAGE.md §File locations) requires mode 0600 on
	// ~/.metascript/credentials. No-op on Windows.
	chmod(path, 384 as int32);
	return true;
}

export function deleteToken(): boolean {
	const path = credentialsPath();
	if (path === "" || !exists(path)) return true;
	const result = writeFile(path, "");
	return result.ok;
}

// Parse a URL-encoded key=value pair from a &-separated response.
function parseUrlEncoded(response: string, key: string): string {
	let pos = 0;
	while (pos < response.length) {
		// Find next &
		let end = pos;
		while (end < response.length && response.charAt(end) !== "&") end = end + 1;

		const pair = response.slice(pos, end);
		// Find = in this pair
		let eq = 0;
		while (eq < pair.length && pair.charAt(eq) !== "=") eq = eq + 1;
		if (eq < pair.length) {
			const k = pair.slice(0, eq);
			const v = pair.slice(eq + 1, pair.length);
			if (k === key) return v;
		}
		pos = end + 1;
	}
	return "";
}

// Simple percent-decode for verification_uri (%3A → :, %2F → /)
function percentDecode(s: string): string {
	let result = "";
	let i = 0;
	while (i < s.length) {
		if (s.charAt(i) === "%" && i + 2 < s.length) {
			const hi = s.charAt(i + 1);
			const lo = s.charAt(i + 2);
			if (hi === "3" && lo === "A") { result = result + ":"; i = i + 3; }
			else if (hi === "2" && lo === "F") { result = result + "/"; i = i + 3; }
			else if (hi === "3" && lo === "D") { result = result + "="; i = i + 3; }
			else if (hi === "2" && lo === "6") { result = result + "&"; i = i + 3; }
			else { result = result + s.charAt(i); i = i + 1; }
		} else {
			result = result + s.charAt(i);
			i = i + 1;
		}
	}
	return result;
}

import { extractJsonField } from "./json";

// HTTPS POST — uses fetch() with auto TLS from URL.
function httpsPost(host: string, path: string, body: string, contentType: string): Result<HttpResponse, HttpError> {
	const headers = createHeaders();
	setHeader(headers, "content-type", contentType);
	return fetch("https://" + host + path, {
		method: "POST",
		body: body,
		headers: headers,
		timeout: 30000,
		maxRedirects: 0,
	});
}

// Busy-wait sleep (ms). Works in both Bun and compiled binary.
function sleepMs(ms: number): void {
	const start = performance.now();
	while (performance.now() - start < ms) {
		// busy wait
	}
}

export function cmdLogin(projectRoot: string): boolean {
	const _pr = projectRoot;
	const existing = loadToken();
	if (existing !== "") {
		console.log("already logged in (token at ~/.metascript/credentials)");
		console.log("run `msc logout` first to re-authenticate");
		return true;
	}

	console.log("MetaScript Registry Login");
	console.log("");

	// Step 1: Request device code from GitHub
	console.log("Requesting device code from GitHub...");
	const deviceBody = "client_id=" + GITHUB_CLIENT_ID + "&scope=read:user";
	const deviceResult = httpsPost("github.com", "/login/device/code", deviceBody, "application/x-www-form-urlencoded");

	if (!deviceResult.ok) {
		console.log("error: failed to connect to GitHub: " + deviceResult.error.message);
		return false;
	}

	const deviceResp = deviceResult.value;
	if (deviceResp.status !== 200) {
		console.log(`error: GitHub returned HTTP ${deviceResp.status}`);
		return false;
	}

	const deviceCode = parseUrlEncoded(deviceResp.body, "device_code");
	const userCode = parseUrlEncoded(deviceResp.body, "user_code");
	const verificationUri = percentDecode(parseUrlEncoded(deviceResp.body, "verification_uri"));
	let interval = 5;
	const intervalStr = parseUrlEncoded(deviceResp.body, "interval");
	if (intervalStr !== "") interval = 8; // conservative default

	if (deviceCode === "" || userCode === "") {
		console.log("error: invalid response from GitHub");
		console.log(deviceResp.body);
		return false;
	}

	// Step 2: Display instructions
	console.log("");
	console.log("1. Open this URL in your browser:");
	const uri = verificationUri !== "" ? verificationUri : "https://github.com/login/device";
	console.log(`   ${uri}`);
	console.log("");
	console.log("2. Enter this code:");
	console.log(`   ${userCode}`);
	console.log("");
	console.log("Waiting for authorization...");

	// Step 3: Poll for access token
	let attempts = 0;
	const maxAttempts = 60;
	let githubToken = "";

	while (attempts < maxAttempts && githubToken === "") {
		sleepMs(interval * 1000);

		const pollBody = "client_id=" + GITHUB_CLIENT_ID + "&device_code=" + deviceCode + "&grant_type=urn:ietf:params:oauth:grant-type:device_code";
		const pollResult = httpsPost("github.com", "/login/oauth/access_token", pollBody, "application/x-www-form-urlencoded");

		if (pollResult.ok && pollResult.value.status === 200) {
			const body = pollResult.value.body;
			const token = parseUrlEncoded(body, "access_token");
			if (token !== "") {
				githubToken = token;
			} else {
				const err = parseUrlEncoded(body, "error");
				if (err === "slow_down") { interval = interval + 5; }
				else if (err === "expired_token") {
					console.log("\nerror: device code expired — please try again");
					return false;
				} else if (err === "access_denied") {
					console.log("\nerror: authorization denied");
					return false;
				}
				// authorization_pending — keep polling
			}
		}
		attempts = attempts + 1;
	}

	if (githubToken === "") {
		console.log("\nerror: timed out waiting for authorization");
		return false;
	}

	console.log("\nGitHub authorized! Exchanging for registry token...");

	// Step 4: Exchange GitHub token for registry token
	const authBody = "{\"github_token\":\"" + githubToken + "\"}";
	const authResult = httpsPost(REGISTRY_HOST, "/auth/github/token", authBody, "application/json");

	if (!authResult.ok) {
		console.log("error: failed to connect to registry");
		return false;
	}

	if (authResult.value.status !== 200) {
		console.log(`error: registry returned HTTP ${authResult.value.status}`);
		return false;
	}

	const registryToken = extractJsonField(authResult.value.body, "token");
	const username = extractJsonField(authResult.value.body, "username");

	if (registryToken === "") {
		console.log("error: invalid response from registry");
		return false;
	}

	// Step 5: Store token
	const saved = saveToken(registryToken);
	if (!saved) {
		console.log("error: failed to save credentials");
		return false;
	}

	const user = username !== "" ? username : "unknown";
	console.log(`\nLogged in as @${user}`);
	console.log("You can now publish packages with `msc publish`");
	return true;
}

export function cmdLogout(): boolean {
	const existing = loadToken();
	if (existing === "") {
		console.log("not logged in");
		return true;
	}

	// Step 1: Try to revoke server-side. Ask /auth/me for the token id, then
	// DELETE /auth/tokens/:id. If the network is unreachable or the token is
	// already rejected, we still fall through to truncate the local file —
	// the credentials file is the authoritative ticket, server revoke is an
	// additional guarantee.
	const meHeaders = createHeaders();
	setHeader(meHeaders, "authorization", "Bearer " + existing);
	const meResult = fetch(API_BASE + "/auth/me", {
		method: "GET",
		body: "",
		headers: meHeaders,
		timeout: 30000,
		maxRedirects: 5,
	});

	let revoked = false;
	if (meResult.ok && meResult.value.status === 200) {
		const tokenId = extractJsonField(meResult.value.body, "tokenId");
		if (tokenId !== "") {
			const delHeaders = createHeaders();
			setHeader(delHeaders, "authorization", "Bearer " + existing);
			const delResult = fetch(API_BASE + "/auth/tokens/" + tokenId, {
				method: "DELETE",
				body: "",
				headers: delHeaders,
				timeout: 30000,
				maxRedirects: 0,
			});
			if (delResult.ok && delResult.value.status >= 200 && delResult.value.status < 300) {
				revoked = true;
			}
		}
	}

	// Step 2: Always truncate local credentials, even if server revoke failed.
	const ok = deleteToken();
	if (!ok) {
		console.log("error: failed to remove credentials");
		return false;
	}

	if (revoked) {
		console.log("logged out (token revoked server-side and removed locally)");
	} else {
		console.log("logged out (token removed locally)");
		console.log("warning: could not revoke server-side — the token will remain valid until it expires (90 days)");
	}
	return true;
}

// msc whoami — verify the stored token against the registry and print the user.
//
// Exit behavior (matches npm/pnpm whoami):
//   0 → authenticated (prints "username" or JSON user object)
//   1 → not logged in, or token rejected/expired, or network error
//
// Flags:
//   --json    Print the full user object instead of just the username.
export function cmdWhoami(args: string[]): boolean {
	const token = loadToken();
	if (token === "") {
		console.log("not logged in");
		console.log("run `msc login` to authenticate");
		return false;
	}

	let jsonOutput = false;
	let i = 0;
	while (i < args.length) {
		if (args[i] === "--json") jsonOutput = true;
		i = i + 1;
	}

	const headers = createHeaders();
	setHeader(headers, "authorization", "Bearer " + token);
	const result = fetch(API_BASE + "/auth/me", {
		method: "GET",
		body: "",
		headers: headers,
		timeout: 30000,
		maxRedirects: 5,
	});

	if (!result.ok) {
		console.log("error: couldn't reach registry: " + result.error.message);
		return false;
	}

	if (result.value.status === 401) {
		console.log("error: token rejected by registry (expired or revoked)");
		console.log("run `msc login` to re-authenticate");
		return false;
	}

	if (result.value.status !== 200) {
		console.log("error: registry returned HTTP " + result.value.status.toString());
		return false;
	}

	// Response shape: { "user": { "username", "displayName", "avatarUrl", "githubUrl" } }
	// We hand-parse with extractJsonField since /me is a flat string-only object.
	const body = result.value.body;
	if (jsonOutput) {
		// Echo the user object verbatim — trim surrounding envelope.
		const userStart = body.indexOf("\"user\":");
		if (userStart < 0) { console.log(body); return true; }
		let depth = 0;
		let objStart = -1;
		let j = userStart;
		while (j < body.length) {
			const ch = body.charAt(j);
			if (ch === "{") {
				if (objStart < 0) objStart = j;
				depth = depth + 1;
			} else if (ch === "}") {
				depth = depth - 1;
				if (depth === 0) {
					console.log(body.slice(objStart, j + 1));
					return true;
				}
			}
			j = j + 1;
		}
		console.log(body);
		return true;
	}

	const username = extractJsonField(body, "username");
	if (username === "") {
		console.log("error: unexpected response from registry");
		return false;
	}
	console.log(username);
	return true;
}
