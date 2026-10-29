// @stdout: A1 b-x B2 c-y
// @stdout: h2 h4 n-z w5 r7 dot
interface Circle { radius: int32 }
interface Label { text: string }
interface Pin { text: string; size?: int32 }

function describe(u: Circle | Label): string {
	if ("radius" in u) {
		return "A" + u.radius.toString();
	}
	return "b-" + u.text;
}

function third(u: Circle | Label | Pin): string {
	if ("radius" in u) {
		return "B" + u.radius.toString();
	}
	if ("size" in u) {
		return "c-" + u.text;
	}
	return "d-" + u.text;
}

console.log(describe({ radius: 1 }), describe({ text: "x" }), third({ radius: 2 }), third({ text: "y", size: 5 }));

interface Box { w: int32; h: int32 }
interface Disc { r: int32; h: int32 }
interface Dot { name: string }

function height(u: Box | Disc | Dot): string {
	if ("h" in u) {
		return "h" + u.h.toString();
	}
	return "n-" + u.name;
}

function width(u: Box | Disc | Dot): string {
	if ("w" in u) return "w" + u.w.toString();
	if ("r" in u) return "r" + u.r.toString();
	return "dot";
}

console.log(height({ w: 1, h: 2 }), height({ r: 3, h: 4 }), height({ name: "z" }), width({ w: 5, h: 6 }), width({ r: 7, h: 8 }), width({ name: "q" }));
