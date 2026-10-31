import { existsSync, unlinkSync } from "node:fs";
import { join, resolve, dirname, relative } from "node:path";
import MagicString from "magic-string";
import { buildCompilerGraph, canonicalPath as canon, stripQuery, instanceOf, withInstance, outputOf } from "./compilerCore.js";

const MS_RE = /\.(?:ms|jms)(\?.*)?$/;

function relativeSpecifiers(program) {
	const found = [];
	const visit = (node) => {
		if (!node || typeof node.type !== "string") return;
		const spec = node.source;
		const takesSpecifier = node.type === "ImportExpression" || node.type.endsWith("Declaration");
		if (takesSpecifier && spec?.type === "Literal" && typeof spec.value === "string" && spec.value.startsWith(".")) found.push(spec);
		for (const key in node) {
			const child = node[key];
			if (Array.isArray(child)) child.forEach(visit);
			else if (child && typeof child === "object") visit(child);
		}
	};
	visit(program);
	return found;
}

export default function metascript(options = {}) {
	let root = process.cwd();
	// Default inside the project: Vite serves files under root directly, while
	// a tmpdir has to go through /@fs and dies under a stricter server.fs.allow.
	let outDir = options.outDir ? resolve(options.outDir) : join(root, "node_modules/.metascript");
	let entry = options.entry ? canon(resolve(options.entry)) : null;
	let emitted = null;
	let server = null;
	let compileFailed = false;
	let dirty = true;
	let watchFiles = new Set(entry ? [entry] : []);
	let stopWatching = null;

	function registerWatchFiles(context) {
		for (const file of watchFiles) context?.addWatchFile(file);
		if (server) server.watcher.add([...watchFiles]);
	}

	function requireCurrentGeneration() {
		if (server === null && dirty && emitted !== null) {
			throw new Error("MetaScript production snapshot invalidated; call buildStart before consuming more modules");
		}
	}

	function emit(context) {
		dirty = true;
		watchFiles.add(entry);
		registerWatchFiles(context);
		const next = buildCompilerGraph({ ...options, root, entry, outDir });
		emitted = next;
		dirty = false;
		watchFiles = new Set(next.dependencies);
		registerWatchFiles(context);
	}

	function hotUpdate(ctx, context) {
		const source = canon(ctx.file);
		if (emitted?.byOutput.has(source)) return [];
		if (!watchFiles.has(source)) return;
		const previous = emitted;
		try {
			emit(context);
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
			if (previous?.byOutput.get(file)?.code !== output.code) changed.add(output);
		}
		for (const [file, output] of previous?.byOutput ?? []) {
			if (!emitted.byOutput.has(file)) changed.add(output);
		}
		const currentFiles = new Set(emitted.artifacts.map(artifact => artifact.file));
		for (const artifact of previous?.artifacts ?? []) {
			if (artifact.kind !== "javascript" && artifact.kind !== "sourcemap") continue;
			if (!currentFiles.has(artifact.file) && existsSync(artifact.file)) unlinkSync(artifact.file);
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
	}

	return {
		name: "vite-plugin-metascript",
		enforce: "pre",

		configResolved(config) {
			root = config.root;
			if (!options.outDir) outDir = join(root, "node_modules/.metascript");
			if (entry === null && options.entry) entry = canon(resolve(root, options.entry));
		},

		buildStart() {
			registerWatchFiles(this);
			if (entry !== null) emit(this);
		},

		watchChange(id) {
			if (watchFiles.has(canon(stripQuery(id)))) dirty = true;
		},

		configureServer(s) {
			stopWatching?.();
			server = s;
			registerWatchFiles();
			const refresh = file => {
				const modules = hotUpdate({ file, server: s });
				if (!modules?.length) return;
				for (const module of modules) s.moduleGraph.invalidateModule(module);
				s.ws.send({ type: "full-reload", path: "*" });
			};
			s.watcher.on("add", refresh);
			s.watcher.on("unlink", refresh);
			stopWatching = () => {
				s.watcher.off("add", refresh);
				s.watcher.off("unlink", refresh);
			};
		},

		closeBundle() {
			stopWatching?.();
			stopWatching = null;
			server = null;
		},

		handleHotUpdate(ctx) {
			return hotUpdate(ctx, this);
		},

		generateBundle() {
			if (options.declaration !== true || entry === null) return;
			if (dirty || emitted === null) throw new Error("MetaScript has no current build snapshot; rebuild before emitting declarations");
			for (const declaration of emitted.declarations) {
				this.emitFile({ type: "asset", fileName: declaration.out, source: declaration.text });
			}
		},

		// Rollup loads the emitted file through its own fs and does not follow
		// the sourceMappingURL comment, so a production bundle maps back to the
		// generated .js unless the map is handed over here. Dev goes through the
		// same hook, which also spares the browser a second request for it.
		load(id) {
			if (outputOf(emitted, id)) {
				requireCurrentGeneration();
				if (dirty) emit(this);
			}
			const output = outputOf(emitted, id);
			const module = output ? emitted.byOutput.get(output) : null;
			if (module && module.source !== canon(stripQuery(id))) {
				throw new Error(`MetaScript source and instance do not match: ${id}`);
			}
			if (module) registerWatchFiles(this);
			return module ? { code: module.code, map: module.map } : null;
		},

		transform(code, id) {
			const source = canon(stripQuery(id));
			const output = outputOf(emitted, id);
			if (!output) return null;
			requireCurrentGeneration();
			registerWatchFiles(this);
			let rewritten = null;
			for (const specifier of relativeSpecifiers(this.parse(code))) {
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
			requireCurrentGeneration();
			if (emitted === null || dirty) emit(this);
			const instance = instanceOf(source);
			if (!emitted.bySource.has(file) || (instance && !emitted.byInstance.has(instance))) return null;
			const module = emitted.byOutput.get(outputOf(emitted, withInstance(file, instance)));
			if (!module || module.source !== file) {
				throw new Error(`MetaScript source and instance do not match: ${source}`);
			}
			return withInstance(file.replace(/\\/g, "/"), instance);
		},
	};
}
