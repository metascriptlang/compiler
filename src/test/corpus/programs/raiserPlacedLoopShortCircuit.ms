// @stdout: while=4 do=3 for=3 cond=1,2 eq=1 calls=15
let calls = 0;
function label(s: string): string { calls += 1; return s; }

function whileOr(n: int32): int32 {
  let i = 0; let hits = 0;
  while ((label(i > 1 ? "z" : "") || "e" + (i + n).toString()) !== "zz" && i < 4) { hits += 1; i += 1; }
  return hits;
}
function doOr(n: int32): int32 {
  let i = 0;
  do { i += 1; } while ((label("") || "e" + n.toString()) !== "zz" && i < 3);
  return i;
}
function forOr(n: int32): int32 {
  let hits = 0;
  for (let k = 0; (label("") || "e" + n.toString()) !== "zz" && k < 3; k += 1) { hits += 1; }
  return hits;
}
function ifOr(n: int32): int32 { if (label("") || "e" + n.toString()) { return 1; } return 0; }
function ifAnd(n: int32): int32 { if (label("a") && "e" + n.toString()) { return 2; } return 0; }
function eqOr(n: int32): int32 { return (label("") || "e" + n.toString()) === "e5" ? 1 : 0; }

console.log(`while=${whileOr(1)} do=${doOr(1)} for=${forOr(1)} cond=${ifOr(1)},${ifAnd(1)} eq=${eqOr(5)} calls=${calls}`);
