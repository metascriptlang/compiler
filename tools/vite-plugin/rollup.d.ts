import type { Plugin } from "rollup";
import type { CompilerOptions } from "./compilerCore.js";

export interface MetaScriptRollupOptions extends Omit<CompilerOptions, "entry"> {
	readonly entry?: string;
}

export default function metascript(options?: MetaScriptRollupOptions): Plugin;
