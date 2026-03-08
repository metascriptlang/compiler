// Module System Hub — re-exports for module compilation

export {
	ModuleState, ImportEntry, Module, ModuleGraph,
	createModuleGraph, createModule, createImportEntry,
	findModule, findModuleIndex, addModule, hasModule,
	isInImportStack, pushImportStack, popImportStack,
	hasExportName,
} from "./graph";

export {
	ResolveCandidates, ResolverConfig, resolveImport, resolveImportWithConfig,
	backendExtension, createDefaultConfig, isStdImport,
	BACKEND_C, BACKEND_JS, BACKEND_RAISER, BACKEND_ERLANG, BACKEND_WASM,
} from "./resolver";

export {
	MapEntry, SourceProvider,
	createMapProvider, createFileSystemProvider, provideSource,
	loadModule, loadModuleGraph, loadModuleGraphWithConfig,
} from "./loader";
