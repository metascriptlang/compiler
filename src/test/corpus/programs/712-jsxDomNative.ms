// @maxrss: 30
// @stdout: jsxdom-native PASS
// note: End-to-end proof of the jsxDom reference macro (std/meta/jsxDom.ms): JSX → DomNode tree → render string. A macro rewrites <div id=app><h1>Hi</h1><p>x</p></div> into el()/txt()/attr() runtime calls at compile time; nested <h1>/<p> recurse via RE-EXPANSION (the macro emits jsxDom(child), the expander re-walks it — macro helper fns can't navigate/build Node values, only the macro body's return position is special-typed, so recursion can't be a helper). The marker prints only if render() is byte-exact, so this guards the whole JSX→macro→codegen path natively. Proves JSX is usable end-to-end, not just parseable.

// End-to-end native guard for the jsxDom reference macro (std/meta/jsxDom.ms): JSX → DomNode
// tree → render string. Exercises attrs, text children, and nested elements (recursion via
// re-expansion: a nested <h1>/<p> is emitted as jsxDom(child) and re-walked). Building this
// natively runs the whole JSX→macro→codegen path; the marker prints only if the rendered HTML
// is byte-exact, proving JSX is usable end-to-end, not just parseable. Note: el/txt/attr must be
// imported because the macro EMITS calls to them at the use site.

import { jsxDom, el, txt, attr, DomNode, render } from "std/meta/jsxDom";

function main(): void {
	const tree: DomNode = jsxDom(<div id="app"><h1>Hi</h1><p>x</p></div>);
	const out = render(tree);
	if (out == "<div id=\"app\"><h1>Hi</h1><p>x</p></div>") { console.log("jsxdom-native PASS"); }
	else { console.log("jsxdom-native FAIL: " + out); }
}
main();
