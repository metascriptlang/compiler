import type { Compiler } from "webpack";
import type { CompilerOptions, SourceDeclarationOptions } from "./compilerCore.js";

export type MetaScriptWebpackOptions = Omit<CompilerOptions, "sourceRoot"> & { readonly sourceDeclarations?: SourceDeclarationOptions };
export const loader: string;
export default class MetaScriptPlugin {
	constructor(options: MetaScriptWebpackOptions);
	apply(compiler: Compiler): void;
}
