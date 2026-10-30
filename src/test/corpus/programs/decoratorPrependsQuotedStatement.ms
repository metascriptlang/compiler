// @stdout: enter
// @stdout: deposit 5
// @stdout: enter if
import { Node, ClassMethodDecoratorContext } from "std/meta";

macro traced(value: Node, context: ClassMethodDecoratorContext): Node {
	const body: Node[] = [quote { console.log("enter"); }];
	for (const statement of value.methodBody.statements) {
		body.push(statement);
	}
	body.push(quote { if (true) { console.log("enter if"); } });
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
