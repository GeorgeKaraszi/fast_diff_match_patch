#ifndef FAST_DIFF_MATCH_PATCH_H
#define FAST_DIFF_MATCH_PATCH_H 1

#include <stdbool.h>
#include "ruby.h"

#define MAX_UTF_8_BYTES 4
#define NELEMS(x)                        (sizeof(x) / sizeof((x)[0]))
#define NELEMS2(x, type)                 (sizeof(x) / sizeof(type))
#define DMP_STR_CMP(x, y)                ( MEMCMP(x.bytes, y.bytes, short, MAX_UTF_8_BYTES) == 0 )
#define RB_FUNC_CALL(caller, func_id)    ( rb_funcall(caller, func_id, 0) )
#define RB_ARRAY_REF(rb_array, rb_index) ( rb_ary_aref(1, &rb_index, rb_array) )

typedef struct DMPBytes {
    short size;
    short bytes[MAX_UTF_8_BYTES];
} DMPBytes;

typedef struct DMPString {
    int size;
    DMPBytes *chars;
} DMPString;


#endif /* FAST_DIFF_MATCH_PATCH_H */
