#include "runtime/drc.h"
void walk__SsrcZastZvisitorOms_u0(Node__SstdZmetaZnodeOms* node) {
Node__SstdZmetaZnodeOms* dollarborrow_1_;
#line 10 "src/ast/visitor.ms"
    msIncrefCyclic(dollarborrow_1_);
    msIncrefCyclic(node);
    msIncref(s);
    msDecref(s);
    msDecrefCyclic(node);
    goto __finally_1;
__finally_1:
    msDecrefCyclic(dollarborrow_1_);
}
int32_t sum__SsrcZcheckerZvar80artitionsOms_u1(int32_t n) {
    msIncref((Node__SstdZmetaZnodeOms*)dollarborrow_2_);
    msDecrefCyclicEdge(x);
    __atomic_fetch_add(&c, 1);
    msAtomicLoad(c);
    return n;
}
void Node__SstdZmetaZnodeOmsDestroy(Node__SstdZmetaZnodeOms* self) {
    msDecrefCyclic(self->parent);
}
void HashMapEntry_a7nncc__ref_Symbol_1hpfwsrTrace(void* p) {
    msDecref(p);
}
void Doc__SsrcZfmtZdocOms_init(Doc__SsrcZfmtZdocOms* self) {
    msIncref(self->kids);
}
