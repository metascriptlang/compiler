// @stdout: small {"k0":"end","k1":9,"k2":6,"k3":7} | {"k0":"end","k1":9,"k2":6,"k3":7}
// @stdout: large {"k0":"end","k1":27,"k2":28,"k3":29,"k4":30,"k5":31,"k6":32,"k7":33,"k8":34,"k9":35,"k10":36,"k11":37,"k12":38} | {"k0":"end","k1":27,"k2":28,"k3":29,"k4":30,"k5":31,"k6":32,"k7":33,"k8":34,"k9":35,"k10":36,"k11":37,"k12":38}
// @stdout: distinct {"k0":0,"k1":1,"k2":2,"k3":3,"k4":4,"k5":5,"k6":6,"k7":7,"k8":8,"k9":9,"k10":10,"k11":11,"k12":12,"k13":13,"k14":14,"k15":15,"k16":16,"k17":17,"k18":18,"k19":19,"k20":20,"k21":21,"k22":22,"k23":23,"k24":24,"k25":25,"k26":26,"k27":27,"k28":28,"k29":29,"k30":30,"k31":31,"k32":32,"k33":33,"k34":34,"k35":35,"k36":36,"k37":37,"k38":38,"k39":39,"z":"end"} | {"k0":0,"k1":1,"k2":2,"k3":3,"k4":4,"k5":5,"k6":6,"k7":7,"k8":8,"k9":9,"k10":10,"k11":11,"k12":12,"k13":13,"k14":14,"k15":15,"k16":16,"k17":17,"k18":18,"k19":19,"k20":20,"k21":21,"k22":22,"k23":23,"k24":24,"k25":25,"k26":26,"k27":27,"k28":28,"k29":29,"k30":30,"k31":31,"k32":32,"k33":33,"k34":34,"k35":35,"k36":36,"k37":37,"k38":38,"k39":39,"z":"end"}
// note: parseJson keeps one entry per key, the last value at the first key's position, as JS does; an object up to 32 keys and a wider one (two dedupe paths) answer the same at comptime and at run time on every lane.
function wide(count: int32, distinctKeys: int32, lastKey: string): string {
	let text = "{";
	for (let i = 0; i < count; i = i + 1) text = text + `"k${i % distinctKeys}":${i},`;
	return text + `"${lastKey}":"end"}`;
}

function show(text: string): string {
	const r = parseJson(text);
	return r.ok ? stringify(r.value) : r.error;
}

const small = @comptime { return show(wide(10, 4, "k0")); };
const large = @comptime { return show(wide(40, 13, "k0")); };
const distinct = @comptime { return show(wide(40, 40, "z")); };
console.log(`small ${small} | ${show(wide(10, 4, "k0"))}`);
console.log(`large ${large} | ${show(wide(40, 13, "k0"))}`);
console.log(`distinct ${distinct} | ${show(wide(40, 40, "z"))}`);
