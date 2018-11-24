#ifndef FAST_DIFF_MATCH_PATCH_H
#define FAST_DIFF_MATCH_PATCH_H 1

#include <stdbool.h>
#include "ruby.h"

#define DMP_CMP(x, y)                    ( x == y )
#define DMP_MAX(x, y)                    ( x > y ? x : y )
#define DMP_MIN(x, y)                    ( x > y ? y : x )

#define RB_FUNC_CALL(caller, func_id)    ( rb_funcall(caller, func_id, 0) )
#define RB_ARRAY_REF(rb_array, rb_index) ( rb_ary_aref(1, &rb_index, rb_array) )

#define FREE_DMP_STR2(x, y)              (FREE_DMP_STR_N(2, &x, &y))
#define FREE_DMP_STR_N(count, ...)       (free_dmp_str(count, __VA_ARGS__))

typedef struct DMPString {
    unsigned int size;
    long *chars;
} DMPString;

extern void free_dmp_str(int count, ...);
extern DMPString rb_str_to_dmp_hash(VALUE text);

// Ruby Class instance ID's
extern VALUE dmp_klass;
extern VALUE dmp_time_klass;

// Ruby function reference ID's
extern ID dmp_new_delete_node_id;
extern ID dmp_new_insert_node_id;
extern ID dmp_diff_bisect_split_id;
extern ID dmp_time_now_id;
extern ID dmp_to_i_id;
extern ID dmp_chars_id;

// DMP Class instance variables
extern double dmp_match_threshold;
extern unsigned int dmp_match_distance;
extern unsigned int dmp_max_bits;

#endif /* FAST_DIFF_MATCH_PATCH_H */
