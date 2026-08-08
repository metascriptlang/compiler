// bug097 — cross-module union alias: defining TU lacked the union typedef
//
// Symptom:    JSON.parse<Shape> with `type Shape = Circle | Square` imported
//             from another module failed the C compile with `unknown type
//             name 'Shape'` — in the DEFINING module's TU, not the consumer.
// Root cause: ensureDrcProto (src/codegen/c/forward.ms) synthesizes hook
//             prototypes from the callee NAME; the defining module's TypeInfo
//             DatInit references ShapeDestroy without ever running
//             getTypeDesc(Shape) there, and the opaque-typedef escape hatch
//             existed only for msAnon_* hooks.
// Fix:        emit the opaque `typedef struct X X;` for pointer-suffix hooks
//             (Destroy/WasMoved/Copy/Sink/Trace) on user-named types too.
//
// This test pins the front-end path (project compiles to C text without
// ERROR). The load-bearing red/green pin is corpus 513-jsonUnionAlias, where
// clang actually compiles the two TUs — the pre-fix failure was a C-compile
// error invisible to C-text assertions (the consumer TU legitimately carries
// the same typedef, so substring presence cannot discriminate).

import { compileProjectToCWithStd, MapEntry } from "../helpers";

test "bug097: union alias through JSON.parse across modules reaches C" {
	const entries: MapEntry[] = [
		{ entryPath: "src/shapes.ms", entrySource: `
			export interface Circle { kind: "circle"; r: float64; }
			export interface Square { kind: "square"; side: float64; }
			export type Shape = Circle | Square;
		` },
		{ entryPath: "src/main.ms", entrySource: `
			import { Shape } from "./shapes";
			function main(): void {
				const r = JSON.parse<Shape>(\`{"kind":"circle","r":2.0}\`);
				console.log(r.ok ? "decoded" : "failed");
			}
			main();
		` },
	];
	const cCode = compileProjectToCWithStd(entries, "src/main.ms");
	assert !cCode.contains("ERROR:");
	assert cCode.contains("ShapeDestroy");
}
