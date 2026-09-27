// Symptom: `Block.create()` failed with "Property 'create' does not exist on type 'Block'" when a module exported `create(this typeof Pet)` and `create(this typeof Block)`, and an importer could call either as a bare `create()`.
// Root cause: the export list kept one entry per name and a static extension belongs to no overload set, so only the first static of a name was exported; an importer put that static in its own scope, where the declaring module never does.
// Fix: every exported static extension is carried on its own, and an import registers it as an extension without binding the name.
import { checkProjectDiagnostics, MapEntry } from "../helpers";

const LIB227 = `export struct Pet { hunger: uint16; }
export struct Block { id: uint32; }
export function create(x: int32): int32 { return x + 1; }
export function create(this typeof Pet): Pet { return { hunger: 7 }; }
export function create(this typeof Block): Block { return { id: 9 }; }
export function make(this typeof Pet): Pet { return { hunger: 3 }; }
`;

function diagnostics227(mainSource: string): string {
	const entries: MapEntry[] = [
		{ entryPath: "src/lib.ms", entrySource: LIB227 },
		{ entryPath: "src/main.ms", entrySource: mainSource },
	];
	return checkProjectDiagnostics(entries, "src/main.ms").join("\n");
}

test "bug227: every static extension of one name reaches the importer" {
	const d = diagnostics227(`import { Pet, Block, create } from "./lib";
const b: uint32 = Block.create().id;
const p: uint16 = Pet.create().hunger;
const n: int32 = create(4);
`);
	assert d == "", d;
}

test "bug227: a namespace import sees every static extension" {
	const d = diagnostics227(`import * as lib from "./lib";
const b: uint32 = lib.Block.create().id;
const p: uint16 = lib.Pet.create().hunger;
`);
	assert d == "", d;
}

test "bug227: an imported static extension is not a bare function" {
	const d = diagnostics227(`import { Pet, make } from "./lib";
const p: Pet = make();
`);
	assert d.contains("Undefined variable 'make'"), d;
	const named = diagnostics227(`import { Pet, make } from "./lib";
const p: uint16 = Pet.make().hunger;
`);
	assert named == "", named;
}
