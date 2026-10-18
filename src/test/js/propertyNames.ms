import { compileToJS } from "../helpers";

test "property names: a literal key that is not an identifier is quoted, an identifier key stays bare" {
	const c = compileToJS("const attrs = { \"data-probe\": \"counter\", \"q\\\"b\": \"quote\", \"42\": \"num\", plain: \"bare\" };\nconsole.log(attrs.plain);");
	assert c.ok, c.ok ? "" : c.error;
	if (!c.ok) return;
	assert c.value.contains("{ \"data-probe\": \"counter\", \"q\\\"b\": \"quote\", \"42\": \"num\", plain: \"bare\" }");
}
