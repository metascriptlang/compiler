const instances = [];
const instantiate = WebAssembly.instantiate;
WebAssembly.instantiate = async function (...args) {
	const r = await instantiate.apply(this, args);
	instances.push(r.instance ?? r);
	return r;
};
process.on("exit", () => {
	for (const i of instances) {
		if (typeof i.exports.msb_ledger != "function") {
			throw new Error("wasmmix: the wasm half has no msb_ledger export");
		}
		i.exports.msb_ledger();
	}
});
