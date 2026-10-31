import { mkdirSync, mkdtempSync, rmSync } from "node:fs";
import { dirname, isAbsolute, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { buildCompilerGraph, canonicalPath, outputOf, stripQuery, withInstance } from "./compilerCore.js";

export const loader = fileURLToPath(new URL("./webpackLoader.js", import.meta.url));
const implementationFiles = ["webpack.js", "webpackLoader.js", "compilerCore.js", "package.json"].map(file => fileURLToPath(new URL(file, import.meta.url)));
const name = "MetaScriptPlugin";

export default class MetaScriptPlugin {
	constructor(options) {
		if (!options || typeof options.entry !== "string" || !/\.(ms|jms)$/.test(options.entry)) {
			throw new Error("MetaScript webpack requires one explicit .ms or .jms entry");
		}
		this.options = { ...options, compilerArgs: options.compilerArgs ? [...options.compilerArgs] : undefined };
	}

	apply(compiler) {
		if (compiler.webpack?.version?.split(".")[0] !== "5") throw new Error("MetaScript requires webpack 5");
		const options = this.options;
		const root = resolve(options.root ?? compiler.context);
		const entry = canonicalPath(resolve(root, options.entry));
		let previousDependencies = [entry];
		compiler.hooks.thisCompilation.tap(name, (compilation, { normalModuleFactory }) => {
			let graph = null;
			let failure = null;
			for (const file of previousDependencies) compilation.fileDependencies.add(file);
			for (const file of implementationFiles) compilation.buildDependencies.add(file);
			if (options.msc && (isAbsolute(options.msc) || options.msc.includes("/") || options.msc.includes("\\"))) {
				compilation.buildDependencies.add(resolve(options.msc));
			}
			const workspace = resolve(root, options.outDir ?? "node_modules/.metascript");
			let temporary;
			try {
				mkdirSync(workspace, { recursive: true });
				temporary = canonicalPath(mkdtempSync(join(workspace, "webpack-")));
				graph = buildCompilerGraph({ ...options, root, entry, outDir: temporary });
				previousDependencies = graph.dependencies;
				for (const file of graph.dependencies) compilation.fileDependencies.add(file);
			} catch (error) {
				failure = error;
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
