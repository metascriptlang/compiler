import { mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync } from "node:fs";
import { createHash } from "node:crypto";
import { dirname, isAbsolute, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { buildCompilerGraph, canonicalPath, outputOf, stripQuery, withInstance } from "./compilerCore.js";

import { createSourceDeclarationPublisher, sourceDeclarationWatchRoots, ownedOutputGlobs, ownedOutputPattern } from "./sourceDeclarations.js";

export const loader = fileURLToPath(new URL("./webpackLoader.js", import.meta.url));
const implementationFiles = ["webpack.js", "webpackLoader.js", "compilerCore.js", "sourceDeclarations.js", "package.json"].map(file => fileURLToPath(new URL(file, import.meta.url)));
const name = "MetaScriptPlugin";

// Context aggregates can name only the directory, not the changed source. Hash
// source bytes as well as names: a failed compile has no complete dependency list.
function sourceInventory(roots, outputs) {
	const visited = new Set(), sources = new Map();
	const visit = file => {
		const path = canonicalPath(file);
		if (outputs.test(path) || visited.has(path)) return;
		visited.add(path);
		try {
			if (statSync(path).isDirectory()) {
				for (const item of readdirSync(path)) visit(join(path, item));
			} else if (/\.(ms|jms)$/.test(path)) {
				sources.set(path, createHash("sha256").update(readFileSync(path)).digest("hex"));
			}
		} catch (error) {
			if (error.code !== "ENOENT" && error.code !== "ENOTDIR") throw error;
		}
	};
	for (const root of roots) visit(root);
	return JSON.stringify([...sources].sort(([a], [b]) => a.localeCompare(b)));
}

class IgnoredWithOutputs extends RegExp {
	constructor(ignored, outputs) {
		super(outputs.source, outputs.flags);
		this.ignored = ignored;
	}

	test(path) {
		return this.ignored.test(path) || super.test(path);
	}
}

function ignoringOutputs(ignored, outputs, outputGlobs) {
	if (!ignored || (Array.isArray(ignored) && ignored.length === 0)) return outputs;
	if (ignored instanceof RegExp) return new IgnoredWithOutputs(ignored, outputs);
	if (typeof ignored === "function") return path => ignored(path) || outputs.test(path);
	const list = Array.isArray(ignored) ? ignored : [ignored];
	return outputGlobs && list.every(item => typeof item === "string") ? [...list, ...outputGlobs] : [...list, outputs];
}

export default class MetaScriptPlugin {
	constructor(options) {
		if (!options || !(Array.isArray(options.entry) ? options.entry : [options.entry]).length || (Array.isArray(options.entry) ? options.entry : [options.entry]).some(file => typeof file !== "string" || !/\.(ms|jms)$/.test(file))) {
			throw new Error("MetaScript webpack requires explicit .ms or .jms entries");
		}
		this.options = { ...options, compilerArgs: options.compilerArgs ? [...options.compilerArgs] : undefined };
	}

	apply(compiler) {
		if (compiler.webpack?.version?.split(".")[0] !== "5") throw new Error("MetaScript requires webpack 5");
		const options = this.options;
		const root = resolve(options.root ?? compiler.context);
		const entry = (Array.isArray(options.entry) ? options.entry : [options.entry]).map(file => canonicalPath(resolve(root, file)));
		let publisher = null;
		const msc = options.msc ? canonicalPath(resolve(options.msc)) : null;
		const workspace = resolve(root, options.outDir ?? "node_modules/.metascript");
		const outputs = options.sourceDeclarations && ownedOutputPattern(options.sourceDeclarations, root, join(workspace, "webpack-"));
		const outputGlobs = options.sourceDeclarations && ownedOutputGlobs(options.sourceDeclarations, root, join(workspace, "webpack-"));
		if (outputs) compiler.hooks.afterEnvironment?.tap(name, () => {
			const native = compiler.watchFileSystem;
			let previousWatchOptions, enrichedWatchOptions;
			compiler.watchFileSystem = {
				watch(files, directories, missing, startTime, watchOptions, callback, callbackUndelayed) {
					if (watchOptions !== previousWatchOptions) {
						enrichedWatchOptions = { ...watchOptions, ignored: ignoringOutputs(watchOptions.ignored, outputs, outputGlobs) };
						previousWatchOptions = watchOptions;
					}
					try {
						return native.watch(files, directories, missing, startTime, enrichedWatchOptions, callback, (file, time) => {
							invalidateSource(file);
							callbackUndelayed?.(file, time);
						});
					} catch (error) {
						if (!Array.isArray(enrichedWatchOptions.ignored) || !enrichedWatchOptions.ignored.includes(outputs)) throw error;
						throw new Error(`MetaScript webpack excludes its outputs from watchOptions.ignored ${outputGlobs ? "beside RegExp items" : `through a RegExp item, because ${root} has glob characters`}, and this watchpack accepts RegExp array items only from 2.6.0; give watchOptions.ignored as one RegExp or a function`, { cause: error });
					}
				},
			};
		});
		let previousDependencies = entry;
		let previousGraph = null;
		let previousFailure = null;
		let attempted = false;
		let invalidated = true;
		let controlInvalidated = true;
		let previousInventory;
		const close = () => {
			publisher?.close(); publisher = null;
			previousDependencies = entry;
			previousGraph = null;
			previousFailure = null;
			attempted = false;
			invalidated = true;
			controlInvalidated = true;
			previousInventory = undefined;
		};
		compiler.hooks.watchClose?.tap(name, close);
		compiler.hooks.shutdown?.tap(name, close);
		const relevant = file => {
			if (!file) return true;
			const source = canonicalPath(file);
			if (outputs?.test(source)) return false;
			return /\.(ms|jms)$/.test(source) || previousDependencies.includes(source) || implementationFiles.includes(source) || source === msc;
		};
		const invalidateSource = file => {
			if (!relevant(file)) return;
			invalidated = true;
			if (!file || !/\.(ms|jms)$/.test(file)) controlInvalidated = true;
			publisher?.invalidate();
		};
		compiler.hooks.invalid?.tap(name, invalidateSource);
		compiler.hooks.thisCompilation.tap(name, (compilation, { normalModuleFactory }) => {
			let graph = null;
			let failure = null;
			if (options.sourceDeclarations) for (const path of sourceDeclarationWatchRoots(root, canonicalPath(resolve(root, options.sourceDeclarations.rootDir ?? root)), previousDependencies)) compilation.contextDependencies.add(path);
			for (const file of previousDependencies) compilation.fileDependencies.add(file);
			for (const file of implementationFiles) compilation.buildDependencies.add(file);
			if (options.msc && (isAbsolute(options.msc) || options.msc.includes("/") || options.msc.includes("\\"))) {
				compilation.buildDependencies.add(msc);
				compilation.fileDependencies.add(msc);
			}
			let temporary;
			try {
				const watchRoots = options.sourceDeclarations && sourceDeclarationWatchRoots(root, canonicalPath(resolve(root, options.sourceDeclarations.rootDir ?? root)), previousDependencies);
				const changes = [...(compiler.modifiedFiles ?? []), ...(compiler.removedFiles ?? [])];
				const ambiguous = watchRoots && changes.some(file => watchRoots.includes(canonicalPath(file)));
				const sourceChanged = changes.some(relevant);
				const inventory = options.sourceDeclarations && compiler.watchMode && (!attempted || ambiguous || invalidated || sourceChanged) ? sourceInventory(watchRoots, outputs) : previousInventory;
				const changed = sourceChanged || inventory !== previousInventory;
				const sourcesOnly = changes.length > 0 && changes.every(file => /\.(ms|jms)$/.test(file) || watchRoots.includes(canonicalPath(file)));
				const compiledBytes = options.sourceDeclarations && compiler.watchMode && attempted && inventory === previousInventory && ((sourcesOnly && !controlInvalidated) || !(invalidated || changed));
				if (compiledBytes) {
					graph = previousGraph;
					if (previousFailure) throw previousFailure;
					if (invalidated) { publisher.publish(graph); invalidated = false; }
				} else {
					attempted = true;
					previousInventory = inventory;
					if (options.sourceDeclarations) {
						publisher ??= createSourceDeclarationPublisher(options.sourceDeclarations, root);
						publisher.invalidate();
					}
					mkdirSync(workspace, { recursive: true });
					temporary = canonicalPath(mkdtempSync(join(workspace, "webpack-")));
					graph = buildCompilerGraph({ ...options, root, entry, outDir: temporary, sourceRoot: publisher?.sourceRoot });
					publisher?.publish(graph);
					previousGraph = graph;
					previousFailure = null;
					invalidated = false;
					controlInvalidated = false;
				}
				previousDependencies = graph.dependencies;
				for (const file of graph.dependencies) compilation.fileDependencies.add(file);
				if (options.sourceDeclarations) for (const path of sourceDeclarationWatchRoots(root, publisher.sourceRoot, graph.dependencies)) compilation.contextDependencies.add(path);
			} catch (error) {
				failure = error;
				previousFailure = error;
				invalidated = false;
				controlInvalidated = false;
				publisher?.invalidate();
				compilation.errors.push(error);
			} finally {
				if (temporary) rmSync(temporary, { recursive: true, force: true });
			}

			compiler.webpack.NormalModule.getCompilationHooks(compilation).loader.tap(name, context => {
				context.metascriptModule = id => {
					if (failure) throw failure;
					const output = graph.byOutput.get(outputOf(graph, id));
					if (!output || output.source !== canonicalPath(stripQuery(id))) {
						throw new Error(`MetaScript source or instance is outside the compiled graph: ${id}`);
					}
					for (const file of graph.dependencies) context.addDependency(file);
					for (const file of implementationFiles) context.addBuildDependency(file);
					return output;
				};
			});

			normalModuleFactory.hooks.beforeResolve.tap(name, data => {
				if (!data || !graph || !data.request.startsWith(".")) return;
				const issuer = data.dependencies?.[0] ? compilation.moduleGraph.getParentModule(data.dependencies[0]) : null;
				const parent = outputOf(graph, issuer?.resource ?? data.contextInfo.issuer ?? "");
				if (!parent) return;
				const target = graph.byOutput.get(canonicalPath(resolve(dirname(parent), stripQuery(data.request))));
				if (target) data.request = withInstance(target.source, target.instance);
			});

			compilation.hooks.processAssets.tap({ name, stage: compiler.webpack.Compilation.PROCESS_ASSETS_STAGE_ADDITIONAL }, () => {
				if (failure || options.declaration !== true) return;
				for (const declaration of graph.declarations) {
					compilation.emitAsset(declaration.out, new compiler.webpack.sources.RawSource(declaration.text));
				}
			});
		});
	}
}
