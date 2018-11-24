#include "fast_diff_match_patch.h"
#include "match.h"

static VALUE match_bitap(VALUE rb_self, VALUE rb_text, VALUE rb_pattern, VALUE rb_loc);

void dmp_init_match()
{
    rb_define_method(dmp_klass, "match_bitap", RUBY_METHOD_FUNC(match_bitap), 3);
}

// Set the extern global variables with the current instance variable settings
static void set_instance_vars(VALUE self)
{
    dmp_match_threshold = RFLOAT_VALUE(rb_iv_get(self, "@match_threshold"));
    dmp_match_distance  = FIX2UINT(rb_iv_get(self, "@match_distance"));
    dmp_max_bits        = FIX2UINT(rb_iv_get(self, "@match_max_bits"));
}

// Free's DMPHash structure and all of its nested child elements
static void destroy_hash(DMP_HT *hash)
{
    unsigned int i = 0;

    for(i = 0; i < hash->size; i++)
    {
        DMP_HT_ELM *e = hash->values[i];

        while(e != NULL)
        {
            DMP_HT_ELM *o = e->next;
            free(e);
            e = o;
        }
    }

    free(hash->values);
    free(hash);
}

// Initialize new DMP_HT from a given size
// Returns:
//   - struct DMP_HT*
static DMP_HT *new_hash(const unsigned int size)
{
    unsigned int i = 0;
    DMP_HT *hash  = ALLOC(DMP_HT);
    hash->size     = size;
    hash->count    = 0;
    hash->values   = ALLOC_N(DMP_HT_ELM*, size);

    for(i = 0; i < hash->size; i++)
    {
        hash->values[i] = NULL;
    }

    return hash;
}

// Find a hash element based on a supplied key
// Returns:
//   - struct DMP_HT_ELM*  #=> if key is found
//   - NULL                #=> if key is not found
static DMP_HT_ELM *hash_lookup(const DMP_HT *hash, const long key)
{
    if(hash->count == 0) return NULL;

    unsigned int idx = DMP_HASH_KEY(hash, key);
    DMP_HT_ELM *e    = hash->values[idx];

    while(e != NULL)
    {
        if(e->key == key)
        {
            return e;
        } else {
            e = e->next;
        }
    }

    return NULL;
}

// Inserts a new element into the hash table.
// To prevent collisions: on any hash index, a new link list item is appended to the head of the hash value.
static void hash_insert(DMP_HT *hash, const long key, const long value)
{

    // Deal with possible collision by inserting the element to the head of the link list
    int idx              = DMP_HASH_KEY(hash, key);
    DMP_HT_ELM *new_elem = ALLOC(DMP_HT_ELM);
    new_elem->next       = hash->values[idx];
    new_elem->key        = key;
    new_elem->value      = value;
    hash->values[idx]    = new_elem;
    hash->count++;
}

// Find the first instance index of the given pattern starting at the given position
// Ruby equivalent code: "Zellow".index("l") #=> 2
static int index_of(const DMPString text, const DMPString pattern, const int pos)
{
    unsigned int i = 0;
    unsigned int j = 0;

    for(i = (unsigned int)pos; i < text.size; i++)
    {
        for(j = 0; j < pattern.size && i + j < text.size; j++)
        {
            if(!DMP_CMP(text.chars[i + j], pattern.chars[j]))
            {
                break;
            }
        }

        if(j > pattern.size)
        {
            return i;
        }
    }

    return Qnil;
}

// Find the last instance index of the given pattern starting at the given position
// Ruby equivalent code: "Zellow".rindex("l") #=> 3
static int rindex_of(const DMPString text, const DMPString pattern, const int pos)
{
    int i = 0;
    int j = 0;

    for(i = text.size - 1; i >= pos; i--)
    {
        for(j = pattern.size - 1; j >= 0 && i - j >= pos; j--)
        {
            if(!DMP_CMP(text.chars[i - j], pattern.chars[j]))
            {
                break;
            }
        }

        if(j <= 0)
        {
            return i - (pattern.size - 1);
        }
    }
    return Qnil;
}

// Calculates score based current location and matching distance.
// Returns: floating point value on calculated score
static double match_bitap_score(const int start, const int end, const DMPString pattern, const int location)
{
    double accuracy  = ((double) start) / pattern.size;
    double proximity = location - end;
    proximity        = proximity < 0.0 ? proximity * -1 : proximity;

    if(dmp_match_distance == 0)
    {
        return proximity == 0.0 ? accuracy : 1.0;
    }

    return accuracy + (proximity / dmp_match_distance);
}

// Generates a hash table for each pattern character; bit shifting like minded characters based on latest position.
// If Pattern is size 11 it'll bit shift from 1024, 512, 256, ... 1
// Ruby equivalent code:
//    pattern.chars.each do |c|
//      hash[c] ||= 0
//      hash[c] |=  1 << (pattern.length - i - 1)
//    end
//
// Returns: struct DMP_HT* #=> Hash table containing each character with bit shifted results.
static DMP_HT *generate_pattern_hash(const DMPString pattern)
{
    DMP_HT *alphabet    = new_hash(pattern.size);
    DMP_HT_ELM *element = NULL;
    unsigned int i      = 0;
    long val            = 0;

    for(i = 0; i < pattern.size; i++)
    {
        val     = 1 << (pattern.size - i - 1);
        element = hash_lookup(alphabet, pattern.chars[i]);

        if(element != NULL)
        {
            element->value |= val;
        } else {
            hash_insert(alphabet, pattern.chars[i], val);
        }
    }

    return alphabet;
}

// Performs a fuzzy search for the pattern in side the text.
// Returns: index of the matched pattern.
static VALUE match_bitap(VALUE rb_self, VALUE rb_text, VALUE rb_pattern, VALUE rb_loc)
{
    set_instance_vars(rb_self);
    const DMPString pattern = rb_str_to_dmp_hash(rb_pattern);
    const DMPString text    = rb_str_to_dmp_hash(rb_text);
    const int loc           = FIX2UINT(rb_loc);
    const int max_rd        = pattern.size + text.size + 2;
    const int match_mask    = 1 << (pattern.size - 1);
    DMP_HT *alpha           = generate_pattern_hash(pattern);
    DMP_HT_ELM *element     = NULL;
    double score_threshold  = dmp_match_threshold;
    double best_score       = 0;
    double tmp_score        = 0;
    long   alpha_value      = 0;
    int    bin_max          = max_rd - 2;
    int    bin_mid          = 0;
    int    bin_min          = 0;
    int    best_loc         = 0;
    int    j, finish, start;
    unsigned int i;

    VALUE last_rd[max_rd];
    VALUE rd[max_rd];


    if(pattern.size > dmp_max_bits) {
        FREE_DMP_HT(alpha);
        FREE_DMP_STR2(pattern, text);
        rb_raise(rb_eArgError, "Pattern is too large for this application");
    }

    best_loc = index_of(text, pattern, loc);
    if(best_loc != Qnil)
    {
        best_score        = match_bitap_score(0, best_loc, pattern, loc);
        score_threshold   = DMP_MIN(best_score, score_threshold);
        best_loc          = rindex_of(text, pattern, loc + pattern.size);

        if(best_loc != Qnil)
        {
            best_score      = match_bitap_score(0, best_loc, pattern, loc);
            score_threshold = DMP_MIN(best_score, score_threshold);
        }
    }

    best_loc = -1;

    for(i = 0; i < pattern.size; i++)
    {
        // Scan for the best match; each iteration allows for one more error.
        // Run a binary search to determine how far from 'loc' we can stray at this
        // error level.
        bin_min = 0;
        bin_mid = bin_max;

        while(bin_min < bin_mid)
        {
            if(match_bitap_score(i, loc + bin_mid, pattern, loc) <= score_threshold)
            {
                bin_min = bin_mid;
            } else {
                bin_max = bin_mid;
            }

            bin_mid = (bin_max - bin_min) / 2 + bin_min;
        }

        // Use the result from this iteration as the maximum for the next
        bin_max  = bin_mid;
        start    = DMP_MAX(1, loc - bin_mid + 1);
        finish   = DMP_MIN(loc + bin_mid, (int)text.size) + pattern.size;


        MEMZERO(rd, VALUE, max_rd);
        rd[finish + 1] = (VALUE) ((1 << i) - 1);

        for(j = finish; j >= start; j--)
        {
            element      = hash_lookup(alpha, text.chars[j-1]);
            alpha_value  = element == NULL ? 0 : element->value;

            if(i == 0)
            {
                // First pass: exact match.
                rd[j] = ((rd[j + 1] << 1) | 1) & alpha_value;
            } else {
                // Subsequent passes: fuzzy match.
                rd[j] = (((rd[j + 1] << 1) | 1) & alpha_value) | (((last_rd[j + 1] | last_rd[j]) << 1) | 1) | last_rd[j + 1];
            }

            // We might have some kinda of fuzzy match when the Bitwise OP is not 0
            if((rd[j] & match_mask) == 0)
            {
                continue;
            }

            tmp_score = match_bitap_score(i, j-1, pattern, loc);

            if (tmp_score <= score_threshold)
            {
                score_threshold = tmp_score;
            } else {
                continue;
            }

            best_loc = j - 1; // New best match location was found
            if(best_loc > loc)
            {
                //When passing loc, don't exceed our current distance from loc.
                start = DMP_MAX(1, 2 * loc - best_loc);
            } else {
                break;
            }

        }

        if(match_bitap_score(i + 1, loc, pattern, loc) > score_threshold)
        {
            break; // No hope for a (better) match at greater error levels.
        }


        // Copy over mappings to perform further fuzzy matching
        MEMCPY(last_rd, rd, VALUE, max_rd);
    }

    FREE_DMP_HT(alpha);
    FREE_DMP_STR2(pattern, text);
    return INT2FIX(best_loc);
}

