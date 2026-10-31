import type { Compiler } from "webpack";
import type { CompilerOptions } from "./compilerCore.js";

export type MetaScriptWebpackOptions = CompilerOptions;
export const loader: string;
export default class MetaScriptPlugin {
	constructor(options: MetaScriptWebpackOptions);
	apply(compiler: Compiler): void;
}
