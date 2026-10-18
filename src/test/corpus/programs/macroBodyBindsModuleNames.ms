// @stdout: 104 7
// note: a decorator body and a macro body bind the module's own names, not the names of the wrapper the compiler runs them in: a module function spelled `__macroBody`, a module function `sink` and a module constant `name`.
import { Node, NodeKind, ClassDecoratorContext } from "std/meta";

function __macroBody(): int32 { return 100; }
function sink(): int32 { return 2; }
const name: string = "module-name";

macro seven(): Node {
	const k = __macroBody();
	return { kind: NodeKind.NumberLiteral, line: 0, column: 0, value: 4 + k, isFloat: false };
}

macro keep(value: Node, context: ClassDecoratorContext): Node {
	if (sink() != 2 || name != "module-name") throw new Error(`the decorator body read the wrapper's names`);
	return value;
}

@keep
class Box { v: int32 = 7; }

console.log(`${seven()} ${new Box().v}`);
