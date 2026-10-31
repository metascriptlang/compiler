// @stdout: string:x number:7 abstract:y echo echoecho

class OverloadedConstructor {
	value: string;
	constructor(value: string);
	constructor(value: int32);
	constructor(value: string | int32) {
		if (typeof value == "string") {
			this.value = "string:" + value;
		} else {
			this.value = "number:" + value.toString();
		}
	}
}

abstract class AbstractConstructor {
	value: string;
	constructor(value: string);
	constructor(value: string) {
		this.value = "abstract:" + value;
	}
}
class InheritedConstructor extends AbstractConstructor {}

class ArityConstructor {
	value: string;
	constructor(value: string);
	constructor(value: string, count: int32);
	constructor(value: string, count: int32 = 1) {
		this.value = value.repeat(count);
	}
}

const text = new OverloadedConstructor("x");
const numeric = new OverloadedConstructor(7);
const inherited = new InheritedConstructor("y");
const one = new ArityConstructor("echo");
const two = new ArityConstructor("echo", 2);
const result = `${text.value} ${numeric.value} ${inherited.value} ${one.value} ${two.value}`;
if (result != "string:x number:7 abstract:y echo echoecho") {
	throw new Error(
		"constructor overload changed its implementation or arguments",
	);
}
console.log(result);
