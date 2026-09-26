// bug463 — a closure made in a loop copied every variable it captured
//
// Symptom:    on C, closures made in a loop body worked on private copies:
//             three `() => { total += i; }` left total at 0 (JS: 3), a write
//             to the loop's binding after the closure was made was lost
//             (j printed 0/10/20, JS 1/11/21), the two closures of one
//             iteration did not share its binding, and a closure in a for
//             header saw the loop variable of the wrong iteration.
// Root cause: src/transform/lowering/lambdaLifting.ms gave every closure made
//             inside a loop its own env holding a copy of every capture, and
//             src/transform/lowering/forLoopLower.ms kept one binding for a
//             `let` of the for header across all iterations.
// Fix:        a loop whose body declares a binding a closure reads opens one
//             env per iteration for those bindings, shared by every closure of
//             the iteration, with `$up` to the enclosing env; every other
//             capture is reached through `$up`. A captured `let` of a for
//             header gets one binding per iteration: the iteration works on a
//             copy and the increment runs on the next iteration's copy.
//
// Guarded end-to-end by corpus/programs/927-closurePerIterationBinding.ms.

type B463Thunk = () => string;
type B463Get = () => int32;
type B463Set = (v: int32) => void;

function b463LoopExample(): string {
	let total: int32 = 0;
	const fns: (() => void)[] = [];
	const shows: B463Thunk[] = [];
	for (let i: int32 = 0; i < 3; i++) {
		let j: int32 = i * 10;
		fns.push((): void => { total += i; });
		shows.push((): string => `${i}/${j}`);
		j = j + 1;
	}
	for (const f of fns) f();
	let s = `total=${total}`;
	for (const g of shows) s = s + " " + g();
	return s;
}

function b463IterationShared(): string {
	const gets: B463Get[] = [];
	const sets: B463Set[] = [];
	for (let i: int32 = 0; i < 2; i++) {
		let y: int32 = i * 100;
		gets.push((): int32 => y);
		sets.push((v: int32): void => { y = v; });
	}
	sets[0](7);
	sets[1](8);
	return `${gets[0]()} ${gets[1]()}`;
}

function b463OuterShared(): string {
	let total: int32 = 0;
	const reads: B463Get[] = [];
	const adds: B463Set[] = [];
	for (let i: int32 = 0; i < 2; i++) {
		reads.push((): int32 => total);
		adds.push((v: int32): void => { total = total + v; });
	}
	adds[0](5);
	adds[1](7);
	const afterAdds = total;
	total = 99;
	return `${afterAdds} ${reads[0]()} ${reads[1]()}`;
}

function b463Nested(): string {
	const fs: B463Get[] = [];
	for (let i: int32 = 0; i < 2; i++) {
		let acc: int32 = i * 100;
		for (let j: int32 = 0; j < 2; j++) {
			fs.push((): int32 => { acc = acc + 1; return acc * 10 + j; });
		}
	}
	let s = "";
	for (const f of fs) s = s + `${f()} `;
	return s;
}

function b463HeaderCondition(): string {
	const fs: B463Get[] = [];
	const keep = (f: B463Get): boolean => { fs.push(f); return true; };
	for (let i: int32 = 0; i < 3 && keep((): int32 => i); i++) {
		i = i + 5;
	}
	let s = "";
	for (const f of fs) s = s + `${f()} `;
	return s;
}

function b463HeaderUpdate(): string {
	const fs: B463Get[] = [];
	const step = (v: int32, f: B463Get): int32 => { fs.push(f); return v + 1; };
	for (let i: int32 = 0; i < 3; i = step(i, (): int32 => i)) {
		i = i + 0;
	}
	let s = "";
	for (const f of fs) s = s + `${f()} `;
	return s;
}

function b463Continue(): string {
	const fs: B463Get[] = [];
	for (let i: int32 = 0; i < 6; i++) {
		fs.push((): int32 => i);
		if (i % 2 == 0) {
			i = i + 1;
			continue;
		}
		if (i > 4) break;
	}
	let s = "";
	for (const f of fs) s = s + `${f()} `;
	return s;
}

function b463ForOf(): int32 {
	let clicks: int32 = 0;
	const handlers: (() => void)[] = [];
	const names: string[] = ["a", "b"];
	for (const n of names) {
		handlers.push((): void => { clicks = clicks + n.length; });
	}
	for (const h of handlers) h();
	return clicks;
}

test "bug463: closures of a loop share the function's variables and own their iteration's" {
	assert b463LoopExample() == "total=3 0/1 1/11 2/21";
}

test "bug463: the closures of one iteration share its binding" {
	assert b463IterationShared() == "7 8";
}

test "bug463: a closure made in a loop reads and writes the enclosing binding" {
	assert b463OuterShared() == "12 99 99";
}

test "bug463: nested loops give each closure its own iteration of both" {
	assert b463Nested() == "10 21 1010 1021 ";
}

test "bug463: a closure in a for condition sees the running iteration's copy" {
	assert b463HeaderCondition() == "5 ";
}

test "bug463: a closure in a for update sees the next iteration's copy" {
	assert b463HeaderUpdate() == "1 2 3 ";
}

test "bug463: continue and break keep the iteration's copy" {
	assert b463Continue() == "1 3 5 ";
}

test "bug463: for-of closures share the enclosing binding" {
	assert b463ForOf() == 2;
}
