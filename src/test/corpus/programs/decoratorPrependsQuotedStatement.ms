// @stdout: enter
// @stdout: deposit 5
// @stdout: enter if
// @stdout: calls 2
import { Node, ClassMethodDecoratorContext } from "std/meta";

let calls = 0;

macro traced(value: Node, context: ClassMethodDecoratorContext): Node {
	const body: Node[] = [quote { console.log("enter"); }];
	body.push(quote { calls = calls + 1; });
	for (const statement of value.methodBody.statements) {
		body.push(statement);
	}
	body.push(quote { if (true) { console.log("enter if"); } });
	body.push(quote { calls += 1; });
	body.push(quote { amount as int64; });
	body.push(quote { console.log("calls " + calls); });
	value.methodBody.statements = body;
	return value;
}

class Account {
	@traced
	deposit(amount: int32): void {
		console.log("deposit " + amount);
	}
}

new Account().deposit(5);
