#include <gtest/gtest.h>
#include <iomanip>
#include <vector>
#include <memory>
#include <algorithm>
#include <initializer_list>
#include <fstream>
#include <string>
#include <sstream>

#include "array/fixnum_array.h"
#include "fixnum/word_fixnum.cu"
#include "fixnum/warp_fixnum.cu"
#include "functions/monty_mul.cu"
#include "functions/modexp.cu"
#include "functions/paillier_encrypt.cu"
#include "functions/paillier_decrypt.cu"

using namespace std;

typedef vector<uint8_t> byte_array;

void die_if(bool p, const string &msg) {
    if (p) {
        cerr << "Error: " << msg << endl;
        abort();
    }
}

::testing::AssertionResult
arrays_are_equal(
    const uint8_t *expected, size_t expected_len,
    const uint8_t *actual, size_t actual_len)
{
    if (expected_len > actual_len) {
        return ::testing::AssertionFailure()
            << "arrays don't have the same length";
    }
    size_t i;
    for (i = 0; i < expected_len; ++i) {
        if (expected[i] != actual[i]) {
            return ::testing::AssertionFailure()
                << "arrays differ: expected[" << i << "] = "
                << static_cast<int>(expected[i])
                << " but actual[" << i << "] = "
                << static_cast<int>(actual[i]);
        }
    }
    for (; i < actual_len; ++i) {
        if (actual[i] != 0) {
            return ::testing::AssertionFailure()
                << "arrays differ: expected[" << i << "] = 0"
                << " but actual[" << i << "] = "
                << static_cast<int>(actual[i]);
        }
    }
    return ::testing::AssertionSuccess();
}


template< typename fixnum_ >
struct TypedPrimitives : public ::testing::Test {
    typedef fixnum_ fixnum;

    TypedPrimitives() {}
};

typedef ::testing::Types<
    warp_fixnum<4, u32_fixnum>,
    warp_fixnum<8, u32_fixnum>,
    warp_fixnum<16, u32_fixnum>,
    warp_fixnum<32, u32_fixnum>,
    warp_fixnum<64, u32_fixnum>,
    warp_fixnum<128, u32_fixnum>,

    warp_fixnum<8, u64_fixnum>,
    warp_fixnum<16, u64_fixnum>,
    warp_fixnum<32, u64_fixnum>,
    warp_fixnum<64, u64_fixnum>,
    warp_fixnum<128, u64_fixnum>,
    warp_fixnum<256, u64_fixnum>
> FixnumImplTypes;

TYPED_TEST_CASE(TypedPrimitives, FixnumImplTypes);

void read_into(ifstream &file, uint8_t *buf, size_t nbytes) {
    file.read(reinterpret_cast<char *>(buf), nbytes);
    die_if( ! file.good(), "Read error.");
    die_if(static_cast<size_t>(file.gcount()) != nbytes, "Expected more data.");
}

uint32_t read_int(ifstream &file) {
    uint32_t res;
    file.read(reinterpret_cast<char*>(&res), sizeof(res));
    return res;
}

template<typename fixnum>
void read_tcases(
        vector<byte_array> &res,
        fixnum_array<fixnum> *&xs,
        const string &fname,
        int nargs) {
    static constexpr int fixnum_bytes = fixnum::BYTES;
    ifstream file(fname + "_" + std::to_string(fixnum_bytes));
    die_if( ! file.good(), "Couldn't open file.");

    uint32_t fn_bytes, vec_len, noutvecs;
    fn_bytes = read_int(file);
    vec_len = read_int(file);
    noutvecs = read_int(file);

    stringstream ss;
    ss << "Inconsistent reporting of fixnum bytes. "
       << "Expected " << fixnum_bytes << " got " << fn_bytes << ".";
    die_if(fixnum_bytes != fn_bytes, ss.str());

    size_t nbytes = fixnum_bytes * vec_len;
    uint8_t *buf = new uint8_t[nbytes];

    read_into(file, buf, nbytes);
    xs = fixnum_array<fixnum>::create(buf, nbytes, fixnum_bytes);

    // ninvecs = number of input combinations
    uint32_t ninvecs = 1;
    for (int i = 1; i < nargs; ++i)
        ninvecs *= vec_len;
    res.reserve(noutvecs * ninvecs);
    for (uint32_t i = 0; i < ninvecs; ++i) {
        for (uint32_t j = 0; j < noutvecs; ++j) {
            read_into(file, buf, nbytes);
            res.emplace_back(buf, buf + nbytes);
        }
    }

    delete[] buf;
}

template< typename fixnum, typename tcase_iter >
void check_result(
    tcase_iter &tcase, uint32_t vec_len,
    initializer_list<const fixnum_array<fixnum> *> args,
    int skip = 1,
    uint32_t nvecs = 1)
{
    static constexpr int fixnum_bytes = fixnum::BYTES;
    size_t total_vec_len = vec_len * nvecs;
    size_t nbytes = fixnum_bytes * total_vec_len;
    // TODO: The fixnum_arrays are in managed memory; there isn't really any
    // point to copying them into buf.
    byte_array buf(nbytes);

    for (auto arg : args) {
        auto buf_iter = buf.begin();
        for (uint32_t i = 0; i < nvecs; ++i) {
            std::copy(tcase->begin(), tcase->end(), buf_iter);
            buf_iter += fixnum_bytes*vec_len;
            tcase += skip;
        }
        EXPECT_TRUE(arrays_are_equal(buf.data(), nbytes, arg->get_ptr(), nbytes));
    }
}

template< typename fixnum >
struct add_cy {
    __device__ void operator()(fixnum &r, fixnum &cy, fixnum a, fixnum b) {
        typedef typename fixnum::digit digit;
        digit c;
        fixnum::add_cy(r, c, a, b);
        // TODO: This is like digit_to_fixnum
        cy = (fixnum::layout::laneIdx() == 0) ? c : digit::zero();
    }
};

TYPED_TEST(TypedPrimitives, add_cy) {
    typedef typename TestFixture::fixnum fixnum;
    typedef fixnum_array<fixnum> fixnum_array;

    fixnum_array *res, *cys, *xs;
    vector<byte_array> tcases;

    read_tcases(tcases, xs, "tests/add_cy", 2);
    int vec_len = xs->length();
    res = fixnum_array::create(vec_len);
    cys = fixnum_array::create(vec_len);

    auto tcase = tcases.begin();
    for (int i = 0; i < vec_len; ++i) {
        fixnum_array *ys = xs->rotate(i);
        fixnum_array::template map<add_cy>(res, cys, xs, ys);
        check_result(tcase, vec_len, {res, cys});
        delete ys;
    }
    delete res;
    delete cys;
    delete xs;
}


template< typename fixnum >
struct sub_br {
    __device__ void operator()(fixnum &r, fixnum &br, fixnum a, fixnum b) {
        typedef typename fixnum::digit digit;
        digit bb;
        fixnum::sub_br(r, bb, a, b);
        br = (fixnum::layout::laneIdx() == 0) ? bb : digit::zero();
    }
};

TYPED_TEST(TypedPrimitives, sub_br) {
    typedef typename TestFixture::fixnum fixnum;
    typedef fixnum_array<fixnum> fixnum_array;

    fixnum_array *res, *brs, *xs;
    vector<byte_array> tcases;

    read_tcases(tcases, xs, "tests/sub_br", 2);
    int vec_len = xs->length();
    res = fixnum_array::create(vec_len);
    brs = fixnum_array::create(vec_len);

    auto tcase = tcases.begin();
    for (int i = 0; i < vec_len; ++i) {
        fixnum_array *ys = xs->rotate(i);
        fixnum_array::template map<sub_br>(res, brs, xs, ys);
        check_result(tcase, vec_len, {res, brs});
        delete ys;
    }
    delete res;
    delete brs;
    delete xs;
}

template< typename fixnum >
struct mul_lo {
    __device__ void operator()(fixnum &r, fixnum a, fixnum b) {
        fixnum rr;
        fixnum::mul_lo(rr, a, b);
        r = rr;
    }
};

TYPED_TEST(TypedPrimitives, mul_lo) {
    typedef typename TestFixture::fixnum fixnum;
    typedef fixnum_array<fixnum> fixnum_array;

    fixnum_array *res, *xs;
    vector<byte_array> tcases;

    read_tcases(tcases, xs, "tests/mul_wide", 2);
    int vec_len = xs->length();
    res = fixnum_array::create(vec_len);

    auto tcase = tcases.begin();
    for (int i = 0; i < vec_len; ++i) {
        fixnum_array *ys = xs->rotate(i);
        fixnum_array::template map<mul_lo>(res, xs, ys);
        check_result(tcase, vec_len, {res}, 2);
        delete ys;
    }
    delete res;
    delete xs;
}

template< typename fixnum >
struct mul_hi {
    __device__ void operator()(fixnum &r, fixnum a, fixnum b) {
        fixnum rr;
        fixnum::mul_hi(rr, a, b);
        r = rr;
    }
};

TYPED_TEST(TypedPrimitives, mul_hi) {
    typedef typename TestFixture::fixnum fixnum;
    typedef fixnum_array<fixnum> fixnum_array;

    fixnum_array *res, *xs;
    vector<byte_array> tcases;

    read_tcases(tcases, xs, "tests/mul_wide", 2);
    int vec_len = xs->length();
    res = fixnum_array::create(vec_len);

    auto tcase = tcases.begin() + 1;
    for (int i = 0; i < vec_len; ++i) {
        fixnum_array *ys = xs->rotate(i);
        fixnum_array::template map<mul_hi>(res, xs, ys);
        check_result(tcase, vec_len, {res}, 2);
        delete ys;
    }
    delete res;
    delete xs;
}

template< typename fixnum >
struct mul_wide {
    __device__ void operator()(fixnum &s, fixnum &r, fixnum a, fixnum b) {
        fixnum rr, ss;
        fixnum::mul_wide(ss, rr, a, b);
        s = ss;
        r = rr;
    }
};

TYPED_TEST(TypedPrimitives, mul_wide) {
    typedef typename TestFixture::fixnum fixnum;
    typedef fixnum_array<fixnum> fixnum_array;

    fixnum_array *his, *los, *xs;
    vector<byte_array> tcases;

    read_tcases(tcases, xs, "tests/mul_wide", 2);
    int vec_len = xs->length();
    his = fixnum_array::create(vec_len);
    los = fixnum_array::create(vec_len);

    auto tcase = tcases.begin();
    for (int i = 0; i < vec_len; ++i) {
        fixnum_array *ys = xs->rotate(i);
        fixnum_array::template map<mul_wide>(his, los, xs, ys);
        check_result(tcase, vec_len, {los, his});
        delete ys;
    }
    delete his;
    delete los;
    delete xs;
}

template< typename fixnum >
struct my_modexp {
    __device__ void operator()(fixnum &z, fixnum x, fixnum e, fixnum m) {
        modexp<fixnum> me(m, e);
        fixnum zz;
        me(zz, x);
        z = zz;
    };
};

TYPED_TEST(TypedPrimitives, modexp) {
    typedef typename TestFixture::fixnum fixnum;
    typedef fixnum_array<fixnum> fixnum_array;

    fixnum_array *res, *input, *xs, *zs;
    vector<byte_array> tcases;

    read_tcases(tcases, input, "tests/modexp", 3);
    int vec_len = input->length();
    int vec_len_sqr = vec_len * vec_len;

    res = fixnum_array::create(vec_len_sqr);
    xs = input->repeat(vec_len);
    zs = input->rotations(vec_len);

    auto tcase = tcases.begin();
    for (int i = 0; i < vec_len; ++i) {
        fixnum_array *tmp = input->rotate(i);
        fixnum_array *ys = tmp->repeat(vec_len);
        fixnum_array::template map<my_modexp>(res, xs, ys, zs);
        check_result(tcase, vec_len, {res}, 1, vec_len);
        delete ys;
        delete tmp;
    }
    delete res;
    delete input;
    delete xs;
    delete zs;
}


template< typename fixnum >
struct my_multi_modexp {
    __device__ void operator()(fixnum &z, fixnum x, fixnum e, fixnum m) {
        multi_modexp<fixnum> mme(m);
        fixnum zz;
        mme(zz, x, e);
        z = zz;
    };
};

TYPED_TEST(TypedPrimitives, multi_modexp) {
    typedef typename TestFixture::fixnum fixnum;
    typedef fixnum_array<fixnum> fixnum_array;

    fixnum_array *res, *input, *xs, *zs;
    vector<byte_array> tcases;

    read_tcases(tcases, input, "tests/modexp", 3);
    int vec_len = input->length();
    int vec_len_sqr = vec_len * vec_len;

    res = fixnum_array::create(vec_len_sqr);
    xs = input->repeat(vec_len);
    zs = input->rotations(vec_len);

    auto tcase = tcases.begin();
    for (int i = 0; i < vec_len; ++i) {
        fixnum_array *tmp = input->rotate(i);
        fixnum_array *ys = tmp->repeat(vec_len);
        fixnum_array::template map<my_multi_modexp>(res, xs, ys, zs);
        check_result(tcase, vec_len, {res}, 1, vec_len);
        delete ys;
        delete tmp;
    }
    delete res;
    delete input;
    delete xs;
    delete zs;
}

template< typename fixnum >
struct pencrypt {
    __device__ void operator()(fixnum &z, fixnum p, fixnum q, fixnum r, fixnum m) {
        fixnum n, zz;
        fixnum::mul_lo(n, p, q);
        paillier_encrypt<fixnum> enc(n);
        enc(zz, m, r);
        z = zz;
    };
};

template< typename fixnum >
struct pdecrypt {
    __device__ void operator()(fixnum &z, fixnum ct, fixnum p, fixnum q, fixnum r, fixnum m) {
        if (fixnum::cmp(p, q) == 0
              || fixnum::cmp(r, p) == 0
              || fixnum::cmp(r, q) == 0) {
            z = fixnum::zero();
            return;
        }
        paillier_decrypt<fixnum> dec(p, q);
        fixnum n, zz;
        dec(zz, fixnum::zero(), ct);
        fixnum::mul_lo(n, p, q);
        quorem_preinv<fixnum> qr(n);
        qr(m, fixnum::zero(), m);

        // z = (z != m)
        z = fixnum::digit( !! fixnum::cmp(zz, m));
    };
};

TYPED_TEST(TypedPrimitives, paillier) {
    typedef typename TestFixture::fixnum fixnum;

    typedef fixnum ctxt;
    // TODO: BYTES/2 only works when BYTES > 4
    //typedef default_fixnum<ctxt::BYTES/2, typename ctxt::word_tp> ptxt;
    typedef fixnum ptxt;

    typedef fixnum_array<ctxt> ctxt_array;
    typedef fixnum_array<ptxt> ptxt_array;

    ctxt_array *ct, *pt, *p;
    vector<byte_array> tcases;
    read_tcases(tcases, p, "tests/paillier_encrypt", 4);

    int vec_len = p->length();
    ct = ctxt_array::create(vec_len);
    pt = ctxt_array::create(vec_len);

    // TODO: Parallelise these tests similar to modexp above.
    ctxt_array *zeros = ctxt_array::create(vec_len, 0);
    auto tcase = tcases.begin();
    for (int i = 0; i < vec_len; ++i) {
        ctxt_array *q = p->rotate(i);
        for (int j = 0; j < vec_len; ++j) {
            ctxt_array *r = p->rotate(j);
            for (int k = 0; k < vec_len; ++k) {
                ctxt_array *m = p->rotate(k);

                ctxt_array::template map<pencrypt>(ct, p, q, r, m);
                check_result(tcase, vec_len, {ct});

                ptxt_array::template map<pdecrypt>(pt, ct, p, q, r, m);

                size_t nbytes = vec_len * ctxt::BYTES;
                const uint8_t *zptr = reinterpret_cast<const uint8_t *>(zeros->get_ptr());
                const uint8_t *ptptr = reinterpret_cast<const uint8_t *>(pt->get_ptr());
                EXPECT_TRUE(arrays_are_equal(zptr, nbytes, ptptr, nbytes));

                delete m;
            }
            delete r;
        }
        delete q;
    }

    delete p;
    delete ct;
    delete zeros;
}

int main(int argc, char *argv[])
{
    int r;

    testing::InitGoogleTest(&argc, argv);
    r = RUN_ALL_TESTS();
    return r;
}
