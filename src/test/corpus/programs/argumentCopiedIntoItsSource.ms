// @stdout: global 31 config:xxxxx
// @stdout: field 31 boxed:xxxxxx
// @stdout: captured 31 capture:xxxx
// @stdout: struct 31 struct:xxxxx 7
// @stdout: element 31 element:xxxx
// @stdout: ref 31 byref:xxxxxx
// @stdout: counted 3 7

let notice = "";
function show(text: string): void {
	notice = text;
	console.log(`global ${text.length} ${text.substring(0, 12)}`);
}
show(`config:${"x".repeat(24)}`);
show(notice);
show(notice);

interface Box { s: string; }
function showBoxed(box: Box, text: string): void {
	box.s = text;
	console.log(`field ${text.length} ${text.substring(0, 12)}`);
}
const box: Box = { s: "" };
showBoxed(box, `boxed:${"x".repeat(25)}`);
showBoxed(box, box.s);

function makeNotice(): () => void {
	let held = "";
	function keep(text: string): void {
		held = text;
		console.log(`captured ${text.length} ${text.substring(0, 12)}`);
	}
	return (): void => {
		keep(`capture:${"x".repeat(23)}`);
		keep(held);
		keep(held);
	};
}
makeNotice()();

struct Note { s: string; n: int32; }
let note: Note = { s: "", n: 0 };
function keepNote(p: Note): void {
	note = p;
	console.log(`struct ${p.s.length} ${p.s.substring(0, 12)} ${p.n}`);
}
keepNote({ s: `struct:${"x".repeat(24)}`, n: 7 });
keepNote(note);

function putFirst(items: string[], text: string): void {
	items[0] = text;
	console.log(`element ${text.length} ${text.substring(0, 12)}`);
}
const items: string[] = [`element:${"x".repeat(23)}`, "b"];
putFirst(items, items[0]);
putFirst(items, items[0]);

let viaRef = `byref:${"x".repeat(25)}`;
function setRef(ref dst: string, text: string): void {
	dst = text;
	console.log(`ref ${text.length} ${text.substring(0, 12)}`);
}
setRef(viaRef, viaRef);

let counted: number[] = [];
function keepCounted(a: number[]): void {
	counted = a;
	console.log(`counted ${a.length} ${a[0]}`);
}
keepCounted([7, 8, 9]);
keepCounted(counted);
