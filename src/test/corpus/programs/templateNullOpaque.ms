// @stdout: null
// @stdout: v=null!
function mapText(m: Map<string, number> | null): string { return `${m}`; }
function ifaceText(i: { a: int32 } | null): string { return `v=${i}!`; }
console.log(mapText(null));
console.log(ifaceText(null));
