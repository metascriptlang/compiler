// MetaScript Compiler CLI — compile command

import { exit } from "std/process";
import { parseSource } from "../parser/statements/validation";
import { Node, NodeKind, ProgramData } from "../ast/node";
import { CheckerContext, hasErrors, errorCount } from "../checker/context";
import { checkProgram } from "../checker/checkPass";
import { transformProgram } from "../transform/index";
import { analyzeProgram } from "../analyzer/index";
import { monomorphizeProgram } from "../monomorphize/collect";
import { generateJS } from "../codegen/js/index";
import { generateC } from "../codegen/c/index";
import { transformForNative } from "../transform/native/index";
import { createTransformContextWithChecker } from "../transform/context";
import { Target } from "./options";
import { readSource, printErrorsAndExit, emitOutput } from "./io";
import { error } from "../utils/color";

export function cmdCompile(filePath: string, target: Target, outputPath: string): void {
	const source = readSource(filePath);

	const parseResult = parseSource(source);
	if (!parseResult.ok) {
		console.log(error("parse error") + ": " + parseResult.error);
		exit(1);
	}
	const program = parseResult.value;

	const checkerCtx = checkProgram(program);
	if (hasErrors(checkerCtx)) {
		printErrorsAndExit(checkerCtx, "Type error: ");
	}

	const monoed = monomorphizeProgram(program, checkerCtx);
	const transformed = transformProgram(monoed, checkerCtx);

	if (target === Target.JS) {
		const jsCode = generateJS(transformed);
		emitOutput(jsCode, filePath, outputPath, ".js");
	} else {
		const nativeCtx = createTransformContextWithChecker(checkerCtx);
		const nativeTransformed = transformForNative(transformed, nativeCtx);
		const analyzed = analyzeProgram(nativeTransformed, checkerCtx);
		const cCode = generateC(analyzed, checkerCtx, filePath);
		emitOutput(cCode, filePath, outputPath, ".c");
	}
}
