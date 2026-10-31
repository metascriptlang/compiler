export default function metascriptLoader() {
	const callback = this.async();
	this.cacheable(false);
	try {
		if (!this.metascriptModule) throw new Error("MetaScript loader requires MetaScriptPlugin in webpack plugins");
		const output = this.metascriptModule(this.resourcePath + (this.resourceQuery ?? ""));
		callback(null, output.code, output.map ?? undefined);
	} catch (error) {
		callback(error);
	}
}
