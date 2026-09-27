// nim-guard: a chain of 50 nested instantiations still builds and runs
//
// INVARIANT (Nim seminst.nim:473: the error fires only when `instCounter > 50`):
//   f50 → f49 → … → f0, each on a deeper array type, is 50 nested
//   instantiations and compiles on every backend with the right result.
//
// WHAT IT CATCHES: the limit tightened by one, and a compiler whose stack no
//   longer reaches the limit (the Windows main stack is 1 MB).
//
// RED MEANS: the depth check or the stack cost per nested instantiation changed.
//   Proven red 2026-09-26 with a -O0 build of the compiler on Windows: it
//   overflows its 1 MB stack after about 31 nested instantiations. The error
//   side one level deeper is genericInstantiationTooNested.
//
// GUARD-JS

function f0<T>(x: T): int32 { return 0; }
function f1<T>(x: T): int32 { const a: T[] = [x]; return 1 + f0(a); }
function f2<T>(x: T): int32 { const a: T[] = [x]; return 1 + f1(a); }
function f3<T>(x: T): int32 { const a: T[] = [x]; return 1 + f2(a); }
function f4<T>(x: T): int32 { const a: T[] = [x]; return 1 + f3(a); }
function f5<T>(x: T): int32 { const a: T[] = [x]; return 1 + f4(a); }
function f6<T>(x: T): int32 { const a: T[] = [x]; return 1 + f5(a); }
function f7<T>(x: T): int32 { const a: T[] = [x]; return 1 + f6(a); }
function f8<T>(x: T): int32 { const a: T[] = [x]; return 1 + f7(a); }
function f9<T>(x: T): int32 { const a: T[] = [x]; return 1 + f8(a); }
function f10<T>(x: T): int32 { const a: T[] = [x]; return 1 + f9(a); }
function f11<T>(x: T): int32 { const a: T[] = [x]; return 1 + f10(a); }
function f12<T>(x: T): int32 { const a: T[] = [x]; return 1 + f11(a); }
function f13<T>(x: T): int32 { const a: T[] = [x]; return 1 + f12(a); }
function f14<T>(x: T): int32 { const a: T[] = [x]; return 1 + f13(a); }
function f15<T>(x: T): int32 { const a: T[] = [x]; return 1 + f14(a); }
function f16<T>(x: T): int32 { const a: T[] = [x]; return 1 + f15(a); }
function f17<T>(x: T): int32 { const a: T[] = [x]; return 1 + f16(a); }
function f18<T>(x: T): int32 { const a: T[] = [x]; return 1 + f17(a); }
function f19<T>(x: T): int32 { const a: T[] = [x]; return 1 + f18(a); }
function f20<T>(x: T): int32 { const a: T[] = [x]; return 1 + f19(a); }
function f21<T>(x: T): int32 { const a: T[] = [x]; return 1 + f20(a); }
function f22<T>(x: T): int32 { const a: T[] = [x]; return 1 + f21(a); }
function f23<T>(x: T): int32 { const a: T[] = [x]; return 1 + f22(a); }
function f24<T>(x: T): int32 { const a: T[] = [x]; return 1 + f23(a); }
function f25<T>(x: T): int32 { const a: T[] = [x]; return 1 + f24(a); }
function f26<T>(x: T): int32 { const a: T[] = [x]; return 1 + f25(a); }
function f27<T>(x: T): int32 { const a: T[] = [x]; return 1 + f26(a); }
function f28<T>(x: T): int32 { const a: T[] = [x]; return 1 + f27(a); }
function f29<T>(x: T): int32 { const a: T[] = [x]; return 1 + f28(a); }
function f30<T>(x: T): int32 { const a: T[] = [x]; return 1 + f29(a); }
function f31<T>(x: T): int32 { const a: T[] = [x]; return 1 + f30(a); }
function f32<T>(x: T): int32 { const a: T[] = [x]; return 1 + f31(a); }
function f33<T>(x: T): int32 { const a: T[] = [x]; return 1 + f32(a); }
function f34<T>(x: T): int32 { const a: T[] = [x]; return 1 + f33(a); }
function f35<T>(x: T): int32 { const a: T[] = [x]; return 1 + f34(a); }
function f36<T>(x: T): int32 { const a: T[] = [x]; return 1 + f35(a); }
function f37<T>(x: T): int32 { const a: T[] = [x]; return 1 + f36(a); }
function f38<T>(x: T): int32 { const a: T[] = [x]; return 1 + f37(a); }
function f39<T>(x: T): int32 { const a: T[] = [x]; return 1 + f38(a); }
function f40<T>(x: T): int32 { const a: T[] = [x]; return 1 + f39(a); }
function f41<T>(x: T): int32 { const a: T[] = [x]; return 1 + f40(a); }
function f42<T>(x: T): int32 { const a: T[] = [x]; return 1 + f41(a); }
function f43<T>(x: T): int32 { const a: T[] = [x]; return 1 + f42(a); }
function f44<T>(x: T): int32 { const a: T[] = [x]; return 1 + f43(a); }
function f45<T>(x: T): int32 { const a: T[] = [x]; return 1 + f44(a); }
function f46<T>(x: T): int32 { const a: T[] = [x]; return 1 + f45(a); }
function f47<T>(x: T): int32 { const a: T[] = [x]; return 1 + f46(a); }
function f48<T>(x: T): int32 { const a: T[] = [x]; return 1 + f47(a); }
function f49<T>(x: T): int32 { const a: T[] = [x]; return 1 + f48(a); }
function f50<T>(x: T): int32 { const a: T[] = [x]; return 1 + f49(a); }

function main(): void {
    const depth = f50(1 as int32);
    console.log(depth == 50 ? "GUARD-OK" : "depth " + depth.toString());
}
main();
