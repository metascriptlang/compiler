// @stdout: 2 3
// note: an object literal assigned to a Map or HashMap builds through the std builder the
// compiler binds by symbol; a user function spelled like that builder is never called for it.
function mapFromPairs(keys: string[], vals: int32[]): Map<string, int32> {
	console.log("HIJACKED");
	return new Map<string, int32>();
}

function hashMapFromPairs(keys: string[], vals: int32[]): HashMap<string, int32> {
	console.log("HIJACKED");
	return new HashMap<string, int32>();
}

const ordered: Map<string, int32> = { a: 1, b: 2 };
const hashed: HashMap<string, int32> = { a: 1, b: 2, c: 3 };
console.log(`${ordered.size} ${hashed.size}`);
