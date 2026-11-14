import { compileToCWithStd, compileToJSWithStd } from "../helpers";

test "a @comptime block runs each overload of a static member through its Raiser tier, on C and JS" {
	const source = "const a = @comptime { return String.fromCharCode(72, 105) + String.fromCharCode(33); }; console.log(a);";
	for (const result of [compileToCWithStd(source), compileToJSWithStd(source)]) {
		assert result.ok, result.ok ? "" : result.error;
		if (result.ok) assert result.value.contains("Hi!"), result.value;
	}
}
