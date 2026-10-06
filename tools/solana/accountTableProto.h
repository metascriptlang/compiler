#ifndef MS_ACCOUNT_TABLE_PROTO_H
#define MS_ACCOUNT_TABLE_PROTO_H

#include "runtime/solana/solana.h"

static inline uint64_t msSolAccountTable(void) {
    return msSolContext()->accountTable;
}

#endif
