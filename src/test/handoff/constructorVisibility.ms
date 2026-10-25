import { checkProjectDiagnostics, MapEntry } from "../helpers";

function diagnostics(main: string): string[] {
	const entries: MapEntry[] = [
		{ entryPath: "src/main.ms", entrySource: main },
	];
	return checkProjectDiagnostics(entries, "src/main.ms");
}

function reports(main: string, needle: string): boolean {
	for (const m of diagnostics(main)) {
		if (m.indexOf(needle) >= 0) return true;
	}
	return false;
}

const privateToken = "class Token {\n\tprivate constructor() {}\n\tstatic make(): Token { return new Token(); }\n}\n";
const protectedShape = "class Shape {\n\tsides: int32 = 0;\n\tprotected constructor(n: int32) { this.sides = n; }\n}\nclass Square extends Shape {\n\tconstructor() { super(4); }\n\tstatic other(): Shape { return new Square(); }\n}\n";

test "constructorVisibility: a private constructor is called inside its class only" {
	const privateCtor = "Constructor of class 'Token' is private and only accessible within the class declaration";
	assert diagnostics(privateToken + "console.log(Token.make() != null);\n").length == 0;
	assert reports(privateToken + "console.log(new Token() != null);\n", privateCtor);
	assert reports(privateToken + "function build(): Token { return new Token(); }\nconsole.log(build() != null);\n", privateCtor);
	const generic = "class Box<T> {\n\tv: T;\n\tprivate constructor(v: T) { this.v = v; }\n\tstatic of<T>(v: T): Box<T> { return new Box<T>(v); }\n}\n";
	assert diagnostics(generic + "console.log(Box.of<int32>(3).v);\n").length == 0;
	assert reports(generic + "console.log(new Box<int32>(3).v);\n", "Constructor of class 'Box' is private");
}

test "constructorVisibility: a protected constructor is called inside its class and its subclasses" {
	assert diagnostics(protectedShape + "console.log(new Square().sides, Square.other().sides);\n").length == 0;
	assert reports(protectedShape + "console.log(new Shape(3).sides);\n", "Constructor of class 'Shape' is protected and only accessible within the class declaration");
	const inherited = "class Base {\n\tn: int32 = 0;\n\tprotected constructor() {}\n}\nclass Sub extends Base {\n\tstatic make(): Sub { return new Sub(); }\n}\n";
	assert diagnostics(inherited + "console.log(Sub.make().n);\n").length == 0;
	assert reports(inherited + "console.log(new Sub().n);\n", "Constructor of class 'Base' is protected");
}

test "constructorVisibility: a class with a private constructor cannot be extended" {
	assert reports(privateToken + "class Sub extends Token {}\nconsole.log(Token.make() != null);\n", "Cannot extend a class 'Token'. Class constructor is marked as private");
}
