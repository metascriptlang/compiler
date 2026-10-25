#include "runtime/drc.h"
void walk__SsrcZastZvisitorOms_u0(Node__SstdZmetaZnodeOms* node) {
Node__SstdZmetaZnodeOms* dollarborrow_1_;
Node__SstdZmetaZnodeOms* dollarborrow_2_;
    msIncrefCyclic(dollarborrow_1_);
    msIncrefCyclic(dollarborrow_2_);
    msIncrefCyclic(node);
    msIncref(s);
    msDecref(s);
    msDecrefCyclic(node);
    goto __finally_1;
__finally_1:
    msDecrefCyclic(dollarborrow_1_);
    goto __finally_2;
__finally_2:
    msDecrefCyclic(dollarborrow_2_);
}
void Node__SstdZmetaZnodeOmsDestroy(Node__SstdZmetaZnodeOms* self) {
    msDecrefCyclic(self->parent);
}
void SsrcZnewOms__Init000(void) {
    msIncref(g);
}
