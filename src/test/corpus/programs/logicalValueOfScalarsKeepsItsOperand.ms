// @stdout: bool or: true true true false
// @stdout: bool and: true false false false
// @stdout: int or: 3 7 7 0
// @stdout: int and: 7 0 0 0
// @stdout: right runs: 2 1
// note: the value of && and || over booleans and integers is the operand that decides it, and the right operand runs only when the left does not decide.
function or(a: boolean, b: boolean): boolean { return a || b; }
function and(a: boolean, b: boolean): boolean { return a && b; }
function orInt(a: int32, b: int32): int32 { return a || b; }
function andInt(a: int32, b: int32): int32 { return a && b; }

let calls: int32 = 0;
function counted(v: boolean): boolean {
	calls += 1;
	return v;
}

console.log(`bool or: ${or(true, true)} ${or(true, false)} ${or(false, true)} ${or(false, false)}`);
console.log(`bool and: ${and(true, true)} ${and(true, false)} ${and(false, true)} ${and(false, false)}`);
console.log(`int or: ${orInt(3, 7)} ${orInt(0, 7)} ${orInt(0, 7)} ${orInt(0, 0)}`);
console.log(`int and: ${andInt(3, 7)} ${andInt(0, 7)} ${andInt(3, 0)} ${andInt(0, 0)}`);
const viaOr = counted(false) || counted(true);
const before = calls;
calls = 0;
const viaAnd = counted(false) && counted(true);
console.log(`right runs: ${before} ${calls}${viaOr && !viaAnd ? "" : " wrong"}`);
