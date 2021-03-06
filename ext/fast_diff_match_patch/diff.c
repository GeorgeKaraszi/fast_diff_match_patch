
#include "fast_diff_match_patch.h"
#include "diff.h"

static VALUE diff_bisect(VALUE self, VALUE text1, VALUE text2, VALUE deadline);

void dmp_init_diff()
{
    rb_define_method(dmp_klass, "diff_bisect", RUBY_METHOD_FUNC(diff_bisect), 3);
}

// Converts ruby object into integer
// Ruby equivalent code: "1337".to_i
static long rb_to_i(VALUE object)
{
    return FIX2LONG(RB_FUNC_CALL(object, dmp_to_i_id));
}

// Returns the current time, converted to an integer
// Ruby equivalent code: Time.now.to_i
static long time_now()
{
    return rb_to_i(RB_FUNC_CALL(dmp_time_klass, dmp_time_now_id));
}

// Find the 'middle snake' of a diff, split the problem in two
// and return the recursively constructed diff.
// See Myers 1986 paper: An O(ND) Difference Algorithm and Its Variations.

static VALUE diff_bisect(VALUE self, VALUE text1, VALUE text2, VALUE deadline) {
    DMPString dmp_text2       = rb_str_to_dmp_hash(text2);
    DMPString dmp_text1       = rb_str_to_dmp_hash(text1);
    const long deadline_l     = deadline == Qnil ? Qnil : rb_to_i(deadline);
    const int text1_length    = dmp_text1.size;
    const int text2_length    = dmp_text2.size;
    const int delta           = text1_length - text2_length;
    const int max_d           = (text1_length + text2_length + 1) / 2;
    const int v_offset        = max_d;
    const int v_length        = 2 * max_d;
    const bool front          = (delta % 2 != 0);

    int v1[v_length];
    int v2[v_length];
    int k1start   = 0;
    int k1end     = 0;
    int k2start   = 0;
    int k2end     = 0;
    int k1_offset = 0;
    int k2_offset = 0;
    int x1        = 0;
    int x2        = 0;
    int y1        = 0;
    int y2        = 0;
    int d         = 0;
    int k1        = 0;
    int k2        = 0;

    memset(v1, -1, v_length * sizeof(int));
    memset(v2, -1, v_length * sizeof(int));
    v1[v_offset + 1] = 0;
    v2[v_offset + 1] = 0;

    for(d = 0; d < max_d; d++)
    {
        if(deadline_l != Qnil && time_now() >= deadline_l)
        {
            break;
        }

        for(k1 = -d + k1start; k1 <= d - k1end; k1 += 2)
        {
            k1_offset = v_offset + k1;
            if(k1 == -d || (k1 != d && v1[k1_offset - 1] < v1[k1_offset + 1]))
            {
                x1 = v1[k1_offset + 1];
            } else {
                x1 = v1[k1_offset - 1] + 1;
            }

            y1 = x1 - k1;
            while(x1 < text1_length &&
                  y1 < text2_length &&
                  DMP_CMP(dmp_text1.chars[x1], dmp_text2.chars[y1]))
            {
                x1++;
                y1++;
            }

            v1[k1_offset] = x1;
            if(x1 > text1_length)
            {
                k1end += 2;
            } else if(y1 > text2_length) {
                k1start += 2;
            } else if(front) {
                k2_offset = v_offset + delta - k1;
                if(k2_offset >= 0 && k2_offset < v_length && v2[k2_offset] != -1)
                {
                    x2 = text1_length - v2[k2_offset];
                    if(x1 >= x2)
                    {
                        FREE_DMP_STR2(dmp_text1, dmp_text2);
                        return rb_funcall(self, dmp_diff_bisect_split_id, 5, text1, text2, INT2FIX(x1), INT2FIX(y1), deadline);
                    }
                }
            }
        }

        for(k2 = -d + k2start; k2 <= d - k2end; k2 += 2)
        {
            k2_offset = v_offset + k2;
            if(k2 == -d || (k2 != d && v2[k2_offset - 1] < v2[k2_offset + 1]))
            {
                x2 = v2[k2_offset + 1];
            } else {
                x2 = v2[k2_offset - 1] + 1;
            }

            y2 = x2 - k2;
            while(x2 < text1_length &&
                  y2 < text2_length &&
                  DMP_CMP(dmp_text1.chars[text1_length - x2 - 1],
                          dmp_text2.chars[text2_length - y2 - 1])
                    )
            {
                x2++;
                y2++;
            }

            v2[k2_offset] = x2;
            if(x2 > text1_length)
            {
                k2end += 2;
            } else if(y2 > text2_length) {
                k2start += 2;
            } else if(!front) {
                k1_offset = v_offset + delta - k2;
                if(k1_offset >= 0 && k1_offset < v_length && v1[k1_offset] != -1)
                {
                    x1 = v1[k1_offset];
                    y1 = v_offset + x1 - k1_offset;
                    x2 = text1_length - x2;
                    if(x1 >= x2) {
                        FREE_DMP_STR2(dmp_text1, dmp_text2);
                        return rb_funcall(self, dmp_diff_bisect_split_id, 5, text1, text2, INT2FIX(x1), INT2FIX(y1), deadline);
                    }
                }
            }
        }
    }


    FREE_DMP_STR2(dmp_text1, dmp_text2);
    return rb_ary_new_from_args(
            2,
            rb_funcall(self, dmp_new_delete_node_id, 1, text1),
            rb_funcall(self, dmp_new_insert_node_id, 1, text2)
    );
}