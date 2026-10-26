// @stdout: ascii [] [a] [!siht esreveR]
// @stdout: multibyte [漢兩秦先] [olléh] [😁x😀]
// @stdout: combining [f̅ds⃝a] [c⃞b⃞a⃞] [à]
function show(label: string, parts: string[]): void {
	console.log(`${label} ${parts.map((p) => `[${p.reverse()}]`).join(" ")}`);
}

show("ascii", ["", "a", "Reverse this!"]);
show("multibyte", ["先秦兩漢", "héllo", "😀x😁"]);
show("combining", ["as⃝df̅", "a⃞b⃞c⃞", "̀a"]);
