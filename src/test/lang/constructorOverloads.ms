class ConstructorChoice {
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

abstract class ConstructorParent {
	value: string;
	constructor(value: string);
	constructor(value: string) {
		this.value = value;
	}
}
class ConstructorChild extends ConstructorParent {}

class ConstructorArity {
	value: string;
	constructor(value: string);
	constructor(value: string, count: int32);
	constructor(value: string, count: int32 = 1) {
		this.value = value.repeat(count);
	}
}

test "constructor signatures call one implementation with either type" {
	assert new ConstructorChoice("x").value == "string:x";
	assert new ConstructorChoice(7).value == "number:7";
}

test "abstract class constructor overloads remain inheritable" {
	assert new ConstructorChild("kept").value == "kept";
}

test "constructor signatures preserve arity and literal defaults" {
	assert new ConstructorArity("echo").value == "echo";
	assert new ConstructorArity("echo", 2).value == "echoecho";
}
