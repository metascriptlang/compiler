// @stdout: in case
// @stdout: first
// @stdout: in default
// @stdout: other
import { Node, ClassMethodDecoratorContext } from "std/meta";

macro tracedCases(value: Node, context: ClassMethodDecoratorContext): Node {
	const sw = value.methodBody.statements[0];
	const first = sw.switchCases[0];
	const firstBody: Node[] = [quote { console.log("in case"); }];
	for (const statement of first.caseStmts) firstBody.push(statement);
	first.caseStmts = firstBody;
	const fallback = sw.switchCases[1];
	const fallbackBody: Node[] = [quote { console.log("in default"); }];
	for (const statement of fallback.caseStmts) fallbackBody.push(statement);
	fallback.caseStmts = fallbackBody;
	return value;
}

class Router {
	@tracedCases
	run(n: int32): void {
		switch (n) {
			case 1: console.log("first"); break;
			default: console.log("other"); break;
		}
	}
}

const router = new Router();
router.run(1);
router.run(2);
