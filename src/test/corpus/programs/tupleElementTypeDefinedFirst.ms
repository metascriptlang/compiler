// @stdout: direct=back,1 nested=back,1,2 struct=back,3 literal=fill,4 generic=back,5 expr=none,6
// note: an arrow is lifted ahead of the module's type declarations, so its tuple signature is the first use of each element type. Every element type is defined before the tuple that holds it, whether the element is an enum, a struct reaching an enum, a nested tuple, a string-literal union or a generic argument.

enum Face { None, Back }
type Mode = "fit" | "fill";
interface Draw { face: Face; }

function faceText(f: Face): string { return f === Face.Back ? "back" : "none"; }
function hold<T>(f: () => T): T { return f(); }

const direct = (): [Face, int32] => [Face.Back, 1];
const nested = (): [[Face, int32], int32] => [[Face.Back, 1], 2];
const viaStruct = (): [Draw, int32] => [{ face: Face.Back }, 3];
const literal = (): [Mode, int32] => ["fill", 4];
const expr = function (): [Face, int32] { return [Face.None, 6]; };

const [d, dn] = direct();
const [inner, nn] = nested();
const [s, sn] = viaStruct();
const [m, mn] = literal();
const g = hold<[Face, int32]>(() => [Face.Back, 5]);
const [e, en] = expr();

console.log(`direct=${faceText(d)},${dn} nested=${faceText(inner[0])},${inner[1]},${nn} struct=${faceText(s.face)},${sn} literal=${m},${mn} generic=${faceText(g[0])},${g[1]} expr=${faceText(e)},${en}`);
