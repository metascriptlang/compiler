// @stdout: literal false true false true false true | evaluated false true calls 2
// @xfail(raiser): bigint is not supported on the Raiser VM
// note: a bigint compared with null is false (and != true) on C as on JS, with the bigint operand still evaluated; C used to stop in the transform with "cannot convert null to bigint".

function big(v: bigint): bigint { return v; }

let calls = 0;
function counted(v: bigint): bigint {
	calls += 1;
	return v;
}

const b = big(5n);
const literal = `literal ${b == null} ${b != null} ${null == b} ${null != b} ${b === null} ${b !== null}`;
const evaluated = `evaluated ${counted(7n) == null} ${null != counted(8n)} calls ${calls}`;
console.log(`${literal} | ${evaluated}`);
