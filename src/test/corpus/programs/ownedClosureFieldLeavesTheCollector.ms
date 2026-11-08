// @skip-js: C-only by design: onDestroy counts the DRC's destroys; JS frees nothing
// @stdout: reuploaded 3 4 at generation 2
// @stdout: kept destroyed 1, textures destroyed 2
// note: an interface whose closure field is Owned<(t: Texture) => void> | null holds a closure formed by another function from a function expression, whose environment captures no cycle; the closure is called through the field, copied into a second texture and dropped with them.
interface Texture {
	width: int32;
	height: int32;
	generation: int32;
	realloc: Owned<(texture: Texture) => void> | null;
}

class Kept {
	width: int32;
	height: int32;
	constructor(width: int32, height: int32) { this.width = width; this.height = height; }
}
let keptDestroyed = 0;
function onDestroy(this k: Kept): void { keptDestroyed++; }

let texturesDestroyed = 0;
class Holder {
	tex: Texture;
	constructor(tex: Texture) { this.tex = tex; }
}
function onDestroy(this h: Holder): void { texturesDestroyed++; }

function reuploadKept(kept: Kept): Owned<(texture: Texture) => void> {
	return (texture: Texture): void => {
		texture.width = kept.width;
		texture.height = kept.height;
		texture.generation += 1;
	};
}

function run(): void {
	const a = new Holder({ width: 0, height: 0, generation: 1, realloc: null });
	a.tex.realloc = reuploadKept(new Kept(3, 4));
	const b = new Holder({ width: 0, height: 0, generation: 0, realloc: a.tex.realloc });
	const realloc = a.tex.realloc;
	if (realloc != null) realloc(a.tex);
	console.log("reuploaded " + a.tex.width.toString() + " " + a.tex.height.toString() + " at generation " + a.tex.generation.toString());
	b.tex.realloc = null;
}

run();
console.log("kept destroyed " + keptDestroyed.toString() + ", textures destroyed " + texturesDestroyed.toString());
