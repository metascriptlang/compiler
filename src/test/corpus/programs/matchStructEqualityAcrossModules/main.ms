// @stdout: equal=true,false,false
// @stdout: different=false,true,true
// @stdout: direct=false,true,true
// @exit: 0
// note: a match struct's `==` declared in one module is the equality a generic `===` / `!==` in a second module uses when a third module instantiates it with that struct, and the `!=` the third module writes is that `==` negated. Before, `!=` and `!==` skipped the declared `==`: C stopped at clang and JS compared identity, so equal values read as different.

import { Projection, ProjectionKind } from "./projection";
import { isEqual, isDifferent } from "./equal";

const first: Projection = { kind: ProjectionKind.Perspective, fovY: 1.0 };
const second: Projection = { kind: ProjectionKind.Perspective, fovY: 1.0 };
const wider: Projection = { kind: ProjectionKind.Perspective, fovY: 2.0 };
const ortho: Projection = { kind: ProjectionKind.Orthographic, worldPerTexel: 0.1, snap: false };
console.log(`equal=${isEqual<Projection>(first, second)},${isEqual<Projection>(first, wider)},${isEqual<Projection>(first, ortho)}`);
console.log(`different=${isDifferent<Projection>(first, second)},${isDifferent<Projection>(first, wider)},${isDifferent<Projection>(first, ortho)}`);
console.log(`direct=${first != second},${first != wider},${first != ortho}`);
