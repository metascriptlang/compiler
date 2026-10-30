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

const named = "interface Named {\n\tname: string;\n}\n";
const use = "const d = new Dog();\nconsole.log(d.legs);\n";

test "classExtendsInterface: a class extends a class and implements an interface" {
	assert diagnostics(named + "class Dog implements Named {\n\tname: string = \"a\";\n\tlegs: int32 = 4;\n}\n" + use).length == 0;
	assert diagnostics("class Animal {\n\tname: string = \"a\";\n}\nclass Dog extends Animal {\n\tlegs: int32 = 4;\n}\n" + use).length == 0;
	assert diagnostics(named + "interface Pet extends Named {\n\tage: int32;\n}\nconst p: Pet = { name: \"a\", age: 1 };\nconsole.log(p.age);\n").length == 0;
}

test "classExtendsInterface: a class cannot extend an interface" {
	assert reports(named + "class Dog extends Named {\n\tlegs: int32 = 4;\n}\n" + use, "Cannot extend an interface 'Named'. Did you mean 'implements'?");
	assert reports(named + "interface Pet extends Named {\n\tage: int32;\n}\nclass Dog extends Pet {\n\tlegs: int32 = 4;\n}\n" + use, "Cannot extend an interface 'Pet'. Did you mean 'implements'?");
	const box = "interface Box<T> {\n\tvalue: T;\n}\n";
	assert reports(box + "class Dog extends Box<int32> {\n\tlegs: int32 = 4;\n}\n" + use, "Cannot extend an interface 'Box'. Did you mean 'implements'?");
}

test "classExtendsInterface: a class whose fields trail an interface is not told to extend it" {
	const shape = "interface Named {\n\tname: string;\n\tage: int32;\n}\nclass Dog {\n\tage: int32 = 1;\n\tname: string = \"a\";\n\tlegs: int32 = 4;\n}\nfunction f(n: Named): void { console.log(n.name); }\nf(new Dog());\n";
	assert reports(shape, "must be a leading prefix of Dog — reorder its fields)");
	assert !reports(shape, "`extends Named`");
}
