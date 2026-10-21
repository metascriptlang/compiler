// @stdout: sum=3 negated=-4 compound=6
struct P { x: int32; }
function `+`(this a: P, b: P): P { return { x: a.x + b.x }; }
function `-`(this a: P): P { return { x: -a.x }; }
type Q = distinct P;
@delegate function `+`(this a: Q, b: Q): Q;
@delegate function `-`(this a: Q): Q;

function q(x: int32): Q { return ({ x: x } as P) as Q; }

const sum = q(1) + q(2);
const negated = -q(4);
let compound = q(1);
compound += q(5);
console.log(`sum=${(sum as P).x} negated=${(negated as P).x} compound=${(compound as P).x}`);
