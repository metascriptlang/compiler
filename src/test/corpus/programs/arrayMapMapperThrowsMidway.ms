// @stdout: ok 4 tag2 label-3
// @stdout: caught-class boom 3
// @stdout: caught-string boom 2
// @stdout: caught-struct boom 4
// @stdout: caught-first boom 0
// @stdout: caught-last boom 5
// @stdout: again 3 tag-2 3
class Tag {
	id: int32;
	label: string;
	parts: string[] = [];
	constructor(id: int32, label: string) {
		this.id = id;
		this.label = label;
		this.parts.push(label);
	}
}
struct Named { name: string; n: int32 }

function failAt(at: int32, i: number): void {
	if (i == at) throw new Error("boom " + i);
}

function mapTags(src: int32[], at: int32): Tag[] {
	return src.map((x: int32, i: number): Tag => {
		failAt(at, i);
		return new Tag(x, "label-" + x);
	});
}

function mapStrings(src: int32[], at: int32): string[] {
	return src.map((x: int32, i: number): string => {
		failAt(at, i);
		return "tag-" + x + "-" + "padding-padding-padding";
	});
}

function mapNamed(src: int32[], at: int32): Named[] {
	return src.map((x: int32, i: number): Named => {
		failAt(at, i);
		return { name: "named-" + x + "-padding-padding", n: x };
	});
}

function attemptTags(at: int32): string {
	try {
		return "ok " + mapTags([1, 2, 3, 4], at).length + " tag" + mapTags([1, 2, 3, 4], at)[1].id + " " + mapTags([1, 2, 3, 4], at)[2].label;
	} catch (e) {
		return "caught " + (e as Error).message;
	}
}

console.log(attemptTags(-1));

const src = [0, 1, 2, 3, 4, 5];

try { mapTags(src, 3); console.log("not thrown"); } catch (e) { console.log("caught-class " + (e as Error).message); }
try { mapStrings(src, 2); console.log("not thrown"); } catch (e) { console.log("caught-string " + (e as Error).message); }
try { mapNamed(src, 4); console.log("not thrown"); } catch (e) { console.log("caught-struct " + (e as Error).message); }
try { mapTags(src, 0); console.log("not thrown"); } catch (e) { console.log("caught-first " + (e as Error).message); }
try { mapStrings(src, 5); console.log("not thrown"); } catch (e) { console.log("caught-last " + (e as Error).message); }

const again = mapStrings([1, 2, 3], -1);
const tags = mapTags([1, 2, 3], -1);
console.log("again " + again.length + " " + again[1].substring(0, 5) + " " + tags[2].id);
