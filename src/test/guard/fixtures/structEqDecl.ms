// Fixture for src/test/guard/structEqNameNotInScope.ms — NOT part of any suite.
// The consuming guard imports mkP but never the struct name P, so the module
// that compares two P values cannot resolve "P" in its own scope.

export struct P { x: number; }

export function mkP(x: number): P { return { x: x }; }
