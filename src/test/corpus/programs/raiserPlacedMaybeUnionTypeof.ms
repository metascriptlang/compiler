// @stdout: both=ret kind=ret plain=ret str=s
// note: a typeof test beside a null test of a nullable union reads the held value without releasing it, so the object is still alive afterwards. Second axis: the held member is a string.
class Boxed {
	message: string;
	constructor(m: string) { this.message = m; }
}
type StrLike = Boxed | string | null;

function give(): StrLike {
	return new Boxed("ret");
}

function giveStr(): StrLike {
	return "s";
}

function both(): string {
	const r = give();
	let ret = "none";
	if (r != null && typeof r !== "string") ret = (r as Boxed).message;
	return ret;
}

function kind(): string {
	const r = give();
	let ret = "none";
	if (typeof r !== "string") ret = (r as Boxed).message;
	return ret;
}

function plain(): string {
	const r = give();
	let ret = "none";
	if (r != null) ret = (r as Boxed).message;
	return ret;
}

function str(): string {
	const s = giveStr();
	let out = "none";
	if (s != null && typeof s === "string") out = s;
	return out;
}

console.log("both=" + both() + " kind=" + kind() + " plain=" + plain() + " str=" + str());
