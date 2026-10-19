// @stdout: 2.5 2.5 3 2.5 2.5 3
// note: a union of two number types converts to text through the member it holds, in a template, through String() and after a copy; before, the raiser bound the float64 toString to the whole union and printed [object].
function viaTemplate(u: float64 | int32): string { return `${u}`; }
function viaString(u: float64 | int32): string { return String(u); }
function untagged(u: float64 | string): string { return `${u}`; }

const wide: float64 | int32 = 2.5;
const copied: number | int32 = wide;
const whole: float64 | int32 = 3;
console.log(viaTemplate(2.5), viaString(2.5), viaTemplate(3), `${copied}`, untagged(2.5), `${whole}`);
