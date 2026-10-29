// Parity program — an optional union field read after an equality test narrowed it to one
// member compares like that member, through an alias, a nested owner, a call that rewrote the
// field, and the string member, on every backend.
//
// @stdout: call=true,true,false
// @stdout: alias=true,true,false
// @stdout: nested=true,true,false
// @stdout: text=true,true,false
// @stdout: absent=false,false
// @exit: 0

interface Style { width?: float64 | string; }
interface Node { style: Style | null; }
interface Holder { node: Node; }

function resize(node: Node): void { node.style = { width: 24 }; }
function setWidth(style: Style, w: float64): void { style.width = w; }
function styleOf(w: float64 | string | null): Style { return w == null ? {} : { width: w }; }

const node: Node = { style: { width: 18 } };
if (node.style !== null && node.style.width === 18) {
	resize(node);
	console.log(`call=${node.style !== null && node.style.width === 24},${node.style.width === 24},${node.style.width === 18}`);
}

const owner: Node = { style: { width: 18 } };
const style = owner.style;
if (style !== null && style.width === 18) {
	setWidth(style, 30);
	console.log(`alias=${style.width === 30},${owner.style !== null && owner.style.width === 30},${style.width === 18}`);
}

const holder: Holder = { node: { style: { width: 18 } } };
if (holder.node.style !== null && holder.node.style.width === 18) {
	resize(holder.node);
	console.log(`nested=${holder.node.style !== null && holder.node.style.width === 24},${holder.node.style.width === 24},${holder.node.style.width !== 24}`);
}

const named = styleOf("10px");
if (named.width === "10px") {
	console.log(`text=${named.width === "10px"},${named.width !== "12px"},${named.width === "12px"}`);
}

const none = styleOf(null);
console.log(`absent=${none.width === 3},${none.width === "x"}`);
