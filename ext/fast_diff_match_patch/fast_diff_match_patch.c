#include "fast_diff_match_patch.h"
#include "diff.h"
#include "match.h"

// Ruby Class instance ID's
VALUE dmp_klass;
VALUE dmp_time_klass;

// Ruby function reference ID's
ID dmp_new_delete_node_id;
ID dmp_new_insert_node_id;
ID dmp_diff_bisect_split_id;
ID dmp_time_now_id;
ID dmp_to_i_id;
ID dmp_chars_id;

// DMP Class instance variables
double dmp_match_threshold;
unsigned int dmp_match_distance;
unsigned int dmp_max_bits;


void Init_fast_diff_match_patch()
{
    rb_require("time");

    dmp_klass                = rb_define_class("FastDiffMatchPatch", rb_cObject);
    dmp_time_klass           = rb_const_get(rb_cObject, rb_intern("Time"));
    dmp_new_delete_node_id   = rb_intern("new_delete_node");
    dmp_new_insert_node_id   = rb_intern("new_insert_node");
    dmp_diff_bisect_split_id = rb_intern("diff_bisect_split");
    dmp_time_now_id          = rb_intern("now");
    dmp_to_i_id              = rb_intern("to_i");
    dmp_chars_id             = rb_intern("chars");

    // Append functions to the DMP Class instance
    dmp_init_diff();
    dmp_init_match();
}

// Free's (N) number of DMPString character allocations
void free_dmp_str(int count, ...)
{
    va_list list;
    int i = 0;

    va_start(list, count);
    for(i = 0; i < count; i++)
    {
        DMPString *val = va_arg(list, DMPString*);
        xfree(val->chars);
    }
    va_end(list);
}

// Convert UTF8 Ruby string into hash values
// Ruby equivalent code:  #=> "ὂ᭚".chars => ["ὂ", "᭚"].map(&:hash) #=> [2688663840084111788, -346891196368687346]
DMPString rb_str_to_dmp_hash(const VALUE text)
{
    // Ruby equivalent code: "Hey".chars #=> ['H', 'e', 'y']
    const VALUE char_array      = RB_FUNC_CALL(text, dmp_chars_id);
    const unsigned int str_len  = (uint)RARRAY_LENINT(char_array);
    const DMPString dmp_hash    = { str_len, ALLOC_N(long, (size_t)str_len) };

    unsigned int i         = 0;
    VALUE char_hash_value  = 0;
    VALUE char_ary_idx     = INT2FIX(0);

    for(i = 0; i < str_len; char_ary_idx = INT2FIX(++i))
    {
        // Ruby equivalent code: "H".hash #=> -479202348279020166
        char_hash_value   = rb_str_hash(RB_ARRAY_REF(char_array, char_ary_idx));
        dmp_hash.chars[i] = RB_FIX2LONG(char_hash_value);
    }

    return dmp_hash;
}