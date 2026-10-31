import { dirname, isAbsolute, resolve } from "node:path";
import { buildCompilerGraph, canonicalPath, stripQuery, instanceOf, withInstance, outputOf } from "./compilerCore.js";

const MS_RE = /\.(?:ms|jms)(\?.*)?$/;

function singleInput(input) {
	if (input !== undefined && (input === null || (typeof input !== "string" && typeof input !== "object"))) {
		throw new Error("MetaScript requires a string Rollup input");
	}
	const inputs = input === undefined ? [] : typeof input === "string" ? [input] : Array.isArray(input) ? input : Object.values(input);
	if (inputs.length > 1) throw new Error("MetaScript supports one compiler root; multiple Rollup inputs are not supported");
	if (inputs.some(value => typeof value !== "string")) throw new Error("MetaScript requires a string Rollup input");
	return inputs[0];
}

export default function metascript(options = {}) {
	if (options.entry !== undefined && (typeof options.entry !== "string" || !MS_RE.test(options.entry))) {
		throw new Error("MetaScript entry must be one .ms or .jms source path");
	}
	const root = resolve(options.root ?? process.cwd());
	const explicitEntry = options.entry ? canonicalPath(resolve(root, stripQuery(options.entry))) : null;
	let entry = explicitEntry;
	let snapshot = null;
	let failure = null;
	let attempted = false;
	let invalidated = false;
	let watchFiles = new Set(entry ? [entry] : []);
	let previousSources = new Set();

	function registerWatches(context) {
		for (const file of watchFiles) context.addWatchFile(file);
	}

	function current(context) {
		if (failure) throw failure;
		if (invalidated) throw new Error("MetaScript build snapshot was invalidated; start a new build generation");
		if (!attempted && entry) {
			attempted = true;
			watchFiles.add(entry);
			registerWatches(context);
			try {
				snapshot = buildCompilerGraph({ ...options, root, entry });
				watchFiles = new Set(snapshot.dependencies);
			} catch (error) {
				failure = error;
				throw error;
			}
		}
		registerWatches(context);
		return snapshot;
	}

	function sourceId(module) {
		return withInstance(module.source.replace(/\\/g, "/"), module.instance);
	}

	return {
		name: "rollup-plugin-metascript",

		buildStart(inputOptions) {
			if (snapshot) previousSources = new Set(snapshot.modules.concat(snapshot.instances).map(module => module.source));
			snapshot = null;
			failure = null;
			attempted = false;
			invalidated = false;
			try {
				const input = singleInput(inputOptions.input);
				if (!explicitEntry && input && MS_RE.test(input)) entry = canonicalPath(resolve(root, stripQuery(input)));
				current(this);
			} catch (error) {
				failure = error;
				throw error;
			}
		},

		watchChange(id) {
			if (watchFiles.has(canonicalPath(stripQuery(id)))) invalidated = true;
		},

		shouldTransformCachedModule({ id }) {
			const source = canonicalPath(stripQuery(id));
			return previousSources.has(source) || Boolean(outputOf(snapshot, id));
		},

		resolveId(source, importer) {
			if (importer && source.startsWith(".")) {
				const graph = current(this);
				const parent = outputOf(graph, importer);
				const target = parent ? graph.byOutput.get(canonicalPath(resolve(dirname(parent), stripQuery(source)))) : null;
				if (target) return sourceId(target);
			}
			if (!MS_RE.test(source)) return null;
			const base = importer ? dirname(stripQuery(importer)) : root;
			const file = canonicalPath(isAbsolute(stripQuery(source)) ? stripQuery(source) : resolve(base, stripQuery(source)));
			if (!entry) entry = file;
			const graph = current(this);
			if (!graph.bySource.has(file)) throw new Error(`MetaScript source is outside the compiled graph: ${file}; configure one entry that imports every required source`);
			const instance = instanceOf(source);
			const output = graph.byOutput.get(outputOf(graph, withInstance(file, instance)));
			if (!output || output.source !== file) throw new Error(`MetaScript instance is not in the compiled graph: ${source}`);
			return sourceId(output);
		},

		load(id) {
			if (!MS_RE.test(id)) return null;
			const graph = current(this);
			const output = graph?.byOutput.get(outputOf(graph, id));
			if (!output) throw new Error(`MetaScript source or instance is not in the current compiled graph: ${id}`);
			return { code: output.code, map: output.map };
		},

		outputOptions(output) {
			if (output.format !== undefined && output.format !== "es" && output.format !== "esm" && output.format !== "module") {
				throw new Error("MetaScript Rollup output must use ES modules (format: 'es')");
			}
			return null;
		},

		generateBundle() {
			if (options.declaration !== true) return;
			const graph = current(this);
			for (const declaration of graph?.declarations ?? []) {
				this.emitFile({ type: "asset", fileName: declaration.out, source: declaration.text });
			}
		},
	};
}
