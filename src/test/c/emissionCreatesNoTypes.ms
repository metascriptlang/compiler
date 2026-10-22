// Emission runs on worker threads and only reads the types the checker finished: walking
// every class chain for a dispatcher registers no union variant and builds no body.

import { compileProjectToC, lastEmissionCreated } from "../helpers";
import { MapEntry } from "../../module/loader";

test "a dispatched call walks every class chain without creating a type while it is emitted" {
	const entries: MapEntry[] = [
		{ entryPath: "src/main.ms", entrySource: `
			class Grand<T> {
				value: T;
				shape: { kind: "a"; x: T } | { kind: "b"; y: int32 } | null = null;
				constructor(value: T) { this.value = value; }
			}
			class Box<T> extends Grand<T> {}
			class Counted extends Box<int32> {
				describe(): string { return "counted"; }
			}
			class Animal {
				describe(): string { return "animal"; }
			}
			class Dog extends Animal {
				describe(): string { return "dog"; }
			}
			function show(a: Animal): string { return a.describe(); }
			console.log(show(new Dog()));
			console.log(new Counted(1).describe());
		` },
	];
	const c = compileProjectToC(entries, "src/main.ms");
	assert !c.startsWith("ERROR:");
	assert c.contains("msDisp_");
	const created = lastEmissionCreated();
	assert created[0] == 0;
	assert created[1] == 0;
}
