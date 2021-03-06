#pragma once

#include "slot_layout.cu"
#include "word_fixnum.cu"

/*
 * This is an archetypal implementation of a fixnum instruction
 * set. It defines the de facto interface for such implementations.
 *
 * All methods are defined for the device. It is someone else's
 * problem to get the data onto the device.
 */
template< int BYTES_, typename digit_ = u32_fixnum >
class warp_fixnum {
public:
    // NB: Language convention: Call something a 'digit' when it is constant
    // across the slot, and call it a 'fixnum' when it can vary between lanes in
    // the slot. Similarly, prefix a function call with 'digit::' when the
    // arguments are interpreted component-wise, and with 'fixnum::' when
    // they're interpreted "across the slot".
    typedef digit_ digit;
    typedef warp_fixnum fixnum;

    static constexpr int BYTES = BYTES_;
    static constexpr int BITS = 8 * BYTES;
    static constexpr int SLOT_WIDTH = BYTES / digit::BYTES;
    typedef slot_layout<digit, SLOT_WIDTH> layout;

    static_assert(BYTES > 0,
                  "Fixnum bytes must be positive.");
    static_assert(BYTES % digit::BYTES == 0,
                  "Fixnum digit size must divide fixnum bytes.");
    // TODO: Specialise std::is_integral for fixnum_u32?
    //static_assert(std::is_integral< digit >::value,
    //        "digit must be integral.");

private:
    digit x;

    // TODO: These should be private
public:
    __device__ __forceinline__
    operator digit () const { return x; }

    __device__ __forceinline__
    operator digit &() { return x; }

public:
    __device__ __forceinline__
    warp_fixnum() { }

    __device__ __forceinline__
    warp_fixnum(digit z) : x(z) { }

    /***************************
     * Representation functions.
     */

    /*
     * Set r using bytes, interpreting bytes as a base-256 unsigned
     * integer. Return the number of bytes used. If nbytes >
     * BYTES, then the last nbytes - BYTES are ignored.
     *
     * NB: Normally we would expect from_bytes to be exclusively a
     * device function, but it's the same for the host, so we leave it
     * in.
     */
    __host__ __device__ static int from_bytes(uint8_t *r, const uint8_t *bytes, int nbytes) {
        int n = min(nbytes, BYTES);
        memcpy(r, bytes, n);
        memset(r + n, 0, BYTES - n);
        return n;
    }

    /*
     * Set bytes using r, converting r to a base-256 unsigned
     * integer. Return the number of bytes written. If nbytes <
     * BYTES, then the last BYTES - nbytes are ignored.
     *
     * NB: Normally we would expect from_bytes to be exclusively a
     * device function, but it's the same for the host, so we leave it
     * in.
     */
    __host__ __device__ static int to_bytes(uint8_t *bytes, int nbytes, const uint8_t *r) {
        int n = min(nbytes, BYTES);
        memcpy(bytes, r, n);
        return n;
    }

    /*
     * Return digit at index idx.
     */
    __device__ static digit get(fixnum var, int idx) {
        return layout::shfl(var, idx);
    }

    /*
     * Set var digit at index idx to be x.
     */
    __device__ static void set(fixnum &var, digit x, int idx) {
        var = (layout::laneIdx() == idx) ? (fixnum)x : var;
    }

    /*
     * Return digit in most significant place. Might be zero.
     */
    __device__ static digit top_digit(fixnum var) {
        return layout::shfl(var, layout::toplaneIdx);
    }

    /*
     * Return digit in the least significant place. Might be zero.
     *
     * TODO: Not clear how to interpret this function with more exotic fixnum
     * implementations such as RNS.
     */
    __device__ static digit bottom_digit(fixnum var) {
        return layout::shfl(var, 0);
    }

    /***********************
     * Arithmetic functions.
     */

    // TODO: Handle carry in
    // TODO: A more consistent syntax might be
    // fixnum add(fixnum a, fixnum b)
    // fixnum add_cc(fixnum a, fixnum b, int &cy_out)
    // fixnum addc(fixnum a, fixnum b, int cy_in)
    // fixnum addc_cc(fixnum a, fixnum b, int cy_in, int &cy_out)
    __device__ static void add_cy(fixnum &r, digit &cy_hi, fixnum a, fixnum b) {
        digit cy;
        digit::add_cy(r, cy, a, b);
        // r propagates carries iff r = FIXNUM_MAX
        digit r_cy = effective_carries(cy_hi, digit::is_max(r), cy);
        digit::add(r, r, r_cy);
    }

    __device__ static void add(fixnum &r, fixnum a, fixnum b) {
        digit cy;
        add_cy(r, cy, a, b);
    }

    // TODO: Handle borrow in
    __device__ static void sub_br(fixnum &r, digit &br_hi, fixnum a, fixnum b) {
        digit br;
        digit::sub_br(r, br, a, b);
        // r propagates borrows iff r = FIXNUM_MIN
        digit r_br = effective_carries(br_hi, digit::is_min(r), br);
        digit::sub(r, r, r_br);
    }

    __device__ static void sub(fixnum &r, fixnum a, fixnum b) {
        digit br;
        sub_br(r, br, a, b);
    }

    __device__ static fixnum zero() {
        return digit::zero();
    }

    __device__ static fixnum one() {
        return digit(layout::laneIdx() == 0);
    }

    __device__ static fixnum two() {
        return digit(layout::laneIdx() == 0 ? 2 : 0);
    }

    __device__ static int is_zero(fixnum a) {
        return digit::is_zero(a);
    }

    __device__ static digit incr_cy(fixnum &r) {
        digit cy;
        add_cy(r, cy, r, one());
        return cy;
    }

    __device__ static digit decr_br(fixnum &r) {
        digit br;
        sub_br(r, br, r, one());
        return br;
    }

    __device__ static void neg(fixnum &r, fixnum a) {
        sub(r, zero(), a);
    }

    /*
     * r += a * u where a is interpreted as a single word, and u a
     * full fixnum. a should be constant across the slot for the
     * result to make sense.
     */
    __device__ static fixnum mad_digit_cy(fixnum &r, digit a, fixnum u) {
        fixnum hi;
        digit cy, cy_hi;

        digit::umad(hi, r, a, u, r);
        cy_hi = top_digit(hi);
        hi = layout::shfl_up0(hi, 1);
        add_cy(r, cy, hi, r);

        return cy_hi + cy;
    }

    /*
     * r = a * u, where a is interpreted as a single word, and u a
     * full fixnum. a should be constant across the slot for the
     * result to make sense.
     *
     * TODO: Can this be refactored with mad_cy?
     * TODO: Come up with a better name for this function. It's
     * scalar multiplication in the vspace of polynomials...
     */
    __device__ static digit mul_digit(fixnum &r, digit a, fixnum u) {
        fixnum hi, lo;
        digit cy, cy_hi;

        digit::mul_wide(hi, lo, a, u);
        cy_hi = top_digit(hi);
        hi = layout::shfl_up0(hi, 1);
        add_cy(lo, cy, lo, hi);

        return cy_hi + cy;
    }

    /*
     * r = lo_half(a * b)
     *
     * The "lo_half" is the product modulo 2^(8*BYTES),
     * i.e. the same size as the inputs.
     */
    __device__ static void mul_lo(fixnum &r, fixnum a, fixnum b) {
        // TODO: This should be smaller, probably uint16_t (smallest
        // possible for addition).  Strangely, the naive translation to
        // the smaller size broke; to investigate.
        digit cy = digit::zero();

        r = zero();
        for (int i = layout::WIDTH - 1; i >= 0; --i) {
            digit aa = layout::shfl(a, i);

            // TODO: See if using umad.wide improves this.
            digit::mad_hi_cc(r, cy, aa, b, r);
            // TODO: Could use rotate here, which is slightly
            // cheaper than shfl_up0...
            r = layout::shfl_up0(r, 1);
            cy = layout::shfl_up0(cy, 1);
            digit::mad_lo_cc(r, cy, aa, b, r);
        }
        cy = layout::shfl_up0(cy, 1);
        add(r, r, cy);
    }

    __device__ static void sqr_lo(fixnum &r, fixnum a) {
        // TODO: Implement my smarter squaring algo.
        mul_lo(r, a, a);
    }

    /*
     * (s, r) = a * b
     *
     * r is the "lo half" (see mul_lo above) and s is the
     * corresponding "hi half".
     */
    __device__ static void mul_wide(fixnum &s, fixnum &r, fixnum a, fixnum b) {
        // TODO: See if we can get away with a smaller type for cy.
        digit cy = digit::zero();
        int L = layout::laneIdx();

        // TODO: Rewrite this using rotates instead of shuffles;
        // should be simpler and faster.
        r = fixnum::zero();
        s = fixnum::zero();
        for (int i = layout::WIDTH - 1; i >= 0; --i) {
            digit aa = layout::shfl(a, i);
            fixnum t;

            // TODO: Review this code: it seems to have more shuffles than
            // necessary, and besides, why does it not use digit_addmuli?
            digit::mad_hi_cc(r, cy, aa, b, r);

            t = layout::shfl(cy, layout::toplaneIdx);
            // TODO: Is there a way to avoid this add?  Definitely need to
            // propagate the carry at least one place, but maybe not more?
            // Previous (wrong) version: "s = (L == 0) ? s + t : s;"
            digit_to_fixnum(t);
            add(s, s, t);

            // shuffle up hi words
            s = layout::shfl_up(s, 1);
            // most sig word of lo words becomes least sig of hi words
            t = layout::shfl(r, layout::toplaneIdx);
            s = (L == 0) ? t : s;

            r = layout::shfl_up0(r, 1);
            cy = layout::shfl_up0(cy, 1);
            digit::mad_lo_cc(r, cy, aa, b, r);
        }
        // TODO: This carry propgation from r to s is a bit long-winded.
        // Can we simplify?
        // NB: cy_hi <= width.  TODO: Justify this explicitly.
        digit cy_hi = layout::shfl(cy, layout::toplaneIdx);
        cy = layout::shfl_up0(cy, 1);
        add_cy(r, cy, r, cy);
        digit::add(cy_hi, cy_hi, cy); // Can't overflow since cy_hi <= width.
        assert(digit::cmp(cy_hi, cy) >= 0);
        // TODO: Investigate: replacing the following two lines with
        // simply "s = (L == 0) ? s + cy_hi : s;" produces no detectible
        // errors. Can I prove that (MAX_UINT64 - s[0]) < width?
        digit_to_fixnum(cy_hi);
        add_cy(s, cy, s, cy_hi);
        assert(digit::is_zero(cy));
    }

    __device__ static void mul_hi(fixnum &s, fixnum a, fixnum b) {
        // TODO: implement this properly
        fixnum r;
        mul_wide(s, r, a, b);
    }

    __device__ static void sqr_wide(fixnum &s, fixnum &r, fixnum a) {
        // TODO: Implement my smarter squaring algo.
        mul_wide(s, r, a, a);
    }

    __device__ static void sqr_hi(fixnum &s, fixnum a) {
        // TODO: implement this properly
        fixnum r;
        sqr_wide(s, r, a);
    }

    /*
     * Return a mask of width bits whose ith bit is set if and only if
     * the ith digit of r is nonzero. In particular, result is zero
     * iff r is zero.
     */
    __device__ static uint32_t nonzero_mask(fixnum r) {
        return layout::ballot( ! is_zero(r));
    }

    /*
     * Return -1, 0, or 1, depending on whether x is less than, equal
     * to, or greater than y.
     */
    __device__ static int cmp(fixnum x, fixnum y) {
        fixnum r;
        digit br;
        sub_br(r, br, x, y);
        // r != 0 iff x != y. If x != y, then br != 0 => x < y.
        return nonzero_mask(r) ? (br ? -1 : 1) : 0;
    }

    /*
     * Return the index of the most significant digit of x, or -1 if x is
     * zero.
     */
    __device__ static int most_sig_dig(fixnum x) {
        // FIXME: Should be able to get this value from limits or numeric_limits
        // or whatever.
        enum { UINT32_BITS = 8 * sizeof(uint32_t) };
        static_assert(UINT32_BITS == 32, "uint32_t isn't 32 bits");

        uint32_t a = nonzero_mask(x);
        return UINT32_BITS - (internal::clz(a) + 1);
    }

    /*
     * Return the index of the most significant bit of x, or -1 if x is
     * zero.
     *
     * TODO: Give this function a better name; maybe floor_log2()?
     */
    __device__ static int msb(fixnum x) {
        int b = most_sig_dig(x);
        if (b < 0) return b;
        digit y = layout::shfl(x, b);
        // TODO: These two lines are basically the same as most_sig_dig();
        // refactor.
        int c = digit::clz(y);
        return digit::BITS - (c + 1) + digit::BITS * b;
    }

    /*
     * Return the 2-valuation of x, i.e. the integer k >= 0 such that
     * 2^k divides x but 2^(k+1) does not divide x.  Depending on the
     * representation, can think of this as CTZ(x) ("Count Trailing
     * Zeros").  The 2-valuation of zero is *ahem* fixnum::BITS.
     *
     * TODO: Refactor common code between here, msb() and
     * most_sig_dig(). Perhaps write msb in terms of two_valuation?
     *
     * FIXME: Pretty sure this function is broken; e.g. if x is 0 but width <
     * warpSize, the answer is wrong.
     */
    __device__ static int two_valuation(fixnum x) {
        uint32_t a = nonzero_mask(x);
        int b = internal::ctz(a), c = 0;
        if (b < SLOT_WIDTH) {
            digit y = layout::shfl(x, b);
            c = digit::ctz(y);
        } else
            b = SLOT_WIDTH;
        return c + b * digit::BITS;
    }

    /*
     * Set y to be x shifted by b bits to the left; effectively
     * multiply by 2^b. Return the top b bits of x in overflow.
     *
     * FIXME: Currently assumes that fixnum is unsigned.
     *
     * TODO: Think of better names for these functions. Something like
     * mul_2exp.
     *
     * TODO: Could improve performance significantly by using the funnel shift
     * instruction: https://docs.nvidia.com/cuda/parallel-thread-execution/#logic-and-shift-instructions-shf
     */
    __device__
    static void
    lshift(fixnum &y, fixnum &overflow, fixnum x, int b) {
        assert(b >= 0);
        assert(b <= BITS);
        int q = b / digit::BITS, r = b % digit::BITS;

        y = layout::rotate_up(x, q);
        // Hi bits of y[i] (=overflow) become the lo bits of y[(i+1) % width]
        digit::lshift(y, overflow, y, r);
        overflow = layout::rotate_up(overflow, 1);
        // TODO: This was "y |= overflow"; any advantage to using logor?
        digit::add(y, y, overflow);

        fixnum t;
        int L = layout::laneIdx();
        digit::set_if(overflow, y, L <= q);  // Kill high (q-1) words of y;
        digit::rem_2exp(t, overflow, r);     // Kill high BITS - r bits of overflow[q]
        set(overflow, t, q);
        digit::set_if(y, y, L >= q);         // Kill low q words of y;
        digit::rshift(t, y, r);              // Kill low r bits of y[q]
        digit::lshift(t, t, r);
        set(y, t, q);
    }

    /*
     * TODO: Adapt lshift above to not bother calculating overflow.
     */
    __device__
    static void
    lshift(fixnum &y, fixnum x, int b) {
        fixnum overflow;
        lshift(y, overflow, x, b);
    }

    /*
     * Set y to be x shifted by b bits to the right; effectively
     * divide by 2^b. Return the bottom b bits of x.
     *
     * TODO: Think of better names for these functions. Something like
     * mul_2exp.
     */
    __device__
    static void
    rshift(fixnum &y, fixnum &underflow, fixnum x, int b) {
        lshift(underflow, y, x, BITS - b);
    }

    __device__
    static void
    rshift(fixnum &y, fixnum x, int b) {
        fixnum underflow;
        rshift(y, underflow, x, b);
    }

private:
    __device__
    static void
    digit_to_fixnum(digit &c) {
        int L = layout::laneIdx();
        // TODO: Try without branching?  c &= -(digit)(L == 0);
        c = (L == 0) ? c : digit::zero();
    }

    __device__
    static digit
    effective_carries(digit &cy_hi, int propagate, int cy) {
        int L = layout::laneIdx();
        uint32_t allcarries, p, g;

        g = layout::ballot(cy);              // carry generate
        p = layout::ballot(propagate);       // carry propagate
        allcarries = (p | g) + g;                 // propagate all carries
        // NB: There is no way to unify these two expressions to remove the
        // conditional. The conditional should be optimised away though, since
        // WIDTH is a compile-time constant.
        cy_hi = (layout::WIDTH == WARPSIZE) // detect hi overflow
            ? (allcarries < g)
            : ((allcarries >> layout::WIDTH) & 1);
        allcarries = (allcarries ^ p) | (g << 1); // get effective carries
        return (allcarries >> L) & 1;
    }
};
