import { jsxDom, el, txt, attr, DomNode, render } from "std/meta/jsxDom";

function main(): void {
    const tree: DomNode = jsxDom(<div id="app"><h1>Hello</h1><p>JSX works</p></div>);
    console.log(render(tree));
}
main();
