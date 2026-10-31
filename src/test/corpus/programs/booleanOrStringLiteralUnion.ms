// @stdout: checked mixed unchecked|mixed checked unchecked none|auto 3|on half
// @exit: 0

function show(checked: boolean | "mixed"): string {
	return checked === "mixed" ? "mixed" : checked === true ? "checked" : "unchecked";
}

interface S {
	checked?: boolean | "mixed" | null;
}

function showField(s: S): string {
	const checked = s.checked;
	return checked === "mixed" ? "mixed" : checked === true ? "checked" : checked === false ? "unchecked" : "none";
}

function width(w: number | "auto"): string {
	return w === "auto" ? "auto" : String(w);
}

function level(v: boolean | "half" | "full"): string {
	if (v === true) return "on";
	if (v === "half") return "half";
	return v === false ? "off" : "full";
}

console.log(`${show(true)} ${show("mixed")} ${show(false)}`
	+ `|${showField({ checked: "mixed" })} ${showField({ checked: true })} ${showField({ checked: false })} ${showField({})}`
	+ `|${width("auto")} ${width(3)}`
	+ `|${level(true)} ${level("half")}`);
