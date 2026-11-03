import { printGlsl, frameGlsl } from "./glsl";
import { printWgsl, frameWgsl } from "./wgsl";
import { printMsl } from "./msl";

export function stageText(target: int32, n: int32): string {
	if (target == 0) return printGlsl(n);
	if (target == 1) return printWgsl(n);
	return printMsl(n);
}

export function frames(n: int32): string {
	return frameGlsl(n) + frameWgsl(n);
}
