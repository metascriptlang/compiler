import { compileToC } from "../helpers";

function emitted(src: string): string {
	const r = compileToC(src);
	if (!r.ok) throw new Error(`internal: ${r.error}`);
	return r.value;
}

function callLine(lines: string[], marker: string): int32 {
	let at: int32 = -1;
	for (let i = 0; i < lines.length; i += 1) {
		if (lines[i].includes(marker)) at = i as int32;
	}
	return at;
}

function zeroedBefore(code: string, marker: string): boolean {
	const lines = code.split("\n");
	const at = callLine(lines, marker);
	return at > 0 && lines[at - 1].includes("= (") && lines[at - 1].includes("){0};");
}

test "nrvoOutTempZero: a direct struct-returning call zeroes its out-temp before the call" {
	const code = emitted("struct P { s: string; n: int32; }\nfunction boomA(t: string): P { if (t.length > 0) { throw new Error(t); } return { s: t, n: 0 }; }\nfunction run(t: string): int32 { try { const p = boomA(t); return p.n; } catch (e) { return -1; } }\nconsole.log(run(\"x\"));");
	assert zeroedBefore(code, "boomA__") , code;
}

test "nrvoOutTempZero: a closure call returning a tuple zeroes its out-temp before the call" {
	const code = emitted("function run(t: string): int32 { const boomB = (u: string): [string, int32] => { if (u.length > 0) { throw new Error(u); } return [u, 0]; }; try { const p = boomB(t); return p[1]; } catch (e) { return -1; } }\nconsole.log(run(\"x\"));");
	assert zeroedBefore(code, "boomB_1_.env ?"), code;
}
