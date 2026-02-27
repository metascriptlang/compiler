// MetaScript Compiler CLI — compile command

import { exit } from "std/process";
import { parseSource } from "../parser/statements/validation";
import { Node, NodeKind, ProgramData } from "../ast/node";
import { CheckerContext, hasErrors, errorCount } from "../checker/context";
import { checkProgram } from "../checker/checkPass";
import { transformProgram } from "../transform/index";
import { analyzeProgram } from "../analyzer/index";
import { generateJS } from "../codegen/js/index";
import { Target } from "./options";
import { readSource, writeOutput } from "./io";

export function cmdCompile(filePath: string, target: Target, outputPath: string): void {
	const source = readSource(filePath);

	if (target === Target.JS) {
		// JS path: parse -> check -> transform -> generateJS (no analyzer)
		const parseResult = parseSource(source);
		if (!parseResult.ok) {
			console.log("Parse error: " + parseResult.error);
			exit(1);
		}
		const program = parseResult.value;
		const checkerCtx = checkProgram(program);
		if (hasErrors(checkerCtx)) {
			let i = 0;
			while (i < checkerCtx.errors.length) {
				console.log("Type error: " + checkerCtx.errors[i]);
				i += 1;
			}
			exit(1);
		}
		const transformed = transformProgram(program, checkerCtx);
		const jsCode = generateJS(transformed);

		if (outputPath !== "") {
			writeOutput(outputPath, jsCode);
			console.log("Wrote " + outputPath);
		} else {
			// Default output: replace .ms with .js
			const outFile = filePath.slice(0, filePath.length - 3) + ".js";
			writeOutput(outFile, jsCode);
			console.log("Wrote " + outFile);
		}
	} else {
		// C path: parse -> check -> transform -> analyze -> generateC
		const parseResult = parseSource(source);
		if (!parseResult.ok) {
			console.log("Parse error: " + parseResult.error);
			exit(1);
		}
		const program = parseResult.value;
		const checkerCtx = checkProgram(program);
		if (hasErrors(checkerCtx)) {
			let i = 0;
			while (i < checkerCtx.errors.length) {
				console.log("Type error: " + checkerCtx.errors[i]);
				i += 1;
			}
			exit(1);
		}
		const transformed = transformProgram(program, checkerCtx);
		const analyzed = analyzeProgram(transformed, checkerCtx);
		// C codegen not yet implemented
		console.log("Error: C backend codegen not yet implemented");
		console.log("Use --target=js for JavaScript output");
		exit(1);
	}
}
