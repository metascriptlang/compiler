import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, realpathSync, statSync } from "node:fs";
import { basename, dirname, isAbsolute, join, relative, resolve, win32 } from "node:path";

export function canonicalPath(path) {
	try { return realpathSync(path); } catch { return path; }
}

export function stripQuery(id) {
	const q = id.indexOf("?");
	return q === -1 ? id : id.slice(0, q);
}

export function instanceOf(id) {
	return /[?&]instance=([^&]+)/.exec(id)?.[1] ?? "";
}

export function withInstance(path, instance) {
	return instance ? `${path}?instance=${instance}` : path;
}

export function outputOf(result, id) {
	if (!result) return undefined;
	const instance = instanceOf(id);
	return instance ? result.byInstance.get(instance) : result.bySource.get(canonicalPath(stripQuery(id)));
}

function freeze(value) {
	if (value && typeof value === "object") {
		for (const child of Object.values(value)) freeze(child);
		Object.freeze(value);
	}
	return value;
}

function readonlyIndex(map) {
	return Object.freeze({
		size: map.size,
		get: key => map.get(key),
		has: key => map.has(key),
		keys: () => map.keys(),
		values: () => map.values(),
		entries: () => map.entries(),
		[Symbol.iterator]: () => map[Symbol.iterator](),
	});
}

function invalid(message) {
	throw new Error(`Invalid msc split manifest: ${message}`);
}

function inputPath(path, label) {
	if (typeof path !== "string" || path.includes("\0") || !isAbsolute(path) || !existsSync(path) || !statSync(path).isFile()) {
		invalid(`${label} must be an absolute existing input file`);
	}
	return canonicalPath(path);
}

export function sourceRootOfOutput(root, file) {
	if (typeof root !== "string" || typeof file !== "string" || !file.startsWith(`${root}/`)) invalid(`output outside source declaration family: ${file}`);
	return file.slice(root.length + 1);
}

function contained(root, file) {
	const rel = relative(root, file);
	return rel !== "" && !isAbsolute(rel) && rel !== ".." && !rel.startsWith(`..${win32.sep}`) && !rel.startsWith("../");
}

function outputPath(root, out) {
	if (typeof out !== "string" || out === "" || out.includes("\0") || isAbsolute(out) || win32.isAbsolute(out)) {
		invalid("output must be a relative file path");
	}
	const parts = out.replace(/\\/g, "/").split("/");
	if (parts.some(part => part === "" || part === "." || part === ".." || part.includes(":"))) {
		invalid(`malformed output path: ${out}`);
	}
	const normalized = parts.join("/");
	const file = canonicalPath(resolve(root, normalized));
	if (!contained(root, file)) invalid(`output escapes root: ${out}`);
	if (!existsSync(file) || !statSync(file).isFile()) invalid(`output is not a file: ${out}`);
	return { file, out: normalized };
}

function parseJSON(text, label) {
	try { return JSON.parse(text); } catch (error) {
		invalid(`${label}: ${error.message}`);
	}
}

export function buildCompilerGraph(options) {
	const root = resolve(options.root ?? process.cwd());
	const requested = Array.isArray(options.entry) ? options.entry : [options.entry];
	if (requested.length === 0) invalid("at least one entry is required");
	const entries = [...new Set(requested.map(path => inputPath(typeof path === "string" ? resolve(root, path) : path, "entry")))];
	const entry = entries[0];
	let sourceRoot;
	if (options.sourceRoot !== undefined) {
		sourceRoot = canonicalPath(resolve(root, options.sourceRoot));
		if (!existsSync(sourceRoot) || !statSync(sourceRoot).isDirectory()) invalid("sourceRoot must be an existing directory");
	}
	const outDir = resolve(root, options.outDir ?? "node_modules/.metascript");
	mkdirSync(outDir, { recursive: true });
	const args = ["build", entry, ...(options.compilerArgs ?? []), "--target=js", "--split", `--output=${outDir}`];
	if (options.sourcemap !== false) args.push("--sourcemap");
	for (const extra of entries.slice(1)) args.push(`--js-entry=${extra}`);
	if (options.declaration === true || sourceRoot) args.push("--declaration");
	if (sourceRoot) args.push(`--declaration-source-root=${sourceRoot}`);
	try {
		execFileSync(options.msc ?? "msc", args, {
			stdio: options.quiet === false ? "inherit" : "pipe",
		});
	} catch (error) {
		const output = [error.stdout, error.stderr].map(b => b ? b.toString() : "").join("").trim();
		throw new Error(output ? `msc build failed:\n${output}` : error.message, { cause: error });
	}

	const outputRoot = canonicalPath(outDir);
	const manifestPath = outputPath(outputRoot, "_manifest.json");
	const manifestText = readFileSync(manifestPath.file, "utf8");
	const manifest = parseJSON(manifestText, "_manifest.json");
	if (!manifest || typeof manifest !== "object" || Array.isArray(manifest)) invalid("expected an object");
	const manifestEntry = inputPath(manifest.entry, "entry");
	if (manifestEntry !== entry) invalid("entry does not match the requested entry");
	if (manifest.entries !== undefined || entries.length > 1) {
		if (!Array.isArray(manifest.entries) || manifest.entries.length !== entries.length || manifest.entries.some((path, i) => inputPath(path, "entries") !== entries[i])) invalid("entries do not match the requested roots");
	}
	if (!Array.isArray(manifest.modules)) invalid("modules must be an array");
	for (const key of ["instances", "declarations", "dependencies", "sourceDeclarations"]) {
		if (manifest[key] !== undefined && !Array.isArray(manifest[key])) invalid(`${key} must be an array`);
	}

	const bySource = new Map();
	const byInstance = new Map();
	const byOutput = new Map();
	const artifacts = [{ kind: "manifest", ...manifestPath, text: manifestText }];
	const owned = new Set([manifestPath.file]);
	const claim = (out) => {
		const path = outputPath(outputRoot, out);
		if (owned.has(path.file)) invalid(`duplicate output: ${out}`);
		owned.add(path.file);
		return path;
	};
	const record = (row, label) => {
		if (!row || typeof row !== "object" || Array.isArray(row)) invalid(`${label} must be an object`);
		return inputPath(row.source, `${label}.source`);
	};
	const readModule = (row, isInstance) => {
		const source = record(row, isInstance ? "instance" : "module");
		const path = claim(row.out);
		const instance = isInstance ? basename(path.out, ".js") : "";
		if (isInstance && byInstance.has(instance)) invalid(`duplicate instance: ${instance}`);
		if (!isInstance && bySource.has(source)) invalid(`duplicate module source: ${source}`);
		const text = readFileSync(path.file, "utf8");
		let map = null;
		if (options.sourcemap !== false && existsSync(`${path.file}.map`)) {
			const mapPath = claim(`${path.out}.map`);
			const mapText = readFileSync(mapPath.file, "utf8");
			map = parseJSON(mapText, mapPath.out);
			if (!map || typeof map !== "object" || !Array.isArray(map.sources) || map.sources.some(s => typeof s !== "string")) {
				invalid(`invalid source map: ${mapPath.out}`);
			}
			map = { ...map, sources: map.sources.map(s => resolve(dirname(path.file), s).replace(/\\/g, "/")) };
			artifacts.push({ kind: "sourcemap", ...mapPath, source, instance, text: mapText });
		}
		const module = { ...path, source, instance, code: text.replace(/\n*\/\/# sourceMappingURL=[^\n]*\n?/, "\n"), map };
		byOutput.set(path.file, module);
		if (isInstance) byInstance.set(instance, path.file);
		else bySource.set(source, path.file);
		artifacts.push({ kind: "javascript", ...path, source, instance, text });
		return freeze(module);
	};
	const modules = manifest.modules.map(row => readModule(row, false));
	const instances = (manifest.instances ?? []).map(row => readModule(row, true));
	for (const source of entries) if (!bySource.has(source)) invalid("entry is not present in modules");
	const declarations = (manifest.declarations ?? []).map(row => {
		const source = record(row, "declaration");
		const path = claim(row.out);
		const declaration = { kind: "declaration", ...path, source, text: readFileSync(path.file, "utf8") };
		artifacts.push(declaration);
		return declaration;
	});
	if (options.declaration === true) for (const source of entries) {
		if (!declarations.some(output => output.source === source)) invalid("entry declaration is required when --declaration is requested");
	}
	let sourceDeclarationRoot = null;
	let sourceDeclarationPackage = null;
	const sourceDeclarations = [];
	if (manifest.sourceDeclarations !== undefined || sourceRoot) {
		if (manifest.sourceDeclarationRoot !== "_source_declarations") invalid("sourceDeclarationRoot must be _source_declarations");
		sourceDeclarationRoot = manifest.sourceDeclarationRoot;
		if (manifest.sourceDeclarationPackage !== `${sourceDeclarationRoot}/package.json`) invalid("sourceDeclarationPackage must name the family package.json");
		const packagePath = claim(manifest.sourceDeclarationPackage);
		const text = readFileSync(packagePath.file, "utf8");
		const metadata = parseJSON(text, packagePath.out);
		if (!metadata || metadata.type !== "module" || Object.keys(metadata).length !== 1) invalid("source declaration package must contain only type: module");
		sourceDeclarationPackage = { kind: "source-declaration-package", ...packagePath, text };
		artifacts.push(sourceDeclarationPackage);
		for (const row of manifest.sourceDeclarations ?? []) {
			const source = record(row, "source declaration");
			const path = claim(row.out);
			const familyOut = sourceRootOfOutput(sourceDeclarationRoot, path.out);
			if (!(/\.d\.(?:ms|jms)\.ts$/.test(familyOut) || (familyOut.startsWith("_types/") && familyOut.endsWith(".d.ts")))) invalid(`invalid source declaration path: ${path.out}`);
			const artifact = { kind: "source-declaration", ...path, source, text: readFileSync(path.file, "utf8") };
			sourceDeclarations.push(artifact);
			artifacts.push(artifact);
		}
		if (sourceRoot) for (const source of entries) {
			if (!contained(sourceRoot, source)) invalid(`source entry is outside sourceRoot: ${source}`);
			const expected = `${sourceDeclarationRoot}/${relative(sourceRoot, source).replace(/\\/g, "/").replace(/\.(ms|jms)$/, ".d.$1.ts")}`;
			if (!sourceDeclarations.some(row => row.source === source && row.out === expected)) invalid(`missing requested source entry declaration: ${source}`);
		}
	}
	const dependencies = [...new Set([
		...modules.map(m => m.source),
		...instances.map(m => m.source),
		...declarations.map(d => d.source),
		...sourceDeclarations.map(d => d.source),
		...(manifest.dependencies ?? []).map(path => inputPath(path, "dependency")),
	])];
	return freeze({
		entry, entries, outDir: outputRoot, modules, instances, declarations, sourceDeclarationRoot, sourceDeclarationPackage, sourceDeclarations, dependencies, artifacts,
		bySource: readonlyIndex(bySource), byInstance: readonlyIndex(byInstance), byOutput: readonlyIndex(byOutput),
	});
}
