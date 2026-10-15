// note: a float divided by zero is NaN or an infinity, and a negated zero keeps its sign, so 1 / -0 is -Infinity, the same on C, JS and the Raiser.

const values: float64[] = [0.0, 1.0];
function negate(r: float64): float64 { return -r; }

const zero = values[0];
const nan = zero / zero;
console.log(`${nan != nan} ${values[1] / zero} ${-values[1] / zero} ${1 / negate(zero)} ${1 / negate(negate(zero))}`);
