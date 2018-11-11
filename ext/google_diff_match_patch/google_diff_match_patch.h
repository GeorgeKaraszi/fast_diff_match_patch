#ifndef GOOGLE_DIFF_MATCH_PATCH_H
#define GOOGLE_DIFF_MATCH_PATCH_H 1

#include <stdbool.h>
#include "ruby.h"

#define DMP_STR_BYTE_COUNT 6
#define NELEMS(x)                     (sizeof(x) / sizeof((x)[0]))
#define NELEMS2(x, type)              (sizeof(x) / sizeof(type))
#define DMP_STR_CMP(x, y)             ( MEMCMP(x, y, short, DMP_STR_BYTE_COUNT) == 0 )
#define RB_FUNC_CALL(caller, func_id) ( rb_funcall(caller, func_id, 0) )

typedef struct DMPBytes {
    int size;
    short bytes[DMP_STR_BYTE_COUNT];
} DMPBytes;

typedef struct DMPString {
    int size;
    DMPBytes *chars;
} DMPString;


#endif /* GOOGLE_DIFF_MATCH_PATCH_H */
