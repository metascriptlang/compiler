import type { Plugin } from "rollup";
import type { CompilerOptions, SourceDeclarationOptions } from "./compilerCore.js";

export interface MetaScriptRollupOptions extends Omit<CompilerOptions, "entry" | "sourceRoot"> {
	readonly entry?: string | readonly string[];
	readonly sourceDeclarations?: SourceDeclarationOptions;
}

export default function metascript(options?: MetaScriptRollupOptions): Plugin;
