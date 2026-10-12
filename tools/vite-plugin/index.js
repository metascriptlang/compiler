import { execFileSync } from "node:child_process";
import { existsSync, realpathSync, readFileSync, mkdirSync, unlinkSync } from "node:fs";
import { join, resolve, dirname, relative, basename } from "node:path";
import MagicString from "magic-string";

const MS_RE = /\.(?:ms|jms)(\?.*)?$/;

// Vite hands ids through the platform's real path (/tmp is a symlink to
// /private/tmp on macOS) while plugin options and the manifest keep the
// spelling each side was given, so both have to go through realpath before
// they can be compared.
function canon(p) {
	try { return realpathSync(p); } catch { return p; }
}

function stripQuery(id) {
	const q = id.indexOf("?");
	return q === -1 ? id : id.slice(0, q);
}

// A generic instance with a file of its own has no source file of its own, so
// its id is the source of the module declaring the generic plus this query.
// The emitted file's own path would put the id under node_modules, where Vite
// serves a module as an immutable dependency.
const INSTANCE_RE = /[?&]instance=([^&]+)/;

function instanceOf(id) {
	const m = INSTANCE_RE.exec(id);
	return m ? m[1] : "";
}

function withInstance(path, instance) {
	return instance ? `${path}?instance=${instance}` : path;
}

export default function metascript(options = {}) {
	const msc = options.msc ?? "msc";
	let root = process.cwd();
	// Default inside the project: Vite serves files under root directly, while
	// a tmpdir has to go through /@fs and dies under a stricter server.fs.allow.
	let outDir = options.outDir ? resolve(options.outDir) : join(root, "node_modules/.metascript");
	let entry = options.entry ? canon(resolve(options.entry)) : null;
	let emitted = null;
	let server = null;
	let compileFailed = false;

	// One emit covers the whole graph, so the first .ms resolve pays for all of
	// them; later resolves reuse the tree until a source file changes. The
	// source→output mapping comes from the compiler's manifest — re-deriving it
	// here means replicating project-root discovery, which silently resolves
	// nothing whenever the two disagree.
	function emit() {
		mkdirSync(outDir, { recursive: true });
		// Vite reads the sourceMappingURL comment off the file it loads, so the
		// map only has to exist beside the emitted module.
		const args = ["build", entry, ...(options.compilerArgs ?? []), "--target=js", "--split", `--output=${outDir}`];
		if (options.sourcemap !== false) args.push("--sourcemap");
		try {
			execFileSync(msc, args, {
				stdio: options.quiet === false ? "inherit" : "pipe",
			});
		} catch (e) {
			const out = [e.stdout, e.stderr].map((b) => (b ? b.toString() : "")).join("").trim();
			throw new Error(out ? `msc build failed:\n${out}` : e.message);
		}
		const manifest = JSON.parse(readFileSync(join(outDir, "_manifest.json"), "utf8"));
		const bySource = new Map();
		const byInstance = new Map();
		const byOutput = new Map();
		const read = (m, instance) => {
			const file = canon(join(outDir, m.out));
			const mapFile = `${file}.map`;
			const code = readFileSync(file, "utf8").replace(/\n*\/\/# sourceMappingURL=[^\n]*\n?/, "\n");
			let map = options.sourcemap !== false && existsSync(mapFile)
				? JSON.parse(readFileSync(mapFile, "utf8"))
				: null;
			if (map) map = { ...map, sources: map.sources.map(source => resolve(dirname(file), source).replace(/\\/g, "/")) };
			const source = canon(m.source);
			byOutput.set(file, { source, instance, code, map });
			return file;
		};
		for (const m of manifest.modules) bySource.set(canon(m.source), read(m, ""));
		for (const m of manifest.instances ?? []) {
			const instance = basename(m.out, ".js");
			byInstance.set(instance, read(m, instance));
		}
		emitted = { bySource, byInstance, byOutput };
		// Vite only watches inside root, so .ms sources living outside it have
		// to be registered explicitly or an edit never reaches the handler.
		if (server) server.watcher.add([...bySource.keys()]);
	}

	function outputOf(id) {
		if (emitted === null) return undefined;
		const instance = instanceOf(id);
		return instance ? emitted.byInstance.get(instance) : emitted.bySource.get(canon(stripQuery(id)));
	}

	return {
		name: "vite-plugin-metascript",
		enforce: "pre",

		configResolved(config) {
			root = config.root;
			if (!options.outDir) outDir = join(root, "node_modules/.metascript");
			if (entry === null && options.entry) entry = canon(resolve(root, options.entry));
		},

		configureServer(s) {
			server = s;
			if (emitted) s.watcher.add([...emitted.bySource.keys()]);
		},

		handleHotUpdate(ctx) {
			if (emitted === null) return;
			const source = canon(ctx.file);
			if (emitted.byOutput.has(source)) return [];
			if (!emitted.bySource.has(source)) return;
			const previous = emitted;
			try {
				emit();
			} catch (error) {
				compileFailed = true;
				ctx.server.ws.send({
					type: "error",
					err: { message: error.message, stack: error.stack, plugin: "vite-plugin-metascript" },
				});
				return [];
			}
			const changed = new Set();
			for (const [file, output] of emitted.byOutput) {
				if (previous.byOutput.get(file)?.code !== output.code) changed.add(output);
			}
			for (const [file, output] of previous.byOutput) {
				if (emitted.byOutput.has(file)) continue;
				changed.add(output);
				if (existsSync(file)) unlinkSync(file);
				if (existsSync(`${file}.map`)) unlinkSync(`${file}.map`);
			}
			const modules = new Set();
			for (const output of changed) {
				const loaded = ctx.server.moduleGraph.getModulesByFile(output.source.replace(/\\/g, "/"));
				if (!loaded) continue;
				for (const module of loaded) {
					if (instanceOf(module.id ?? "") === output.instance) modules.add(module);
				}
			}
			if (compileFailed && modules.size === 0) ctx.server.ws.send({ type: "update", updates: [] });
			compileFailed = false;
			return [...modules];
		},

		// Rollup loads the emitted file through its own fs and does not follow
		// the sourceMappingURL comment, so a production bundle maps back to the
		// generated .js unless the map is handed over here. Dev goes through the
		// same hook, which also spares the browser a second request for it.
		load(id) {
			const output = outputOf(id);
			const module = output ? emitted.byOutput.get(output) : null;
			return module ? { code: module.code, map: module.map } : null;
		},

		transform(code, id) {
			const source = canon(stripQuery(id));
			const output = outputOf(id);
			if (!output) return null;
			let rewritten = null;
			for (const statement of this.parse(code).body) {
				const specifier = statement.source;
				if (!specifier || !specifier.value.startsWith(".")) continue;
				const target = emitted.byOutput.get(canon(resolve(dirname(output), specifier.value)));
				if (!target) continue;
				let path = relative(dirname(source), target.source).replace(/\\/g, "/");
				if (!path.startsWith(".")) path = "./" + path;
				if (!rewritten) rewritten = new MagicString(code);
				rewritten.overwrite(specifier.start, specifier.end, JSON.stringify(withInstance(path, target.instance)));
			}
			return rewritten ? { code: rewritten.toString(), map: rewritten.generateMap({ hires: true, source: id, includeContent: true }) } : null;
		},

		resolveId(source, importer) {
			if (!MS_RE.test(source)) return null;
			const base = importer ? dirname(stripQuery(importer)) : root;
			const file = canon(resolve(base, stripQuery(source)));
			if (!existsSync(file)) return null;
			if (entry === null) entry = file;
			if (emitted === null) emit();
			const instance = instanceOf(source);
			if (!emitted.bySource.has(file) || (instance && !emitted.byInstance.has(instance))) return null;
			return withInstance(file.replace(/\\/g, "/"), instance);
		},
	};
}
