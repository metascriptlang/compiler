// GUARD-CHECK-FAIL @exportName defines a C symbol

@exportName("guard_bound")
extern function guardBound(): int32;
console.log(guardBound());
