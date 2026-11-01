import type { Plugin } from "vite";
import type { SourceDeclarationOptions } from "./compilerCore.js";

export interface MetaScriptOptions {
	readonly msc?: string;
	readonly entry?: string | readonly string[];
	readonly sourceDeclarations?: SourceDeclarationOptions;
	readonly outDir?: string;
	readonly compilerArgs?: readonly string[];
	readonly quiet?: boolean;
	readonly sourcemap?: boolean;
	/** Publish compiler declarations as build assets, not source-import editor sidecars. */
	readonly declaration?: boolean;
}

export default function metascript(options?: MetaScriptOptions): Plugin;
