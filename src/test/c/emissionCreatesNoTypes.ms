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

test "sets and enums are laid out and named without creating a type while they are emitted" {
	const entries: MapEntry[] = [
		{ entryPath: "src/main.ms", entrySource: `
			enum Three { A, B, C }
			enum Twelve { M0, M1, M2, M3, M4, M5, M6, M7, M8, M9, M10, M11 }
			enum Forty { F0, F1, F2, F3, F4, F5, F6, F7, F8, F9, F10, F11, F12, F13, F14, F15, F16, F17, F18, F19, F20, F21, F22, F23, F24, F25, F26, F27, F28, F29, F30, F31, F32, F33, F34, F35, F36, F37, F38, F39 }
			enum Hundred { H0, H1, H2, H3, H4, H5, H6, H7, H8, H9, H10, H11, H12, H13, H14, H15, H16, H17, H18, H19, H20, H21, H22, H23, H24, H25, H26, H27, H28, H29, H30, H31, H32, H33, H34, H35, H36, H37, H38, H39, H40, H41, H42, H43, H44, H45, H46, H47, H48, H49, H50, H51, H52, H53, H54, H55, H56, H57, H58, H59, H60, H61, H62, H63, H64, H65, H66, H67, H68, H69, H70, H71, H72, H73, H74, H75, H76, H77, H78, H79, H80, H81, H82, H83, H84, H85, H86, H87, H88, H89, H90, H91, H92, H93, H94, H95, H96, H97, H98, H99 }
			struct Wide { a: Three; b: BitSet<Three>; c: BitSet<Twelve>; d: BitSet<Forty>; e: BitSet<Hundred>; f: Twelve; }
			function pick(on: boolean, s: BitSet<Three>): BitSet<Three> | null { return on ? s : null; }
			function widest(w: Wide): BitSet<Hundred> { return w.e; }
			const w: Wide = { a: Three.B, b: Three.A | Three.C, c: Twelve.M11 | Twelve.M0, d: Forty.F39 | Forty.F1, e: Hundred.H99 | Hundred.H0, f: Twelve.M3 };
			const sets: BitSet<Three>[] = [w.b, 0 as BitSet<Three>];
			const p = pick(true, w.b);
			console.log(\`\${w.a},\${w.b.has(Three.C)},\${w.c.has(Twelve.M11)},\${w.d.has(Forty.F39)},\${widest(w).has(Hundred.H99)},\${sets.length},\${p != null},\${w.f}\`);
		` },
	];
	const c = compileProjectToC(entries, "src/main.ms");
	assert !c.startsWith("ERROR:");
	assert c.contains("msSizedArray_uint8_t_13 e;");
	assert c.contains("uint64_t d;");
}
