import { dirname, isAbsolute, resolve } from "node:path";
import { buildCompilerGraph, canonicalPath, stripQuery, instanceOf, withInstance, outputOf } from "./compilerCore.js";

import { createSourceDeclarationPublisher, sourceDeclarationWatchRoots, sourceDeclarationOutputPattern } from "./sourceDeclarations.js";

const MS_RE = /\.(?:ms|jms)(\?.*)?$/;

function compilerInputs(input) {
	if (input !== undefined && (input === null || (typeof input !== "string" && typeof input !== "object"))) {
		throw new Error("MetaScript requires a string Rollup input");
	}
	const inputs = input === undefined ? [] : typeof input === "string" ? [input] : Array.isArray(input) ? input : Object.values(input);
	if (inputs.some(value => typeof value !== "string")) throw new Error("MetaScript requires a string Rollup input");
	return inputs;
}

export default function metascript(options = {}) {
	if (options.entry !== undefined && (!(Array.isArray(options.entry) ? options.entry : [options.entry]).length || (Array.isArray(options.entry) ? options.entry : [options.entry]).some(file => typeof file !== "string" || !MS_RE.test(file)))) {
		throw new Error("MetaScript entry must contain .ms or .jms source paths");
	}
	const root = resolve(options.root ?? process.cwd());
	const explicitEntry = options.entry ? (Array.isArray(options.entry) ? options.entry : [options.entry]).map(file => canonicalPath(resolve(root, stripQuery(file)))) : null;
	let publisher = null;
	let entry = explicitEntry;
	let snapshot = null;
	let failure = null;
	let attempted = false;
	let invalidated = false;
	let watchFiles = new Set(entry ?? []);
	let previousSources = new Set();

	function registerWatches(context) {
		if (options.sourceDeclarations && context.meta?.watchMode) for (const path of sourceDeclarationWatchRoots(root, publisher?.sourceRoot ?? canonicalPath(resolve(root, options.sourceDeclarations.rootDir ?? root)), [...watchFiles])) context.addWatchFile(path);
		for (const file of watchFiles) context.addWatchFile(file);
		if (options.msc) context.addWatchFile(canonicalPath(resolve(options.msc)));
	}

	function current(context) {
		if (failure) throw failure;
		if (invalidated) throw new Error("MetaScript build snapshot was invalidated; start a new build generation");
		if (!attempted && entry) {
			attempted = true;
			for (const file of entry) watchFiles.add(file);
			registerWatches(context);
			try {
				if (options.sourceDeclarations) {
					publisher ??= createSourceDeclarationPublisher(options.sourceDeclarations, root);
					publisher.invalidate();
				}
				snapshot = buildCompilerGraph({ ...options, root, entry, sourceRoot: publisher?.sourceRoot });
				publisher?.publish(snapshot);
				watchFiles = new Set(snapshot.dependencies);
			} catch (error) {
				failure = error;
				publisher?.invalidate();
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
			if (options.sourceDeclarations && this.meta?.watchMode && attempted && !invalidated) { registerWatches(this); if (failure) throw failure; return; }
			if (snapshot) previousSources = new Set(snapshot.modules.concat(snapshot.instances).map(module => module.source));
			snapshot = null;
			failure = null;
			attempted = false;
			invalidated = false;
			try {
				const inputs = compilerInputs(inputOptions.input);
				if (!explicitEntry && inputs.length && inputs.every(input => MS_RE.test(input))) entry = inputs.map(input => canonicalPath(resolve(root, stripQuery(input))));
				current(this);
			} catch (error) {
				failure = error;
				throw error;
			}
		},

		watchChange(id) {
			const file = canonicalPath(stripQuery(id));
			if (options.sourceDeclarations && sourceDeclarationOutputPattern(options.sourceDeclarations, root, options.outDir).test(file)) return;
			if (watchFiles.has(file) || (options.msc && file === canonicalPath(resolve(options.msc))) || (options.sourceDeclarations && MS_RE.test(file))) { invalidated = true; publisher?.invalidate(); }
		},

		closeWatcher() {
			publisher?.close(); publisher = null;
			attempted = false;
			invalidated = true;
		},

		closeBundle() { if (!this.meta?.watchMode) { publisher?.close(); publisher = null; } },

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
			if (!entry) entry = [file];
			const graph = current(this);
			if (!graph.bySource.has(file)) throw new Error(`MetaScript source is outside the compiled graph: ${file}; configure entry roots that include every required source`);
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
