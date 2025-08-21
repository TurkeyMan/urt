module urt.range.primitives;

import urt.traits;


enum bool is_input_range(R) =
    is(typeof(R.init) == R)
    && is(typeof((R r) { return r.empty; } (R.init)) == bool)
    && (is(typeof((return ref R r) => r.front)) || is(typeof(ref (return ref R r) => r.front)))
    && !is(typeof((R r) { return r.front; } (R.init)) == void)
    && is(typeof((R r) => r.popFront));
enum bool is_input_range(R, E) =
    .is_input_range!R && isQualifierConvertible!(ElementType!R, E);

enum bool is_forward_range(R) = is_input_range!R
    && is(typeof((R r) { return r.save; } (R.init)) == R);
enum bool is_forward_range(R, E) =
    .is_forward_range!R && isQualifierConvertible!(ElementType!R, E);

enum bool is_bidirectional_range(R) = is_forward_range!R
    && is(typeof((R r) => r.popBack))
    && (is(typeof((return ref R r) => r.back)) || is(typeof(ref (return ref R r) => r.back)))
    && is(typeof(R.init.back.init) == ElementType!R);
enum bool is_bidirectional_range(R, E) =
    .is_bidirectional_range!R && isQualifierConvertible!(ElementType!R, E);

enum bool is_random_access_range(R) =
    is(typeof(lvalue_of!R[1]) == ElementType!R)
    && !(isAutodecodableString!R && !isAggregateType!R)
    && is_forward_range!R
    && (is_bidirectional_range!R || isInfinite!R)
    && (hasLength!R || isInfinite!R)
    && (isInfinite!R || !is(typeof(lvalue_of!R[$ - 1]))
        || is(typeof(lvalue_of!R[$ - 1]) == ElementType!R));
enum bool is_random_access_range(R, E) =
    .is_random_access_range!R && isQualifierConvertible!(ElementType!R, E);


// is this in the wrong place? should this be a general traits for arrays and stuff too?
template ElementType(R)
{
    static if (is(typeof(lvalue_of!R.front)))
        alias ElementType = typeof(lvalue_of!R.front);
    else static if (is(R : T[], T))
        alias ElementType = T;
    else
        ElementType = void;
}
