import { BoundaryCallback, BoundaryFunction, BoundaryKind, BoundaryLeaf, BoundaryMode, BoundaryParam, Manifest, signatureLetter } from "./manifest";
import { jsBindings } from "./jsSide";
import { wasmEntrySource } from "./wasmSide";

enum Position {
	Param,
	Result,
	CallbackParam,
	CallbackResult,
	StructLeaf,
	StructResultLeaf,
	VecElement,
	VecResultElement,
	SpanElement,
	CallbackSpanElement,
}

const ALL_KINDS: BoundaryKind[] = [
	BoundaryKind.Bool, BoundaryKind.I8, BoundaryKind.I16, BoundaryKind.I32, BoundaryKind.U8, BoundaryKind.U16,
	BoundaryKind.U32, BoundaryKind.I64, BoundaryKind.U64, BoundaryKind.F32, BoundaryKind.F64, BoundaryKind.Void,
	BoundaryKind.Callback, BoundaryKind.String, BoundaryKind.Struct, BoundaryKind.Vec, BoundaryKind.Span,
];

const SCALARS: BoundaryKind[] = [
	BoundaryKind.Bool, BoundaryKind.I8, BoundaryKind.I16, BoundaryKind.I32, BoundaryKind.U8, BoundaryKind.U16,
	BoundaryKind.U32, BoundaryKind.I64, BoundaryKind.U64, BoundaryKind.F32, BoundaryKind.F64,
];

const ALL_POSITIONS: Position[] = [
	Position.Param, Position.Result, Position.CallbackParam, Position.CallbackResult, Position.StructLeaf,
	Position.StructResultLeaf, Position.VecElement, Position.VecResultElement, Position.SpanElement,
	Position.CallbackSpanElement,
];

function accepts(kind: BoundaryKind, at: Position): boolean {
	return match (kind) {
		BoundaryKind.Bool
			| BoundaryKind.I8
			| BoundaryKind.I16
			| BoundaryKind.I32
			| BoundaryKind.U8
			| BoundaryKind.U16
			| BoundaryKind.U32
			| BoundaryKind.I64
			| BoundaryKind.U64
			| BoundaryKind.F32
			| BoundaryKind.F64 => true,
		BoundaryKind.Void => at == Position.Result || at == Position.CallbackResult,
		BoundaryKind.String => at == Position.Param || at == Position.Result || at == Position.CallbackParam
			|| at == Position.StructLeaf || at == Position.StructResultLeaf,
		BoundaryKind.Callback => at == Position.Param,
		BoundaryKind.Struct | BoundaryKind.Vec => at == Position.Param || at == Position.Result,
		BoundaryKind.Span => at == Position.Param || at == Position.CallbackParam,
	};
}

function placeholderLetterOf(kind: BoundaryKind): string {
	try {
		return signatureLetter(kind);
	} catch {
		return "i";
	}
}

function callbackOf(params: BoundaryKind[], elements: BoundaryKind[], modes: BoundaryMode[], result: BoundaryKind): BoundaryCallback {
	let letters = "";
	for (const p of params) letters += placeholderLetterOf(p);
	return { params, elements, modes, result, signature: placeholderLetterOf(result) + "_" + letters };
}

function plainCallback(): BoundaryCallback {
	return callbackOf([BoundaryKind.I32], [BoundaryKind.Void], [BoundaryMode.Copied], BoundaryKind.Void);
}

function paramOf(name: string, kind: BoundaryKind, leaves: BoundaryLeaf[], element: BoundaryKind): BoundaryParam {
	const mode = kind == BoundaryKind.Span ? BoundaryMode.Shared : kind == BoundaryKind.Callback ? BoundaryMode.Borrowed : BoundaryMode.Copied;
	return { name, kind, mode, callback: kind == BoundaryKind.Callback ? plainCallback() : null, leaves, element };
}

function leavesOf(kind: BoundaryKind): BoundaryLeaf[] {
	return [{ path: ["x"], kind }];
}

function functionOf(params: BoundaryParam[], result: BoundaryKind, resultLeaves: BoundaryLeaf[], resultElement: BoundaryKind): BoundaryFunction {
	return { modulePath: "/p/calc.ms", moduleKey: "calc", name: "f", exportSymbol: "msb_calc_f", params, result, resultLeaves, resultElement };
}

function functionAt(kind: BoundaryKind, at: Position): BoundaryFunction {
	const none = BoundaryKind.Void;
	const i32 = BoundaryKind.I32;
	const shape = (k: BoundaryKind): BoundaryParam => paramOf("a", k, k == BoundaryKind.Struct ? leavesOf(i32) : [], k == BoundaryKind.Vec || k == BoundaryKind.Span ? i32 : none);
	return match (at) {
		Position.Param => functionOf([shape(kind)], none, [], none),
		Position.Result => functionOf([], kind, kind == BoundaryKind.Struct ? leavesOf(i32) : [], kind == BoundaryKind.Vec ? i32 : none),
		Position.CallbackParam => functionOfCallback(callbackOf([kind], [kind == BoundaryKind.Span ? i32 : none], [kind == BoundaryKind.Span ? BoundaryMode.Shared : BoundaryMode.Copied], none)),
		Position.CallbackResult => functionOfCallback(callbackOf([], [], [], kind)),
		Position.StructLeaf => functionOf([paramOf("a", BoundaryKind.Struct, leavesOf(kind), none)], none, [], none),
		Position.StructResultLeaf => functionOf([], BoundaryKind.Struct, leavesOf(kind), none),
		Position.VecElement => functionOf([paramOf("a", BoundaryKind.Vec, [], kind)], none, [], none),
		Position.VecResultElement => functionOf([], BoundaryKind.Vec, [], kind),
		Position.SpanElement => functionOf([paramOf("a", BoundaryKind.Span, [], kind)], none, [], none),
		Position.CallbackSpanElement => functionOfCallback(callbackOf([BoundaryKind.Span], [kind], [BoundaryMode.Shared], none)),
	};
}

function functionOfCallback(cb: BoundaryCallback): BoundaryFunction {
	const p: BoundaryParam = { name: "a", kind: BoundaryKind.Callback, mode: BoundaryMode.Borrowed, callback: cb, leaves: [], element: BoundaryKind.Void };
	return functionOf([p], BoundaryKind.Void, [], BoundaryKind.Void);
}

function emitted(fn: BoundaryFunction, jsSide: boolean): string {
	const m: Manifest = { functions: [fn], errors: [] };
	try {
		if (jsSide) jsBindings(m, "./app.wasm.mjs", (f) => "bundled_" + f.name, { checked: false });
		else wasmEntrySource(m.functions, (p: string) => "./calc");
	} catch (e) {
		return e.message;
	}
	return "";
}

test "wire kinds: the kind list is dense and ends where the enum ends, so a kind added to the enum cannot hide from the matrix" {
	for (let i = 0; i < ALL_KINDS.length; i += 1) assert (ALL_KINDS[i] as int32) == i, `ALL_KINDS[${i}] is ${BoundaryKind[ALL_KINDS[i]]}`;
	let past: int32 = 0;
	for (let i = 0; i < ALL_KINDS.length; i += 1) past += 1;
	const far: int32 = past + 1000;
	assert BoundaryKind[past] == BoundaryKind[far], `BoundaryKind has a member at ${past} that ALL_KINDS lacks: ${BoundaryKind[past]}`;
}

test "wire kinds: every kind in every position is emitted or refused naming the kind, by each side alone" {
	for (const jsSide of [true, false]) {
		for (const kind of ALL_KINDS) {
			for (const at of ALL_POSITIONS) {
				const message = emitted(functionAt(kind, at), jsSide);
				const cell = `${jsSide ? "js" : "wasm"} side, ${BoundaryKind[kind]} at ${Position[at]}`;
				if (accepts(kind, at)) {
					assert message == "", `${cell} must emit, got: ${message}`;
				} else {
					assert message.startsWith(`internal: boundary kind ${BoundaryKind[kind]} has no `), `${cell} must be refused naming the kind, got: '${message}'`;
				}
			}
		}
	}
}

const WASM_CALL = "__msbMod._msb_calc_f()";

function resultCode(kind: BoundaryKind): string {
	const m: Manifest = { functions: [functionOf([], kind, [], BoundaryKind.Void)], errors: [] };
	return jsBindings(m, "./app.wasm.mjs", (f) => "bundled_" + f.name, { checked: false }).modules[0].code;
}

test "js side: every scalar result is converted from the wasm side as listed" {
	const expected: string[] = [
		`${WASM_CALL} !== 0`,
		`(${WASM_CALL} << 24) >> 24`,
		`(${WASM_CALL} << 16) >> 16`,
		WASM_CALL,
		`${WASM_CALL} & 255`,
		`${WASM_CALL} & 65535`,
		`${WASM_CALL} >>> 0`,
		WASM_CALL,
		`BigInt.asUintN(64, ${WASM_CALL})`,
		WASM_CALL,
		WASM_CALL,
	];
	for (let i = 0; i < SCALARS.length; i += 1) {
		const code = resultCode(SCALARS[i]);
		assert code.includes(`\treturn ${expected[i]};\n`), `${BoundaryKind[SCALARS[i]]}: ${code}`;
	}
}

test "js side: every scalar parameter is passed to the wasm side as listed" {
	const params: BoundaryParam[] = [];
	for (let i = 0; i < SCALARS.length; i += 1) params.push(paramOf(`p${i}`, SCALARS[i], [], BoundaryKind.Void));
	const m: Manifest = { functions: [functionOf(params, BoundaryKind.Void, [], BoundaryKind.Void)], errors: [] };
	const code = jsBindings(m, "./app.wasm.mjs", (f) => "bundled_" + f.name, { checked: false }).modules[0].code;
	assert code.includes("__msbMod._msb_calc_f((a0 ? 1 : 0), a1, a2, a3, a4, a5, a6, a7, a8, a9, a10);"), code;
}

test "js side: every scalar callback parameter arrives converted and every scalar callback result is passed back as listed" {
	const elements: BoundaryKind[] = [];
	const modes: BoundaryMode[] = [];
	for (let i = 0; i < SCALARS.length; i += 1) {
		elements.push(BoundaryKind.Void);
		modes.push(BoundaryMode.Copied);
	}
	const viaParams = jsBindings({ functions: [functionOfCallback(callbackOf(SCALARS, elements, modes, BoundaryKind.Void))], errors: [] }, "./app.wasm.mjs", (f) => "bundled_" + f.name, { checked: false }).modules[0].code;
	assert viaParams.includes("__msb.push((x0, x1, x2, x3, x4, x5, x6, x7, x8, x9, x10) => { a0(x0 !== 0, (x1 << 24) >> 24, (x2 << 16) >> 16, x3, x4 & 255, x5 & 65535, x6 >>> 0, x7, BigInt.asUintN(64, x8), x9, x10); });"), viaParams;
	const viaBool = jsBindings({ functions: [functionOfCallback(callbackOf([], [], [], BoundaryKind.Bool))], errors: [] }, "./app.wasm.mjs", (f) => "bundled_" + f.name, { checked: false }).modules[0].code;
	assert viaBool.includes("__msb.push(() => (a0() ? 1 : 0));"), viaBool;
	const viaU64 = jsBindings({ functions: [functionOfCallback(callbackOf([], [], [], BoundaryKind.U64))], errors: [] }, "./app.wasm.mjs", (f) => "bundled_" + f.name, { checked: false }).modules[0].code;
	assert viaU64.includes("__msb.push(a0);"), viaU64;
}
