// @stdout: 12|13|25|25|26,27|50|25
// note: a local, a parameter or an arrow parameter named like an extension does not capture a call of that extension, whether the extension is imported or declared in the same module, on every backend.
import { Shape } from "./shape";
import { Scaler, Vec } from "./vec";

function strideOf(source: Shape): int32 {
	const stride: int32 = source.stride();
	return stride;
}
function widthOf(source: Shape): int32 {
	const width: int32 = source.width();
	return width;
}
function lengthOf(a: Vec): number {
	const lengthSquared = a.lengthSquared();
	return lengthSquared;
}

const source: Shape = { value: 12 };
const a: Vec = { x: 3, y: 4 };
const parts: string[] = [];
parts.push(`${strideOf(source)}`);
parts.push(`${widthOf(source)}`);
parts.push(`${a.normalizedLength()}`);
parts.push(`${lengthOf(a)}`);
parts.push(a.plusEach([1, 2]).join(","));
parts.push(`${new Scaler(2).scaled(a)}`);
parts.push(`${a.lengthSquared()}`);
console.log(parts.join("|"));
