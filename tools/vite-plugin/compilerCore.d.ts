export interface CompilerOptions {
	readonly entry: string | readonly string[];
	readonly root?: string;
	readonly outDir?: string;
	readonly msc?: string;
	readonly compilerArgs?: readonly string[];
	readonly sourcemap?: boolean;
	readonly declaration?: boolean;
	readonly sourceRoot?: string;
	readonly quiet?: boolean;
}

export type JSONValue = null | boolean | number | string | readonly JSONValue[] | { readonly [key: string]: JSONValue };

export interface SourceMap {
	readonly sources: readonly string[];
	readonly [key: string]: JSONValue;
}

export interface ModuleOutput {
	readonly file: string;
	readonly out: string;
	readonly source: string;
	readonly instance: string;
	readonly code: string;
	readonly map: SourceMap | null;
}

export interface Artifact {
	readonly kind: "manifest" | "javascript" | "sourcemap" | "declaration" | "source-declaration" | "source-declaration-package";
	readonly file: string;
	readonly out: string;
	readonly text: string;
	readonly source?: string;
	readonly instance?: string;
}

export interface DeclarationOutput extends Artifact {
	readonly kind: "declaration";
	readonly source: string;
}

export interface SourceDeclarationOptions {
	readonly outDir: string;
	readonly rootDir?: string;
}

export interface SourceDeclarationOutput extends Artifact {
	readonly kind: "source-declaration";
	readonly source: string;
}

export interface LookupIndex<T> extends Iterable<[string, T]> {
	readonly size: number;
	get(key: string): T | undefined;
	has(key: string): boolean;
	keys(): IterableIterator<string>;
	values(): IterableIterator<T>;
	entries(): IterableIterator<[string, T]>;
}

export interface CompilerResult {
	readonly entry: string;
	readonly entries: readonly string[];
	readonly sourceDeclarationRoot: string | null;
	readonly sourceDeclarationPackage: Artifact | null;
	readonly sourceDeclarations: readonly SourceDeclarationOutput[];
	readonly outDir: string;
	readonly modules: readonly ModuleOutput[];
	readonly instances: readonly ModuleOutput[];
	readonly declarations: readonly DeclarationOutput[];
	readonly dependencies: readonly string[];
	readonly artifacts: readonly Artifact[];
	readonly bySource: LookupIndex<string>;
	readonly byInstance: LookupIndex<string>;
	readonly byOutput: LookupIndex<ModuleOutput>;
}

export function canonicalPath(path: string): string;
export function stripQuery(id: string): string;
export function instanceOf(id: string): string;
export function withInstance(path: string, instance: string): string;
export function outputOf(result: CompilerResult | null, id: string): string | undefined;
export function buildCompilerGraph(options: CompilerOptions): CompilerResult;

export function sourceRootOfOutput(root: string, file: string): string;
