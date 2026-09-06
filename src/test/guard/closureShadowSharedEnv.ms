function host7(): int32 {
    let s = 5;
    const bump = () => { s = s + 1; };
    bump();
    const f = (n: int32) => {
        let s = 0;
        const inner = () => { s = s + n; };
        inner();
        inner();
        return s;
    };
    return s * 100 + f(3);
}
const r = host7();
if (r != 606) { throw "GUARD RED: shadowed closure local aliased ancestor env r=" + r; }
console.log("closureShadowSharedEnv ok");
