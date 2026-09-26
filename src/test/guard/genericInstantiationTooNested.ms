// nim-guard: an instantiation nested past 50 levels is a checker error naming the generic
//
// INVARIANT (Nim seminst.nim:473 generateInstance: `instCounter > 50` →
//   "generic instantiation too nested"): the 51st nested instantiation stops with
//   that error at the call, on every backend, instead of leaving the call bound to
//   the generic declaration.
//
// WHAT IT CATCHES: the depth guard in instantiateGenericFunction returning null
//   silently again. Pre-fix behaviour: C died in clang on an undeclared
//   `nest__…`/`f0__…` function, and JS compiled clean and ran.
//
// RED MEANS: the guard lost its diagnostic or its limit moved. Proven red
//   2026-09-26 on main c36ed0ab (drc, orc: clang errors without the diagnostic;
//   js: compiled clean). genericInstantiationAtLimit is the neighbour one level
//   shallower that must still build.
//
// NOTE: runs through the candidate compiler, not a test binary: the -O0 test
//   binary overflows the 1 MB Windows main stack before depth 50 (measured: 16 MB
//   still overflows, 32 MB passes), while the release compiler reaches the limit.
//
// GUARD-CHECK-FAIL generic instantiation too nested: instantiating 'nest'
// GUARD-CHECK-FAIL generic instantiation too nested: instantiating 'f0'
// GUARD-JS

function nest<T>(x: T, n: int32): int32 {
    if (n == 0) return 0;
    const arr: T[] = [x];
    return 1 + nest(arr, n - 1);
}

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
function f51<T>(x: T): int32 { const a: T[] = [x]; return 1 + f50(a); }

function main(): void {
    console.log(nest(1 as int32, 3 as int32).toString());
    console.log(f51(1 as int32).toString());
}
main();
