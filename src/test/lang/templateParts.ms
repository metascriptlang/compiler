test "template parts: integer widths print their decimal digits" {
	const a: int32 = -2147483648;
	const b: int64 = -9223372036854775807;
	const c: uint8 = 255;
	const d: uint64 = 18446744073709551615;
	const e: int16 = -7;
	const f: uint32 = 4294967295;
	assert `${a}|${b}|${c}|${d}|${e}|${f}` == "-2147483648|-9223372036854775807|255|18446744073709551615|-7|4294967295";
	assert String(a) == "-2147483648";
	assert String(d) == "18446744073709551615";
	assert String(c) == "255";
}

test "template parts: numbers keep their shortest text" {
	const frac: number = 1.5;
	const negZero: number = -0;
	const nan: number = NaN;
	const big: number = 1e21;
	const huge: number = 1.2345678901234568e20;
	const whole: number = 42;
	assert `${frac}/${negZero}/${nan}/${big}/${huge}/${whole}` == "1.5/0/NaN/1e+21/123456789012345680000/42";
	assert String(frac) == "1.5";
	assert String(nan) == "NaN";
	assert String(negZero) == "0";
}

test "template parts: string, boolean, null and empty parts" {
	const s = "x";
	const t = true;
	const n: string | null = null;
	const empty = "";
	assert `${s}${empty}${t}` == "xtrue";
	assert `${n}` == "null";
	assert `a${empty}b` == "ab";
	assert `${empty}` == "";
	assert `${s}` == "x";
	assert `${1}` == "1";
	assert `${t}` == "true";
	assert `` == "";
}

test "template parts: nested templates and an empty head" {
	const i: int32 = 7;
	const inner = `${i}-${i + 1}`;
	assert `[${inner}:${`<${i}>`}]` == "[7-8:<7>]";
	assert `${i}${i}` == "77";
	assert `${i}` + `${i}` == "77";
}

type TplId = distinct int32;
function valueOf(this d: TplId): string { return "vo"; }
type TplTagged<T> = distinct int32;
function valueOf<T>(this d: TplTagged<T>): string { return "tv"; }
type TplMeters = distinct number;

test "template parts: a distinct cast to its base prints the base, a cast through valueOf owns its text" {
	const id = (7 as int32) as TplId;
	const tagged = (5 as int32) as TplTagged<string>;
	const m = (1.5 as number) as TplMeters;
	assert `${id as int32}|${id as number}|${id as int64}|${tagged as int32}|${m as number}` == "7|7|7|5|1.5";
	assert (id as int32).toString() == "7";
	assert (tagged as int32).toString() == "5";
	assert (m as number).toString() == "1.5";
	const parts: string[] = [];
	parts.push(`${(id as string | null)!}`);
	parts.push((id as string | null)!);
	parts.push(`${(tagged as string | null)!}`);
	assert parts.join("|") == "vo|vo|tv";
}
