// Parity program — `{ ["lit"]: v }` names the field `lit`, as in TypeScript,
// beside a plain key; before, every computed key was stored as `__computed__`.
//
// @stdout: {"lit":3,"plain":4}|7
// @exit: 0

const o = { ["lit"]: 3, plain: 4 };
console.log(JSON.stringify(o) + "|" + (o.lit + o.plain).toString());
