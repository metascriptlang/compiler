// msc publish — publish a package to the registry.
//
// Pipeline: load & validate → walk files → zip → multipart → POST.
// All size gates are enforced client-side so we fail fast instead of
// uploading bytes just to get 413'd.
//
// Flags:
//   --dry-run    Build the archive, print the file list, exit without uploading.

import { exists, readFile } from "std/fs";
import { join } from "std/fs/path";
import { loadBuildConfig, PackageSection } from "../buildConfig";
import { loadToken } from "./login";
import { collectPublishFiles } from "./walker";
import { newZipWriter, zipAdd, zipFinalize, closeZipWriter, ZipWriter } from "std/compress/zip";
import { buildMultipart, MultipartPart, boundaryCollides } from "std/http/multipart";
import { createHeaders, setHeader } from "std/http/headers";
import { error as errStyle, bold, green, cyan, dim } from "../../utils/color";
import { registryBaseUrl } from "./registry";

const PUBLISH_API_BASE = registryBaseUrl();

// Server hard limits — mirror these client-side so the user gets a clear
// error before we try to upload.
const MAX_FILES: number = 10000;
const MAX_UNCOMPRESSED: number = 100 * 1024 * 1024;   // 100 MB
const MAX_COMPRESSED: number = 50 * 1024 * 1024;       // 50 MB

// Server version regex requires plain semver without leading "v".
function stripVPrefix(v: string): string {
	if (v.length > 0 && (v.charAt(0) === "v" || v.charAt(0) === "V")) {
		return v.slice(1, v.length);
	}
	return v;
}

// Human-readable size (bytes → "42.1 MB" style).
function humanSize(bytes: number): string {
	if (bytes < 1024) return bytes.toString() + " B";
	if (bytes < 1024 * 1024) {
		const kb = bytes / 1024;
		return roundTo1(kb) + " KB";
	}
	if (bytes < 1024 * 1024 * 1024) {
		const mb = bytes / (1024 * 1024);
		return roundTo1(mb) + " MB";
	}
	const gb = bytes / (1024 * 1024 * 1024);
	return roundTo1(gb) + " GB";
}

function roundTo1(x: number): string {
	// Round to 1 decimal place — MetaScript has no Math.round, so use
	// manual floor-based rounding: scaled + 0.5 then truncate. Always emits
	// the decimal digit (e.g. "1.0" not "1") for consistency.
	const scaled = x * 10 + 0.5;
	const rounded = scaled - scaled % 1;
	const whole = (rounded - rounded % 10) / 10;
	const frac = rounded - whole * 10;
	return whole.toString() + "." + frac.toString();
}

// Build manifest.json — the machine-readable package descriptor included in
// every published archive. Contains the same fields as the metadata multipart
// field. The server cross-validates this against the metadata field to catch
// tampering, and tooling can read it offline without a MetaScript parser.
function buildManifestJson(pkg: PackageSection, version: string): string {
	return buildMetadataJson(pkg, version);
}

// Build the full metadata JSON that goes in the `metadata` multipart part.
// Only emits fields that are non-empty (matches server Zod schema's optional
// fields). The server will reject extras via Zod — keep field set minimal.
function buildMetadataJson(pkg: PackageSection, version: string): string {
	let out = "{";
	out = out + "\"name\":" + jsonEscape(pkg.name);
	out = out + ",\"version\":" + jsonEscape(version);
	if (pkg.description.length > 0) out = out + ",\"description\":" + jsonEscape(pkg.description);
	if (pkg.license.length > 0) out = out + ",\"license\":" + jsonEscape(pkg.license);
	if (pkg.repository.length > 0) out = out + ",\"repository\":" + jsonEscape(pkg.repository);
	if (pkg.homepage.length > 0) out = out + ",\"homepage\":" + jsonEscape(pkg.homepage);
	if (pkg.keywords.length > 0) {
		out = out + ",\"keywords\":[";
		let i = 0;
		while (i < pkg.keywords.length) {
			if (i > 0) out = out + ",";
			out = out + jsonEscape(pkg.keywords[i]);
			i = i + 1;
		}
		out = out + "]";
	}
	out = out + "}";
	return out;
}

// JSON-encode a string value with surrounding double quotes. Only escapes
// the minimal required characters.
function jsonEscape(s: string): string {
	let out = "\"";
	let i = 0;
	while (i < s.length) {
		const ch = s.charAt(i);
		const code = s.charCodeAt(i);
		if (ch === "\\") { out = out + "\\\\"; }
		else if (ch === "\"") { out = out + "\\\""; }
		else if (ch === "\n") { out = out + "\\n"; }
		else if (ch === "\r") { out = out + "\\r"; }
		else if (ch === "\t") { out = out + "\\t"; }
		else if (code < 32) {
			// Other control chars → \u00XX
			out = out + "\\u00" + hexByte(code);
		} else {
			out = out + ch;
		}
		i = i + 1;
	}
	out = out + "\"";
	return out;
}

function hexByte(b: number): string {
	const hi = (b - b % 16) / 16;
	const lo = b % 16;
	return hexDigit(hi) + hexDigit(lo);
}

function hexDigit(d: number): string {
	return match (d) {
		0 => "0", 1 => "1", 2 => "2", 3 => "3",
		4 => "4", 5 => "5", 6 => "6", 7 => "7",
		8 => "8", 9 => "9", 10 => "a", 11 => "b",
		12 => "c", 13 => "d", 14 => "e", _ => "f",
	};
}

import { extractJsonField } from "./json";

export function cmdPublish(projectRoot: string, args: string[]): boolean {
	// --- Parse flags ---
	let dryRun = false;
	let k = 0;
	while (k < args.length) {
		if (args[k] === "--dry-run") dryRun = true;
		k = k + 1;
	}

	// --- Load & validate build.ms ---
	const buildPath = join(projectRoot, "build.ms");
	if (!exists(buildPath)) {
		console.log(`${errStyle("error")}: no ${bold("build.ms")} found in project root`);
		return false;
	}
	const cfg = loadBuildConfig(buildPath, false);
	if (!cfg.valid) {
		console.log(`${errStyle("error")}: failed to parse build.ms`);
		return false;
	}
	if (!cfg.package.valid) {
		console.log(`${errStyle("error")}: build.ms must have a ${cyan("package")} section with at least ${cyan("name")}`);
		console.log("example:");
		console.log("  package: { name: \"my-lib\", version: \"1.0.0\" },");
		return false;
	}
	if (cfg.package.version === "") {
		console.log(`${errStyle("error")}: ${cyan("package.version")} is required for publishing`);
		return false;
	}

	const version = stripVPrefix(cfg.package.version);
	const name = cfg.package.name;

	// --- Check token (unless --dry-run) ---
	const token = loadToken();
	if (!dryRun && token === "") {
		console.log(`${errStyle("error")}: not logged in`);
		console.log(`run ${cyan("msc login")} first to authenticate`);
		return false;
	}

	// --- Walk files ---
	const walk = collectPublishFiles(projectRoot, cfg.package.files, cfg.package.ignore);
	if (walk.errors.length > 0) {
		for (const e of walk.errors) {
			console.log(`${errStyle("error")}: ${e}`);
		}
		return false;
	}
	if (walk.files.length === 0) {
		console.log(`${errStyle("error")}: no files selected for publishing`);
		console.log(`check ${cyan("package.files")} and ${cyan("package.ignore")} in build.ms`);
		return false;
	}

	// --- Client-side size gates #1: file count & uncompressed total ---
	if (walk.files.length > MAX_FILES) {
		console.log(`${errStyle("error")}: too many files (${walk.files.length.toString()}), max is ${MAX_FILES.toString()}`);
		return false;
	}
	let uncompressedTotal = 0;
	let i = 0;
	while (i < walk.files.length) {
		uncompressedTotal = uncompressedTotal + walk.files[i].size;
		i = i + 1;
	}
	if (uncompressedTotal > MAX_UNCOMPRESSED) {
		console.log(`${errStyle("error")}: uncompressed size (${humanSize(uncompressedTotal)}) exceeds limit (${humanSize(MAX_UNCOMPRESSED)})`);
		return false;
	}

	// --- Build zip archive ---
	const writerR = newZipWriter();
	if (!writerR.ok) {
		console.log(`${errStyle("error")}: failed to create zip writer: ${writerR.error.message}`);
		return false;
	}
	const writer: ZipWriter = writerR.value;

	i = 0;
	while (i < walk.files.length) {
		const f = walk.files[i];
		i = i + 1;
		const contentR = readFile(f.absPath);
		if (!contentR.ok) {
			closeZipWriter(writer);
			console.log(`${errStyle("error")}: failed to read ${f.relPath}: ${contentR.error.message}`);
			return false;
		}
		const addR = zipAdd(writer, "package/" + f.relPath, contentR.value, 6);
		if (!addR.ok) {
			closeZipWriter(writer);
			console.log(`${errStyle("error")}: zip failed for ${f.relPath}: ${addR.error.message}`);
			return false;
		}
	}

	// Add manifest.json — machine-readable package descriptor. Server validates
	// its presence and cross-checks against the metadata multipart field.
	const manifestJson = buildManifestJson(cfg.package, version);
	const manifestR = zipAdd(writer, "package/manifest.json", manifestJson, 6);
	if (!manifestR.ok) {
		closeZipWriter(writer);
		console.log(`${errStyle("error")}: zip failed for manifest.json: ${manifestR.error.message}`);
		return false;
	}

	// Finalize and get the archive bytes.
	const zipR = zipFinalize(writer);
	closeZipWriter(writer);
	if (!zipR.ok) {
		console.log(`${errStyle("error")}: zip finalize failed: ${zipR.error.message}`);
		return false;
	}
	const zipBytes = zipR.value;

	// --- Client-side size gate #2: compressed ---
	if (zipBytes.byteLength > MAX_COMPRESSED) {
		console.log(`${errStyle("error")}: archive size (${humanSize(zipBytes.byteLength)}) exceeds limit (${humanSize(MAX_COMPRESSED)})`);
		return false;
	}

	// --- Print plan ---
	console.log(`${bold("Publishing")} ${cyan(name)}@${cyan(version)}`);
	console.log(`  files:      ${walk.files.length.toString()}`);
	console.log(`  size:       ${humanSize(zipBytes.byteLength)} compressed, ${humanSize(uncompressedTotal)} uncompressed`);

	if (dryRun) {
		console.log("");
		console.log(`${bold("Files")} (dry run — not uploading):`);
		for (const f of walk.files) {
			console.log(`  ${f.relPath}  ${dim("(" + humanSize(f.size) + ")")}`);
		}
		return true;
	}

	// --- Build multipart body ---
	// Generate a boundary from performance.now() + file count + compressed size. Not
	// crypto-random — it only needs to not collide with the part bodies, and
	// the content-dependent mix makes collisions effectively impossible in
	// practice (any collision would mean the same exact ASCII sequence
	// appeared inside the zip archive). `boundaryCollides` below is the
	// safety net regardless.
	const boundary = "msc-" + performance.now().toString() + "-" + walk.files.length.toString() + "-" + zipBytes.byteLength.toString();

	const metadataJson = buildMetadataJson(cfg.package, version);
	const parts: MultipartPart[] = [
		{ name: "metadata", filename: "", contentType: "application/json", body: metadataJson },
		{ name: "archive",  filename: name + "-" + version + ".zip",
		  contentType: "application/zip", body: zipBytes },
	];

	// Sanity: verify the boundary doesn't collide with any part body (essentially
	// impossible for 16 random bytes but the check is O(n) on each body).
	if (boundaryCollides(parts, boundary)) {
		console.log(`${errStyle("error")}: boundary collision — please retry`);
		return false;
	}
	const mp = buildMultipart(parts, boundary);

	// --- POST to registry ---
	const headers = createHeaders();
	setHeader(headers, "authorization", "Bearer " + token);
	setHeader(headers, "content-type", mp.contentType);
	const postR = fetch(PUBLISH_API_BASE + "/packages", {
		method: "POST",
		body: mp.body,
		headers: headers,
		timeout: 120000, // 2 minutes for the full upload
		maxRedirects: 0,
	});
	if (!postR.ok) {
		console.log(`${errStyle("error")}: failed to reach registry: ${postR.error.message}`);
		return false;
	}
	const resp = postR.value;

	// --- Parse response ---
	if (resp.status === 201) {
		const publishedVer = extractJsonField(resp.body, "version");
		const tarUrl = extractJsonField(resp.body, "archiveUrl");
		const srvIntegrity = extractJsonField(resp.body, "integrity");
		const showVer = publishedVer !== "" ? publishedVer : version;
		console.log("");
		console.log(`${green("+ published")} ${cyan(name)}@${cyan(showVer)}`);
		if (tarUrl !== "") console.log(`  url:       ${dim(tarUrl)}`);
		if (srvIntegrity !== "") console.log(`  integrity: ${dim(srvIntegrity)}`);
		return true;
	}

	// Error path — surface whatever the server said.
	const serverError = extractJsonField(resp.body, "error");
	const hint = serverError !== "" ? serverError : resp.body;
	match (resp.status) {
		401 => {
			console.log(`${errStyle("error")}: token rejected by registry (expired or revoked)`);
			console.log(`run ${cyan("msc login")} to re-authenticate`);
		},
		403 => { console.log(`${errStyle("error")}: not authorized to publish ${cyan(name)} — you are not the owner`); },
		409 => { console.log(`${errStyle("error")}: version ${cyan(version)} already exists — bump ${cyan("package.version")} and retry`); },
		413 => { console.log(`${errStyle("error")}: registry rejected upload as too large`); },
		429 => { console.log(`${errStyle("error")}: rate limit exceeded — wait a few minutes and retry`); },
		400 => { console.log(`${errStyle("error")}: registry rejected metadata: ${hint}`); },
		_ => { console.log(`${errStyle("error")}: registry returned HTTP ${resp.status.toString()}: ${hint}`); },
	};
	return false;
}

// ===== Tests =====

test "stripVPrefix" {
	assert stripVPrefix("v1.2.3") === "1.2.3";
	assert stripVPrefix("V1.2.3") === "1.2.3";
	assert stripVPrefix("1.2.3") === "1.2.3";
	assert stripVPrefix("") === "";
}

test "humanSize formatting" {
	assert humanSize(0) === "0 B";
	assert humanSize(500) === "500 B";
	assert humanSize(1024) === "1.0 KB";
	assert humanSize(1536) === "1.5 KB";
	assert humanSize(1024 * 1024) === "1.0 MB";
	assert humanSize(10 * 1024 * 1024) === "10.0 MB";
}

test "hexByte" {
	assert hexByte(0) === "00";
	assert hexByte(15) === "0f";
	assert hexByte(16) === "10";
	assert hexByte(255) === "ff";
}

test "jsonEscape basic" {
	assert jsonEscape("hello") === "\"hello\"";
	assert jsonEscape("a\"b") === "\"a\\\"b\"";
	assert jsonEscape("line1\nline2") === "\"line1\\nline2\"";
	assert jsonEscape("back\\slash") === "\"back\\\\slash\"";
}

test "buildMetadataJson minimal" {
	const pkg: PackageSection = {
		name: "cool-json",
		version: "1.0.0",
		description: "",
		license: "",
		repository: "",
		homepage: "",
		keywords: [],
		author: "",
		files: [],
		ignore: [],
		valid: true,
	};
	const js = buildMetadataJson(pkg, "1.0.0");
	assert js === "{\"name\":\"cool-json\",\"version\":\"1.0.0\"}";
}

test "buildMetadataJson with optionals" {
	const pkg: PackageSection = {
		name: "x",
		version: "0.1.0",
		description: "A thing",
		license: "MIT",
		repository: "",
		homepage: "",
		keywords: ["a", "b"],
		author: "",
		files: [],
		ignore: [],
		valid: true,
	};
	const js = buildMetadataJson(pkg, "0.1.0");
	assert js === "{\"name\":\"x\",\"version\":\"0.1.0\",\"description\":\"A thing\",\"license\":\"MIT\",\"keywords\":[\"a\",\"b\"]}";
}

test "buildManifestJson" {
	const pkg: PackageSection = {
		name: "x",
		version: "1.0.0",
		description: "",
		license: "",
		repository: "",
		homepage: "",
		keywords: [],
		author: "",
		files: [],
		ignore: [],
		valid: true,
	};
	const manifest = buildManifestJson(pkg, "1.0.0");
	assert manifest === "{\"name\":\"x\",\"version\":\"1.0.0\"}";
}
