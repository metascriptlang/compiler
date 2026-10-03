// @stdout: sizes 1 2 4 4 2 6 12
// note: an enum is stored in the narrowest width that holds its ordinals (one byte up to 255, two up to 65535, four with a negative member or beyond), so a struct of a byte enum and a uint8 is two bytes. The sizes line is the oracle (every lane folds `sizeof` the same way); field writes, match, JSON and in-range conversions are held by the cross-lane compare. Ordinals print through `as int32`: `toString()` of a member with an explicit non-sequential value prints <unknown> on C and JS, and the raiser prints the ordinal (both older than this program).

enum Kind { Empty, Pet }
enum Wide { Low = 0, High = 300 }
enum Signed { Below = -1, Zero = 0 }
enum Big { Small = 1, Large = 70000 }
struct Head { kind: Kind; version: uint8; }
struct Mix { a: uint8; w: Wide; b: uint8; k: Kind; }
struct Tagged { kind: Kind; wide: Wide; version: uint8; }
struct Spread { s: Signed; k: Kind; w: Wide; v: uint8; }

function label(k: Kind): string {
	return match (k) {
		Kind.Empty => "empty",
		Kind.Pet => "pet",
	};
}

function main(): void {
	console.log(`sizes ${sizeof(Kind)} ${sizeof(Wide)} ${sizeof(Signed)} ${sizeof(Big)} ${sizeof(Head)} ${sizeof(Mix)} ${sizeof(Spread)}`);
	const h: Head = { kind: Kind.Pet, version: 7 };
	console.log(`head ${h.kind as int32} ${h.version} ${label(h.kind)}`);
	const hs: Head[] = [{ kind: Kind.Pet, version: 1 }, { kind: Kind.Empty, version: 9 }];
	hs[0].kind = Kind.Empty;
	hs[1].kind = Kind.Pet;
	console.log(`heads ${hs[0].kind as int32} ${hs[1].kind as int32} ${hs[1].version} ${label(hs[0].kind)} ${label(hs[1].kind)}`);
	const m: Mix = { a: 1, w: Wide.High, b: 2, k: Kind.Pet };
	console.log(`mix ${m.a} ${m.w as int32} ${m.b} ${m.k as int32}`);
	const t: Tagged = { kind: Kind.Pet, wide: Wide.High, version: 7 };
	const text = JSON.stringify(t);
	const r = JSON.parse<Tagged>(text);
	if (r.ok) {
		console.log(`json ${text} ${r.value.kind == Kind.Pet} ${r.value.wide == Wide.High} ${r.value.version}`);
	} else {
		console.log(`json failed ${r.error}`);
	}
	let one: int32 = 1;
	let three: int32 = 300;
	const k = one as Kind;
	const w = three as Wide;
	console.log(`conv ${label(k)} ${k as int32} ${w as int32} ${Signed.Below as int32}`);
}

main();
