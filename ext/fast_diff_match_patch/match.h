#ifndef FAST_DIFF_MATCH_PATCH_MATCH_H
#define FAST_DIFF_MATCH_PATCH_MATCH_H

#define DMP_ABS(x, size)        ((x < 0 ? size + x : x))
#define DMP_HASH_KEY(hash, key) ((uint)DMP_ABS(key % hash->size, hash->size))

#define FREE_DMP_HT(hash_tbl)   (destroy_hash(hash_tbl))

typedef struct DMP_HT_ELM
{
    struct DMP_HT_ELM *next;
    long key;
    long value;
}DMP_HT_ELM;

typedef struct DMP_HT
{
    unsigned int size;
    unsigned int count;
    DMP_HT_ELM **values;
} DMP_HT;


extern void dmp_init_match();

#endif //FAST_DIFF_MATCH_PATCH_MATCH_H
