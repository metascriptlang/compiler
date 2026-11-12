import { MacroDeclData } from "./node";

const MACRO_RECEIVER_PREFIX = "this:";

export function macroTakesReceiver(decl: MacroDeclData): boolean {
	return decl.macroDeclParams.length > 0 && decl.macroDeclParams[0].startsWith(MACRO_RECEIVER_PREFIX);
}

export function macroParamNames(decl: MacroDeclData): string[] {
	if (!macroTakesReceiver(decl)) return decl.macroDeclParams;
	const names = decl.macroDeclParams.slice(0);
	names[0] = names[0].slice(MACRO_RECEIVER_PREFIX.length, names[0].length);
	return names;
}
