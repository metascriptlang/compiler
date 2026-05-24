// bug036 — actor CALL returning struct/Result/Tuple emitted broken C
//
// Symptom:    Code like
//                 actor A {
//                     getR(): Result<number, string> { return Result.ok(42); }
//                 }
//             failed at C compile step with:
//                 error: too many arguments to function call,
//                        expected single argument 'this', have 2 arguments
//                 error: passing 'Result__number_string' to parameter of
//                        incompatible type 'void *'
//             Same shape for `struct V { ... }; getV(): V` and any value
//             layout return. PARALOCK Bug B Item 2 (task #67 deferred).
//
// Root cause: Two coupled gaps in src/transform/lowering/actorLower.ms:
//
//   (1) Classifier — typeMsgKind's `_ => "ptr"` fallthrough swept value
//       structs / Result / Tuple / value-GIs into msMsgCompletePtr,
//       which expects void* but received a struct VALUE. The IsStruct
//       flag (set by createStruct(...true)) is not the discriminator
//       because every struct AND interface sets it — `interface` is
//       Ref-wrapped at the symbol layer so its USAGE-site kind is Ref,
//       while value `struct` keeps TypeKind.Struct. The kind alone is
//       the correct discriminator.
//
//   (2) Proxy retType / sym retype — buildCallProxy emitted a proxy
//       that returned void* (msFuture pointer), but `proxyNode.nodeType`
//       was the original `T getR()`. The CALL site resolved through
//       `m.resolvedSym`, saw `Result` return, applied C-codegen NRVO
//       (`Result*` out-param), and emitted `proxyFn(&out, this)` —
//       2 args against a 1-arg proxy.
//
// Fix:        src/transform/lowering/actorLower.ms
//             - isValueLayoutType(t) — kind-based classifier (Tuple,
//               Struct, GI with body Struct/Union/Tuple)
//             - msgCompleteName "struct" → msMsgCompletePtr after
//               explicit msSinkBoxStruct boxing (mirror of "array")
//             - packArgsIntoMsg / dispatch reading: same box/unbox
//               pattern for value-layout params
//             - proxyRetType = createPromise(methodRetType) so call
//               site sees Promise<T>, no NRVO triggered
//             - m.resolvedSym.symbolType = proxyFnType so callers
//               picking up the sym see the new signature
//
// Pony parity: msg layout (pony_msg_t header) UNCHANGED. The boxing
//              is done at the actor-lowering layer using existing
//              asyncBridge machinery (msSinkBoxStruct/msUnboxStruct).
//              No new runtime symbol, no codegen intercept.
//
// PARALOCK:    §0 "Existing actor SEND/CALL message protocol" — preserved.
//              §7.6 COPY/MOVE/SHARE — Box-on-COPY for value structs at
//              actor boundary executes the COPY semantic.

import { compileToC, compileProjectToC } from "../helpers";

// These tests lock in the return-path AND param-path fixes for Bug B Item 2.
// PARAM tests use `move` to satisfy the checker's `isSendable` requirement
// for non-primitive-pure args (anonymous literals would be rejected — that's
// a separate, pre-existing constraint independent of the boxing path tested
// here).

test "bug036: value-struct PARAM via move — compile succeeds, ptr-routed" {
	// Struct args go through `move` (checker `isSendable` requires it for
	// non-primitive-pure types). The C backend's ccgIntroducedPtr passes
	// struct params by pointer, so the SEND side stores the pointer
	// directly via msMsgSetPtr — the boxing branch in packArgsIntoMsg only
	// triggers if a struct param somehow survives codegen as a VALUE
	// (defensive; not observed in current paths).
	const src = `
struct Bug036Cfg { x: int32; y: int32; }
actor Bug036C {
	configure(c: Bug036Cfg): void {}
}
const a = new Bug036C();
const cfg: Bug036Cfg = { x: 1, y: 2 };
a.configure(move cfg);
`;
	const result = compileToC(src);
	assert result.ok;
	if (result.ok) {
		// SEND side stores the param into the msg slot via msMsgSetPtr.
		assert result.value.indexOf("msMsgSetPtr") >= 0;
		// Receive side: dispatch reads ptr back via msMsgGetPtr.
		assert result.value.indexOf("msMsgGetPtr") >= 0;
		// Dispatch must call the impl with the recovered pointer arg.
		assert result.value.indexOf("Bug036C_configure_impl") >= 0;
	}
}

test "bug036: value-struct return — compile succeeds, no NRVO out-param leak" {
	const src = `
struct Bug036V { a: number; b: number; }
actor A {
	getV(): Bug036V { return { a: 1, b: 2 }; }
}
const a = new A();
const v = await a.getV();
console.log(v.a.toString());
`;
	const result = compileToC(src);
	// Pre-fix: failed at type-check or emitted invalid C. Post-fix: compiles.
	assert result.ok;
	if (result.ok) {
		// Caller must NOT pass an NRVO out-param to the proxy: proxy
		// returns void* (future pointer), not Bug036V. Pre-fix emitted
		// `A_getV_u0(&dollarfut_N_, a)` — 2 args to a 1-arg fn.
		assert result.value.indexOf("(&dollarfut") < 0;
		// Reply path: ptr-typed completion is used (not value-typed).
		assert result.value.indexOf("msMsgCompletePtr") >= 0;
	}
}

test "bug036: Result<T,E> return — compile succeeds" {
	const src = `
actor Bug036B {
	getR(): Result<number, string> { return Result.ok(42); }
}
const b = new Bug036B();
const r = await b.getR();
if (r.ok) console.log(r.value.toString());
`;
	const result = compileToC(src);
	// Pre-fix: Result<T,E> hit the value-layout fall-through, emitted
	// `msMsgCompletePtr(reply, _result)` where _result is the union
	// VALUE, type-incompatible with void*. Post-fix: classifier routes
	// it through the boxing path → compile succeeds.
	assert result.ok;
	if (result.ok) {
		assert result.value.indexOf("msMsgCompletePtr") >= 0;
	}
}

test "bug036: cross-module value-struct return — compile succeeds end-to-end" {
	// The Bug B Item 2 fix mutates `m.resolvedSym.symbolType` at transform
	// time so call sites see Promise<T> (no NRVO out-param). This test
	// exercises a CROSS-MODULE flow: actor defined in inner.ms, called from
	// main.ms — the mutation must propagate through the shared symbol so
	// the call site in main.ms also sees Promise<T>. Pre-fix this failed
	// at the C compile step with "too many arguments" because the call
	// site emitted an NRVO out-param against the void*-returning proxy.
	const entries = [
		{ entryPath: "src/inner.ms", entrySource: `
			export struct Bug036XV { a: int32; b: int32; }
			export actor Bug036XA {
				getV(): Bug036XV { return { a: 1, b: 2 }; }
			}
		` },
		{ entryPath: "src/main.ms", entrySource: `
			import { Bug036XA, Bug036XV } from "./inner";
			async function main(): Promise<void> {
				const a = new Bug036XA();
				const v = await a.getV();
				console.log(v.a.toString());
			}
			main();
		` },
	];
	const cCode = compileProjectToC(entries, "src/main.ms");
	// "ERROR:" is compileProjectToC's sentinel for any phase failure
	// (parse / check / monomorphize / validate). Pre-fix produced
	// check/transform errors at the main.ms call site.
	assert !cCode.contains("ERROR:");
}

test "bug036: interface (Ref-wrapped Struct) stays on ptr path — regression" {
	// Interface is `createStruct(..., true)` with IsStruct flag set, but
	// the symbol wraps it in Ref<Struct>, so the USAGE kind is Ref. The
	// classifier must NOT route it through the value-struct boxing path —
	// Ref<Struct> is already a pointer and fits in the void* slot directly.
	const src = `
interface Bug036Pt { x: number; y: number; }
actor Bug036D {
	getPt(): Bug036Pt { return { x: 3, y: 4 }; }
}
const d = new Bug036D();
const p = await d.getPt();
console.log(p.x.toString());
`;
	const result = compileToC(src);
	assert result.ok;
	if (result.ok) {
		// Interface (Ref<Struct>) flows through pointer types end-to-end.
		assert result.value.indexOf("Bug036Pt*") >= 0;
	}
}
