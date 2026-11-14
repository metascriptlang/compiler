// @stdout: Error: boom|Error: boom|c=Error: boom|RangeError: far|TypeError: bad|NotFound: key is missing|NotFound|Error: s|Error|m|Error: inherits
// @stdout: runtime-made true true
// note: an Error converts to text as `Error.prototype.toString` does, name then message, through a template, String() and `+`; a subclass's own name shows, an empty message leaves the name and an empty name the message; an Error the C runtime makes (Promise.any's rejection) carries a name too, a literal whose text conversion faulted when it was not marked ASCII (all backends printed the JSON dump {"message":"boom"} before std's Error declared `name` and `toString`).

class NotFound extends Error {
	constructor(what: string) {
		super(`${what} is missing`);
		this.name = "NotFound";
	}
}

class Inherits extends Error {
	constructor(m: string) {
		super(m);
	}
}

function plain(): void { throw "s"; }

function texts(): string {
	const out: string[] = [];
	try { throw new Error("boom"); } catch (e) {
		out.push(`${e}`);
		out.push(String(e));
		out.push("c=" + e);
	}
	try { throw new RangeError("far"); } catch (e) { out.push(`${e}`); }
	try { throw new TypeError("bad"); } catch (e) { out.push(`${e}`); }
	try { throw new NotFound("key"); } catch (e) {
		out.push(`${e}`);
		out.push(e.name);
	}
	try { plain(); } catch (e) { out.push(`${e}`); }
	out.push(`${new Error("")}`);
	const unnamed = new Error("m");
	unnamed.name = "";
	out.push(`${unnamed}`);
	out.push(`${new Inherits("inherits")}`);
	return out.join("|");
}
console.log(texts());
try {
	await Promise.any([Promise.reject(new Error("a"))]);
} catch (e) {
	console.log(`runtime-made ${String(e).endsWith(": All promises were rejected")} ${e.name.length > 0}`);
}
