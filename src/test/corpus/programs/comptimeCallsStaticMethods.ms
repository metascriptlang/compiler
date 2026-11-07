// @stdout: x! y! o!k | x!
// note: a static method runs at comptime through the class that declares it, called directly in a block, through a helper, and from another static method. Before, the engine lowered the method alone and stopped with "processStmt has no arm for MethodDecl".
class Mark {
	static get(n: string): string {
		return n + "!";
	}
	static twice(n: string, more: string): string {
		return Mark.get(n) + more;
	}
}

function viaHelper(): string {
	return Mark.get("y");
}

const DIRECT = @comptime { return Mark.get("x"); };
const HELPER = @comptime { return viaHelper(); };
const NESTED = @comptime { return Mark.twice("o", "k"); };

console.log(`${DIRECT} ${HELPER} ${NESTED} | ${Mark.get("x")}`);
