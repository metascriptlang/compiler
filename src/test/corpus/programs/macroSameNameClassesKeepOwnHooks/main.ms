// @stdout: glslwgslmsl gx0p01gx1p11gx2p21 wy01q00wy11q11wy21q22 mz010mz111mz212 fg012fw33
// @stdout: glslwgslmsl gx0p01gx1p11gx2p21 wy01q00wy11q11wy21q22 mz010mz111mz212 fg012fw33
// @exit: 0
// note: three modules each declare a class Printer of their own layout, two of them also an exported class Frame with a constructor, and one macro builds and drops them all through a helper module after a first call into each module. The engine compiles each class from a re-checked copy of its declaration; that copy took the module the engine was working in (desc.ms) as its own, so the copies of every Printer shared one type identity and one destroy hook, and a Printer was destroyed by another module's hook ("Printer__…desc…Destroy reads 'label' at slot 4 of a Printer that holds 'tail' there", a crash in a --danger msc). Each copy now keeps the identity of the class it copies.
import { Node, NodeKind } from "std/meta";
import { stageText, frames } from "./desc";
import { glslName } from "./glsl";
import { wgslName } from "./wgsl";
import { mslName } from "./msl";

function every(n: int32): string {
	return glslName() + wgslName() + mslName() + " " + stageText(0, n) + " " + stageText(1, n) + " " + stageText(2, n) + " " + frames(n);
}

macro printed(): Node {
	return { kind: NodeKind.StringLiteral, line: 0, column: 0, value: every(3) };
}

console.log(printed());
console.log(every(3));
