// @stdout: 1 1 true 1 1 1 [ab]

function maybeNum(): number | null { let x: number | null = 1; try { return x; } finally { x = 2; } }
function maybeInt(): int32 | null { let x: int32 | null = 1; try { return x; } finally { x = 2; } }
function maybeBool(): boolean | null { let x: boolean | null = true; try { return x; } finally { x = false; } }
function numOrBool(): number | boolean { let x: number | boolean = 1; try { return x; } finally { x = true; } }
function viaCatch(): number | null { let x: number | null = 1; try { throw new Error("e"); } catch (e) { return x; } finally { x = 9; } }
function plain(): int32 { let x: int32 = 1; try { return x; } finally { x = 2; } }
function text(): string { let s = "a" + "b"; try { return s; } finally { s = "zz"; } }
console.log(`${maybeNum()} ${maybeInt()} ${maybeBool()} ${numOrBool()} ${viaCatch()} ${plain()} [${text()}]`);
