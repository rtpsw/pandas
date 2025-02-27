import cython
from cython import Py_ssize_t

from cython cimport floating
from libc.stdlib cimport (
    free,
    malloc,
)

import numpy as np

cimport numpy as cnp
from numpy cimport (
    complex64_t,
    complex128_t,
    float32_t,
    float64_t,
    int8_t,
    int16_t,
    int32_t,
    int64_t,
    intp_t,
    ndarray,
    uint8_t,
    uint16_t,
    uint32_t,
    uint64_t,
)
from numpy.math cimport NAN

cnp.import_array()

from pandas._libs.algos cimport kth_smallest_c
from pandas._libs.util cimport get_nat

from pandas._libs.algos import (
    ensure_platform_int,
    groupsort_indexer,
    rank_1d,
    take_2d_axis1_float64_float64,
)

from pandas._libs.dtypes cimport (
    iu_64_floating_obj_t,
    iu_64_floating_t,
    numeric_t,
)
from pandas._libs.missing cimport checknull


cdef int64_t NPY_NAT = get_nat()
_int64_max = np.iinfo(np.int64).max

cdef float64_t NaN = <float64_t>np.NaN

cdef enum InterpolationEnumType:
    INTERPOLATION_LINEAR,
    INTERPOLATION_LOWER,
    INTERPOLATION_HIGHER,
    INTERPOLATION_NEAREST,
    INTERPOLATION_MIDPOINT


cdef inline float64_t median_linear(float64_t* a, int n) nogil:
    cdef:
        int i, j, na_count = 0
        float64_t result
        float64_t* tmp

    if n == 0:
        return NaN

    # count NAs
    for i in range(n):
        if a[i] != a[i]:
            na_count += 1

    if na_count:
        if na_count == n:
            return NaN

        tmp = <float64_t*>malloc((n - na_count) * sizeof(float64_t))

        j = 0
        for i in range(n):
            if a[i] == a[i]:
                tmp[j] = a[i]
                j += 1

        a = tmp
        n -= na_count

    if n % 2:
        result = kth_smallest_c(a, n // 2, n)
    else:
        result = (kth_smallest_c(a, n // 2, n) +
                  kth_smallest_c(a, n // 2 - 1, n)) / 2

    if na_count:
        free(a)

    return result


@cython.boundscheck(False)
@cython.wraparound(False)
def group_median_float64(
    ndarray[float64_t, ndim=2] out,
    ndarray[int64_t] counts,
    ndarray[float64_t, ndim=2] values,
    ndarray[intp_t] labels,
    Py_ssize_t min_count=-1,
) -> None:
    """
    Only aggregates on axis=0
    """
    cdef:
        Py_ssize_t i, j, N, K, ngroups, size
        ndarray[intp_t] _counts
        ndarray[float64_t, ndim=2] data
        ndarray[intp_t] indexer
        float64_t* ptr

    assert min_count == -1, "'min_count' only used in add and prod"

    ngroups = len(counts)
    N, K = (<object>values).shape

    indexer, _counts = groupsort_indexer(labels, ngroups)
    counts[:] = _counts[1:]

    data = np.empty((K, N), dtype=np.float64)
    ptr = <float64_t*>cnp.PyArray_DATA(data)

    take_2d_axis1_float64_float64(values.T, indexer, out=data)

    with nogil:

        for i in range(K):
            # exclude NA group
            ptr += _counts[0]
            for j in range(ngroups):
                size = _counts[j + 1]
                out[j, i] = median_linear(ptr, size)
                ptr += size


@cython.boundscheck(False)
@cython.wraparound(False)
def group_cumprod_float64(
    float64_t[:, ::1] out,
    const float64_t[:, :] values,
    const intp_t[::1] labels,
    int ngroups,
    bint is_datetimelike,
    bint skipna=True,
) -> None:
    """
    Cumulative product of columns of `values`, in row groups `labels`.

    Parameters
    ----------
    out : np.ndarray[np.float64, ndim=2]
        Array to store cumprod in.
    values : np.ndarray[np.float64, ndim=2]
        Values to take cumprod of.
    labels : np.ndarray[np.intp]
        Labels to group by.
    ngroups : int
        Number of groups, larger than all entries of `labels`.
    is_datetimelike : bool
        Always false, `values` is never datetime-like.
    skipna : bool
        If true, ignore nans in `values`.

    Notes
    -----
    This method modifies the `out` parameter, rather than returning an object.
    """
    cdef:
        Py_ssize_t i, j, N, K, size
        float64_t val
        float64_t[:, ::1] accum
        intp_t lab

    N, K = (<object>values).shape
    accum = np.ones((ngroups, K), dtype=np.float64)

    with nogil:
        for i in range(N):
            lab = labels[i]

            if lab < 0:
                continue
            for j in range(K):
                val = values[i, j]
                if val == val:
                    accum[lab, j] *= val
                    out[i, j] = accum[lab, j]
                else:
                    out[i, j] = NaN
                    if not skipna:
                        accum[lab, j] = NaN
                        break


@cython.boundscheck(False)
@cython.wraparound(False)
def group_cumsum(
    numeric_t[:, ::1] out,
    ndarray[numeric_t, ndim=2] values,
    const intp_t[::1] labels,
    int ngroups,
    is_datetimelike,
    bint skipna=True,
) -> None:
    """
    Cumulative sum of columns of `values`, in row groups `labels`.

    Parameters
    ----------
    out : np.ndarray[ndim=2]
        Array to store cumsum in.
    values : np.ndarray[ndim=2]
        Values to take cumsum of.
    labels : np.ndarray[np.intp]
        Labels to group by.
    ngroups : int
        Number of groups, larger than all entries of `labels`.
    is_datetimelike : bool
        True if `values` contains datetime-like entries.
    skipna : bool
        If true, ignore nans in `values`.

    Notes
    -----
    This method modifies the `out` parameter, rather than returning an object.
    """
    cdef:
        Py_ssize_t i, j, N, K, size
        numeric_t val, y, t
        numeric_t[:, ::1] accum, compensation
        intp_t lab

    N, K = (<object>values).shape
    accum = np.zeros((ngroups, K), dtype=np.asarray(values).dtype)
    compensation = np.zeros((ngroups, K), dtype=np.asarray(values).dtype)

    with nogil:
        for i in range(N):
            lab = labels[i]

            if lab < 0:
                continue
            for j in range(K):
                val = values[i, j]

                # For floats, use Kahan summation to reduce floating-point
                # error (https://en.wikipedia.org/wiki/Kahan_summation_algorithm)
                if numeric_t == float32_t or numeric_t == float64_t:
                    if val == val:
                        y = val - compensation[lab, j]
                        t = accum[lab, j] + y
                        compensation[lab, j] = t - accum[lab, j] - y
                        accum[lab, j] = t
                        out[i, j] = t
                    else:
                        out[i, j] = NaN
                        if not skipna:
                            accum[lab, j] = NaN
                            break
                else:
                    t = val + accum[lab, j]
                    accum[lab, j] = t
                    out[i, j] = t


@cython.boundscheck(False)
@cython.wraparound(False)
def group_shift_indexer(
    int64_t[::1] out,
    const intp_t[::1] labels,
    int ngroups,
    int periods,
) -> None:
    cdef:
        Py_ssize_t N, i, j, ii, lab
        int offset = 0, sign
        int64_t idxer, idxer_slot
        int64_t[::1] label_seen = np.zeros(ngroups, dtype=np.int64)
        int64_t[:, ::1] label_indexer

    N, = (<object>labels).shape

    if periods < 0:
        periods = -periods
        offset = N - 1
        sign = -1
    elif periods > 0:
        offset = 0
        sign = 1

    if periods == 0:
        with nogil:
            for i in range(N):
                out[i] = i
    else:
        # array of each previous indexer seen
        label_indexer = np.zeros((ngroups, periods), dtype=np.int64)
        with nogil:
            for i in range(N):
                # reverse iterator if shifting backwards
                ii = offset + sign * i
                lab = labels[ii]

                # Skip null keys
                if lab == -1:
                    out[ii] = -1
                    continue

                label_seen[lab] += 1

                idxer_slot = label_seen[lab] % periods
                idxer = label_indexer[lab, idxer_slot]

                if label_seen[lab] > periods:
                    out[ii] = idxer
                else:
                    out[ii] = -1

                label_indexer[lab, idxer_slot] = ii


@cython.wraparound(False)
@cython.boundscheck(False)
def group_fillna_indexer(
    ndarray[intp_t] out,
    ndarray[intp_t] labels,
    ndarray[intp_t] sorted_labels,
    ndarray[uint8_t] mask,
    str direction,
    int64_t limit,
    bint dropna,
) -> None:
    """
    Indexes how to fill values forwards or backwards within a group.

    Parameters
    ----------
    out : np.ndarray[np.intp]
        Values into which this method will write its results.
    labels : np.ndarray[np.intp]
        Array containing unique label for each group, with its ordering
        matching up to the corresponding record in `values`.
    sorted_labels : np.ndarray[np.intp]
        obtained by `np.argsort(labels, kind="mergesort")`; reversed if
        direction == "bfill"
    values : np.ndarray[np.uint8]
        Containing the truth value of each element.
    mask : np.ndarray[np.uint8]
        Indicating whether a value is na or not.
    direction : {'ffill', 'bfill'}
        Direction for fill to be applied (forwards or backwards, respectively)
    limit : Consecutive values to fill before stopping, or -1 for no limit
    dropna : Flag to indicate if NaN groups should return all NaN values

    Notes
    -----
    This method modifies the `out` parameter rather than returning an object
    """
    cdef:
        Py_ssize_t i, N, idx
        intp_t curr_fill_idx=-1
        int64_t filled_vals = 0

    N = len(out)

    # Make sure all arrays are the same size
    assert N == len(labels) == len(mask)

    with nogil:
        for i in range(N):
            idx = sorted_labels[i]
            if dropna and labels[idx] == -1:  # nan-group gets nan-values
                curr_fill_idx = -1
            elif mask[idx] == 1:  # is missing
                # Stop filling once we've hit the limit
                if filled_vals >= limit and limit != -1:
                    curr_fill_idx = -1
                filled_vals += 1
            else:  # reset items when not missing
                filled_vals = 0
                curr_fill_idx = idx

            out[idx] = curr_fill_idx

            # If we move to the next group, reset
            # the fill_idx and counter
            if i == N - 1 or labels[idx] != labels[sorted_labels[i + 1]]:
                curr_fill_idx = -1
                filled_vals = 0


@cython.boundscheck(False)
@cython.wraparound(False)
def group_any_all(
    int8_t[:, ::1] out,
    const int8_t[:, :] values,
    const intp_t[::1] labels,
    const uint8_t[:, :] mask,
    str val_test,
    bint skipna,
    bint nullable,
) -> None:
    """
    Aggregated boolean values to show truthfulness of group elements. If the
    input is a nullable type (nullable=True), the result will be computed
    using Kleene logic.

    Parameters
    ----------
    out : np.ndarray[np.int8]
        Values into which this method will write its results.
    labels : np.ndarray[np.intp]
        Array containing unique label for each group, with its
        ordering matching up to the corresponding record in `values`
    values : np.ndarray[np.int8]
        Containing the truth value of each element.
    mask : np.ndarray[np.uint8]
        Indicating whether a value is na or not.
    val_test : {'any', 'all'}
        String object dictating whether to use any or all truth testing
    skipna : bool
        Flag to ignore nan values during truth testing
    nullable : bool
        Whether or not the input is a nullable type. If True, the
        result will be computed using Kleene logic

    Notes
    -----
    This method modifies the `out` parameter rather than returning an object.
    The returned values will either be 0, 1 (False or True, respectively), or
    -1 to signify a masked position in the case of a nullable input.
    """
    cdef:
        Py_ssize_t i, j, N = len(labels), K = out.shape[1]
        intp_t lab
        int8_t flag_val, val

    if val_test == 'all':
        # Because the 'all' value of an empty iterable in Python is True we can
        # start with an array full of ones and set to zero when a False value
        # is encountered
        flag_val = 0
    elif val_test == 'any':
        # Because the 'any' value of an empty iterable in Python is False we
        # can start with an array full of zeros and set to one only if any
        # value encountered is True
        flag_val = 1
    else:
        raise ValueError("'bool_func' must be either 'any' or 'all'!")

    out[:] = 1 - flag_val

    with nogil:
        for i in range(N):
            lab = labels[i]
            if lab < 0:
                continue

            for j in range(K):
                if skipna and mask[i, j]:
                    continue

                if nullable and mask[i, j]:
                    # Set the position as masked if `out[lab] != flag_val`, which
                    # would indicate True/False has not yet been seen for any/all,
                    # so by Kleene logic the result is currently unknown
                    if out[lab, j] != flag_val:
                        out[lab, j] = -1
                    continue

                val = values[i, j]

                # If True and 'any' or False and 'all', the result is
                # already determined
                if val == flag_val:
                    out[lab, j] = flag_val


# ----------------------------------------------------------------------
# group_add, group_prod, group_var, group_mean, group_ohlc
# ----------------------------------------------------------------------

ctypedef fused mean_t:
    float64_t
    float32_t
    complex64_t
    complex128_t

ctypedef fused add_t:
    mean_t
    object


@cython.wraparound(False)
@cython.boundscheck(False)
def group_add(
    add_t[:, ::1] out,
    int64_t[::1] counts,
    ndarray[add_t, ndim=2] values,
    const intp_t[::1] labels,
    Py_ssize_t min_count=0,
    bint is_datetimelike=False,
) -> None:
    """
    Only aggregates on axis=0 using Kahan summation
    """
    cdef:
        Py_ssize_t i, j, N, K, lab, ncounts = len(counts)
        add_t val, t, y
        add_t[:, ::1] sumx, compensation
        int64_t[:, ::1] nobs
        Py_ssize_t len_values = len(values), len_labels = len(labels)

    if len_values != len_labels:
        raise ValueError("len(index) != len(labels)")

    nobs = np.zeros((<object>out).shape, dtype=np.int64)
    # the below is equivalent to `np.zeros_like(out)` but faster
    sumx = np.zeros((<object>out).shape, dtype=(<object>out).base.dtype)
    compensation = np.zeros((<object>out).shape, dtype=(<object>out).base.dtype)

    N, K = (<object>values).shape

    if add_t is object:
        # NB: this does not use 'compensation' like the non-object track does.
        for i in range(N):
            lab = labels[i]
            if lab < 0:
                continue

            counts[lab] += 1
            for j in range(K):
                val = values[i, j]

                # not nan
                if not checknull(val):
                    nobs[lab, j] += 1

                    if nobs[lab, j] == 1:
                        # i.e. we haven't added anything yet; avoid TypeError
                        #  if e.g. val is a str and sumx[lab, j] is 0
                        t = val
                    else:
                        t = sumx[lab, j] + val
                    sumx[lab, j] = t

        for i in range(ncounts):
            for j in range(K):
                if nobs[i, j] < min_count:
                    out[i, j] = NAN
                else:
                    out[i, j] = sumx[i, j]
    else:
        with nogil:
            for i in range(N):
                lab = labels[i]
                if lab < 0:
                    continue

                counts[lab] += 1
                for j in range(K):
                    val = values[i, j]

                    # not nan
                    # With dt64/td64 values, values have been cast to float64
                    #  instead if int64 for group_add, but the logic
                    #  is otherwise the same as in _treat_as_na
                    if val == val and not (
                        add_t is float64_t
                        and is_datetimelike
                        and val == <float64_t>NPY_NAT
                    ):
                        nobs[lab, j] += 1
                        y = val - compensation[lab, j]
                        t = sumx[lab, j] + y
                        compensation[lab, j] = t - sumx[lab, j] - y
                        sumx[lab, j] = t

            for i in range(ncounts):
                for j in range(K):
                    if nobs[i, j] < min_count:
                        out[i, j] = NAN
                    else:
                        out[i, j] = sumx[i, j]


@cython.wraparound(False)
@cython.boundscheck(False)
def group_prod(
    floating[:, ::1] out,
    int64_t[::1] counts,
    ndarray[floating, ndim=2] values,
    const intp_t[::1] labels,
    Py_ssize_t min_count=0,
) -> None:
    """
    Only aggregates on axis=0
    """
    cdef:
        Py_ssize_t i, j, N, K, lab, ncounts = len(counts)
        floating val, count
        floating[:, ::1] prodx
        int64_t[:, ::1] nobs
        Py_ssize_t len_values = len(values), len_labels = len(labels)

    if len_values != len_labels:
        raise ValueError("len(index) != len(labels)")

    nobs = np.zeros((<object>out).shape, dtype=np.int64)
    prodx = np.ones((<object>out).shape, dtype=(<object>out).base.dtype)

    N, K = (<object>values).shape

    with nogil:
        for i in range(N):
            lab = labels[i]
            if lab < 0:
                continue

            counts[lab] += 1
            for j in range(K):
                val = values[i, j]

                # not nan
                if val == val:
                    nobs[lab, j] += 1
                    prodx[lab, j] *= val

        for i in range(ncounts):
            for j in range(K):
                if nobs[i, j] < min_count:
                    out[i, j] = NAN
                else:
                    out[i, j] = prodx[i, j]


@cython.wraparound(False)
@cython.boundscheck(False)
@cython.cdivision(True)
def group_var(
    floating[:, ::1] out,
    int64_t[::1] counts,
    ndarray[floating, ndim=2] values,
    const intp_t[::1] labels,
    Py_ssize_t min_count=-1,
    int64_t ddof=1,
) -> None:
    cdef:
        Py_ssize_t i, j, N, K, lab, ncounts = len(counts)
        floating val, ct, oldmean
        floating[:, ::1] mean
        int64_t[:, ::1] nobs
        Py_ssize_t len_values = len(values), len_labels = len(labels)

    assert min_count == -1, "'min_count' only used in add and prod"

    if len_values != len_labels:
        raise ValueError("len(index) != len(labels)")

    nobs = np.zeros((<object>out).shape, dtype=np.int64)
    mean = np.zeros((<object>out).shape, dtype=(<object>out).base.dtype)

    N, K = (<object>values).shape

    out[:, :] = 0.0

    with nogil:
        for i in range(N):
            lab = labels[i]
            if lab < 0:
                continue

            counts[lab] += 1

            for j in range(K):
                val = values[i, j]

                # not nan
                if val == val:
                    nobs[lab, j] += 1
                    oldmean = mean[lab, j]
                    mean[lab, j] += (val - oldmean) / nobs[lab, j]
                    out[lab, j] += (val - mean[lab, j]) * (val - oldmean)

        for i in range(ncounts):
            for j in range(K):
                ct = nobs[i, j]
                if ct <= ddof:
                    out[i, j] = NAN
                else:
                    out[i, j] /= (ct - ddof)


@cython.wraparound(False)
@cython.boundscheck(False)
def group_mean(
    mean_t[:, ::1] out,
    int64_t[::1] counts,
    ndarray[mean_t, ndim=2] values,
    const intp_t[::1] labels,
    Py_ssize_t min_count=-1,
    bint is_datetimelike=False,
    const uint8_t[:, ::1] mask=None,
    uint8_t[:, ::1] result_mask=None,
) -> None:
    """
    Compute the mean per label given a label assignment for each value.
    NaN values are ignored.

    Parameters
    ----------
    out : np.ndarray[floating]
        Values into which this method will write its results.
    counts : np.ndarray[int64]
        A zeroed array of the same shape as labels,
        populated by group sizes during algorithm.
    values : np.ndarray[floating]
        2-d array of the values to find the mean of.
    labels : np.ndarray[np.intp]
        Array containing unique label for each group, with its
        ordering matching up to the corresponding record in `values`.
    min_count : Py_ssize_t
        Only used in add and prod. Always -1.
    is_datetimelike : bool
        True if `values` contains datetime-like entries.
    mask : ndarray[bool, ndim=2], optional
        Not used.
    result_mask : ndarray[bool, ndim=2], optional
        Not used.

    Notes
    -----
    This method modifies the `out` parameter rather than returning an object.
    `counts` is modified to hold group sizes
    """

    cdef:
        Py_ssize_t i, j, N, K, lab, ncounts = len(counts)
        mean_t val, count, y, t, nan_val
        mean_t[:, ::1] sumx, compensation
        int64_t[:, ::1] nobs
        Py_ssize_t len_values = len(values), len_labels = len(labels)

    assert min_count == -1, "'min_count' only used in add and prod"

    if len_values != len_labels:
        raise ValueError("len(index) != len(labels)")

    # the below is equivalent to `np.zeros_like(out)` but faster
    nobs = np.zeros((<object>out).shape, dtype=np.int64)
    sumx = np.zeros((<object>out).shape, dtype=(<object>out).base.dtype)
    compensation = np.zeros((<object>out).shape, dtype=(<object>out).base.dtype)

    N, K = (<object>values).shape
    nan_val = NPY_NAT if is_datetimelike else NAN

    with nogil:
        for i in range(N):
            lab = labels[i]
            if lab < 0:
                continue

            counts[lab] += 1
            for j in range(K):
                val = values[i, j]
                # not nan
                if val == val and not (is_datetimelike and val == NPY_NAT):
                    nobs[lab, j] += 1
                    y = val - compensation[lab, j]
                    t = sumx[lab, j] + y
                    compensation[lab, j] = t - sumx[lab, j] - y
                    sumx[lab, j] = t

        for i in range(ncounts):
            for j in range(K):
                count = nobs[i, j]
                if nobs[i, j] == 0:
                    out[i, j] = nan_val
                else:
                    out[i, j] = sumx[i, j] / count


@cython.wraparound(False)
@cython.boundscheck(False)
def group_ohlc(
    floating[:, ::1] out,
    int64_t[::1] counts,
    ndarray[floating, ndim=2] values,
    const intp_t[::1] labels,
    Py_ssize_t min_count=-1,
) -> None:
    """
    Only aggregates on axis=0
    """
    cdef:
        Py_ssize_t i, j, N, K, lab
        floating val

    assert min_count == -1, "'min_count' only used in add and prod"

    if len(labels) == 0:
        return

    N, K = (<object>values).shape

    if out.shape[1] != 4:
        raise ValueError('Output array must have 4 columns')

    if K > 1:
        raise NotImplementedError("Argument 'values' must have only one dimension")
    out[:] = np.nan

    with nogil:
        for i in range(N):
            lab = labels[i]
            if lab == -1:
                continue

            counts[lab] += 1
            val = values[i, 0]
            if val != val:
                continue

            if out[lab, 0] != out[lab, 0]:
                out[lab, 0] = out[lab, 1] = out[lab, 2] = out[lab, 3] = val
            else:
                out[lab, 1] = max(out[lab, 1], val)
                out[lab, 2] = min(out[lab, 2], val)
                out[lab, 3] = val


@cython.boundscheck(False)
@cython.wraparound(False)
def group_quantile(
    ndarray[float64_t, ndim=2] out,
    ndarray[numeric_t, ndim=1] values,
    ndarray[intp_t] labels,
    ndarray[uint8_t] mask,
    const intp_t[:] sort_indexer,
    const float64_t[:] qs,
    str interpolation,
) -> None:
    """
    Calculate the quantile per group.

    Parameters
    ----------
    out : np.ndarray[np.float64, ndim=2]
        Array of aggregated values that will be written to.
    values : np.ndarray
        Array containing the values to apply the function against.
    labels : ndarray[np.intp]
        Array containing the unique group labels.
    sort_indexer : ndarray[np.intp]
        Indices describing sort order by values and labels.
    qs : ndarray[float64_t]
        The quantile values to search for.
    interpolation : {'linear', 'lower', 'highest', 'nearest', 'midpoint'}

    Notes
    -----
    Rather than explicitly returning a value, this function modifies the
    provided `out` parameter.
    """
    cdef:
        Py_ssize_t i, N=len(labels), ngroups, grp_sz, non_na_sz, k, nqs
        Py_ssize_t grp_start=0, idx=0
        intp_t lab
        InterpolationEnumType interp
        float64_t q_val, q_idx, frac, val, next_val
        int64_t[::1] counts, non_na_counts

    assert values.shape[0] == N

    if any(not (0 <= q <= 1) for q in qs):
        wrong = [x for x in qs if not (0 <= x <= 1)][0]
        raise ValueError(
            f"Each 'q' must be between 0 and 1. Got '{wrong}' instead"
        )

    inter_methods = {
        'linear': INTERPOLATION_LINEAR,
        'lower': INTERPOLATION_LOWER,
        'higher': INTERPOLATION_HIGHER,
        'nearest': INTERPOLATION_NEAREST,
        'midpoint': INTERPOLATION_MIDPOINT,
    }
    interp = inter_methods[interpolation]

    nqs = len(qs)
    ngroups = len(out)
    counts = np.zeros(ngroups, dtype=np.int64)
    non_na_counts = np.zeros(ngroups, dtype=np.int64)

    # First figure out the size of every group
    with nogil:
        for i in range(N):
            lab = labels[i]
            if lab == -1:  # NA group label
                continue

            counts[lab] += 1
            if not mask[i]:
                non_na_counts[lab] += 1

    with nogil:
        for i in range(ngroups):
            # Figure out how many group elements there are
            grp_sz = counts[i]
            non_na_sz = non_na_counts[i]

            if non_na_sz == 0:
                for k in range(nqs):
                    out[i, k] = NaN
            else:
                for k in range(nqs):
                    q_val = qs[k]

                    # Calculate where to retrieve the desired value
                    # Casting to int will intentionally truncate result
                    idx = grp_start + <int64_t>(q_val * <float64_t>(non_na_sz - 1))

                    val = values[sort_indexer[idx]]
                    # If requested quantile falls evenly on a particular index
                    # then write that index's value out. Otherwise interpolate
                    q_idx = q_val * (non_na_sz - 1)
                    frac = q_idx % 1

                    if frac == 0.0 or interp == INTERPOLATION_LOWER:
                        out[i, k] = val
                    else:
                        next_val = values[sort_indexer[idx + 1]]
                        if interp == INTERPOLATION_LINEAR:
                            out[i, k] = val + (next_val - val) * frac
                        elif interp == INTERPOLATION_HIGHER:
                            out[i, k] = next_val
                        elif interp == INTERPOLATION_MIDPOINT:
                            out[i, k] = (val + next_val) / 2.0
                        elif interp == INTERPOLATION_NEAREST:
                            if frac > .5 or (frac == .5 and q_val > .5):  # Always OK?
                                out[i, k] = next_val
                            else:
                                out[i, k] = val

            # Increment the index reference in sorted_arr for the next group
            grp_start += grp_sz


# ----------------------------------------------------------------------
# group_nth, group_last, group_rank
# ----------------------------------------------------------------------

cdef inline bint _treat_as_na(iu_64_floating_obj_t val, bint is_datetimelike) nogil:
    if iu_64_floating_obj_t is object:
        # Should never be used, but we need to avoid the `val != val` below
        #  or else cython will raise about gil acquisition.
        raise NotImplementedError

    elif iu_64_floating_obj_t is int64_t:
        return is_datetimelike and val == NPY_NAT
    elif iu_64_floating_obj_t is uint64_t:
        # There is no NA value for uint64
        return False
    else:
        return val != val


# TODO(cython3): GH#31710 use memorviews once cython 0.30 is released so we can
#  use `const iu_64_floating_obj_t[:, :] values`
@cython.wraparound(False)
@cython.boundscheck(False)
def group_last(
    iu_64_floating_obj_t[:, ::1] out,
    int64_t[::1] counts,
    ndarray[iu_64_floating_obj_t, ndim=2] values,
    const intp_t[::1] labels,
    const uint8_t[:, :] mask,
    uint8_t[:, ::1] result_mask=None,
    Py_ssize_t min_count=-1,
) -> None:
    """
    Only aggregates on axis=0
    """
    cdef:
        Py_ssize_t i, j, N, K, lab, ncounts = len(counts)
        iu_64_floating_obj_t val
        ndarray[iu_64_floating_obj_t, ndim=2] resx
        ndarray[int64_t, ndim=2] nobs
        bint runtime_error = False
        bint uses_mask = mask is not None
        bint isna_entry

    # TODO(cython3):
    # Instead of `labels.shape[0]` use `len(labels)`
    if not len(values) == labels.shape[0]:
        raise AssertionError("len(index) != len(labels)")

    min_count = max(min_count, 1)
    nobs = np.zeros((<object>out).shape, dtype=np.int64)
    if iu_64_floating_obj_t is object:
        resx = np.empty((<object>out).shape, dtype=object)
    else:
        resx = np.empty_like(out)

    N, K = (<object>values).shape

    if iu_64_floating_obj_t is object:
        # TODO(cython3): De-duplicate once conditional-nogil is available
        for i in range(N):
            lab = labels[i]
            if lab < 0:
                continue

            counts[lab] += 1
            for j in range(K):
                val = values[i, j]

                if uses_mask:
                    isna_entry = mask[i, j]
                else:
                    isna_entry = checknull(val)

                if not isna_entry:
                    # NB: use _treat_as_na here once
                    #  conditional-nogil is available.
                    nobs[lab, j] += 1
                    resx[lab, j] = val

        for i in range(ncounts):
            for j in range(K):
                if nobs[i, j] < min_count:
                    out[i, j] = None
                else:
                    out[i, j] = resx[i, j]
    else:
        with nogil:
            for i in range(N):
                lab = labels[i]
                if lab < 0:
                    continue

                counts[lab] += 1
                for j in range(K):
                    val = values[i, j]

                    if uses_mask:
                        isna_entry = mask[i, j]
                    else:
                        isna_entry = _treat_as_na(val, True)
                        # TODO: Sure we always want is_datetimelike=True?

                    if not isna_entry:
                        nobs[lab, j] += 1
                        resx[lab, j] = val

            for i in range(ncounts):
                for j in range(K):
                    if nobs[i, j] < min_count:
                        if uses_mask:
                            result_mask[i, j] = True
                        elif iu_64_floating_obj_t is int64_t:
                            # TODO: only if datetimelike?
                            out[i, j] = NPY_NAT
                        elif iu_64_floating_obj_t is uint64_t:
                            runtime_error = True
                            break
                        else:
                            out[i, j] = NAN

                    else:
                        out[i, j] = resx[i, j]

    if runtime_error:
        # We cannot raise directly above because that is within a nogil
        #  block.
        raise RuntimeError("empty group with uint64_t")


# TODO(cython3): GH#31710 use memorviews once cython 0.30 is released so we can
#  use `const iu_64_floating_obj_t[:, :] values`
@cython.wraparound(False)
@cython.boundscheck(False)
def group_nth(
    iu_64_floating_obj_t[:, ::1] out,
    int64_t[::1] counts,
    ndarray[iu_64_floating_obj_t, ndim=2] values,
    const intp_t[::1] labels,
    const uint8_t[:, :] mask,
    uint8_t[:, ::1] result_mask=None,
    int64_t min_count=-1,
    int64_t rank=1,
) -> None:
    """
    Only aggregates on axis=0
    """
    cdef:
        Py_ssize_t i, j, N, K, lab, ncounts = len(counts)
        iu_64_floating_obj_t val
        ndarray[iu_64_floating_obj_t, ndim=2] resx
        ndarray[int64_t, ndim=2] nobs
        bint runtime_error = False
        bint uses_mask = mask is not None
        bint isna_entry

    # TODO(cython3):
    # Instead of `labels.shape[0]` use `len(labels)`
    if not len(values) == labels.shape[0]:
        raise AssertionError("len(index) != len(labels)")

    min_count = max(min_count, 1)
    nobs = np.zeros((<object>out).shape, dtype=np.int64)
    if iu_64_floating_obj_t is object:
        resx = np.empty((<object>out).shape, dtype=object)
    else:
        resx = np.empty_like(out)

    N, K = (<object>values).shape

    if iu_64_floating_obj_t is object:
        # TODO(cython3): De-duplicate once conditional-nogil is available
        for i in range(N):
            lab = labels[i]
            if lab < 0:
                continue

            counts[lab] += 1
            for j in range(K):
                val = values[i, j]

                if uses_mask:
                    isna_entry = mask[i, j]
                else:
                    isna_entry = checknull(val)

                if not isna_entry:
                    # NB: use _treat_as_na here once
                    #  conditional-nogil is available.
                    nobs[lab, j] += 1
                    if nobs[lab, j] == rank:
                        resx[lab, j] = val

        for i in range(ncounts):
            for j in range(K):
                if nobs[i, j] < min_count:
                    out[i, j] = None
                else:
                    out[i, j] = resx[i, j]

    else:
        with nogil:
            for i in range(N):
                lab = labels[i]
                if lab < 0:
                    continue

                counts[lab] += 1
                for j in range(K):
                    val = values[i, j]

                    if uses_mask:
                        isna_entry = mask[i, j]
                    else:
                        isna_entry = _treat_as_na(val, True)
                        # TODO: Sure we always want is_datetimelike=True?

                    if not isna_entry:
                        nobs[lab, j] += 1
                        if nobs[lab, j] == rank:
                            resx[lab, j] = val

            for i in range(ncounts):
                for j in range(K):
                    if nobs[i, j] < min_count:
                        if uses_mask:
                            result_mask[i, j] = True
                        elif iu_64_floating_obj_t is int64_t:
                            # TODO: only if datetimelike?
                            out[i, j] = NPY_NAT
                        elif iu_64_floating_obj_t is uint64_t:
                            runtime_error = True
                            break
                        else:
                            out[i, j] = NAN
                    else:
                        out[i, j] = resx[i, j]

    if runtime_error:
        # We cannot raise directly above because that is within a nogil
        #  block.
        raise RuntimeError("empty group with uint64_t")


@cython.boundscheck(False)
@cython.wraparound(False)
def group_rank(
    float64_t[:, ::1] out,
    ndarray[iu_64_floating_obj_t, ndim=2] values,
    const intp_t[::1] labels,
    int ngroups,
    bint is_datetimelike,
    str ties_method="average",
    bint ascending=True,
    bint pct=False,
    str na_option="keep",
) -> None:
    """
    Provides the rank of values within each group.

    Parameters
    ----------
    out : np.ndarray[np.float64, ndim=2]
        Values to which this method will write its results.
    values : np.ndarray of iu_64_floating_obj_t values to be ranked
    labels : np.ndarray[np.intp]
        Array containing unique label for each group, with its ordering
        matching up to the corresponding record in `values`
    ngroups : int
        This parameter is not used, is needed to match signatures of other
        groupby functions.
    is_datetimelike : bool
        True if `values` contains datetime-like entries.
    ties_method : {'average', 'min', 'max', 'first', 'dense'}, default 'average'
        * average: average rank of group
        * min: lowest rank in group
        * max: highest rank in group
        * first: ranks assigned in order they appear in the array
        * dense: like 'min', but rank always increases by 1 between groups
    ascending : bool, default True
        False for ranks by high (1) to low (N)
        na_option : {'keep', 'top', 'bottom'}, default 'keep'
    pct : bool, default False
        Compute percentage rank of data within each group
    na_option : {'keep', 'top', 'bottom'}, default 'keep'
        * keep: leave NA values where they are
        * top: smallest rank if ascending
        * bottom: smallest rank if descending

    Notes
    -----
    This method modifies the `out` parameter rather than returning an object
    """
    cdef:
        Py_ssize_t i, k, N
        ndarray[float64_t, ndim=1] result

    N = values.shape[1]

    for k in range(N):
        result = rank_1d(
            values=values[:, k],
            labels=labels,
            is_datetimelike=is_datetimelike,
            ties_method=ties_method,
            ascending=ascending,
            pct=pct,
            na_option=na_option
        )
        for i in range(len(result)):
            # TODO: why can't we do out[:, k] = result?
            out[i, k] = result[i]


# ----------------------------------------------------------------------
# group_min, group_max
# ----------------------------------------------------------------------

# TODO: consider implementing for more dtypes

@cython.wraparound(False)
@cython.boundscheck(False)
cdef group_min_max(
    iu_64_floating_t[:, ::1] out,
    int64_t[::1] counts,
    ndarray[iu_64_floating_t, ndim=2] values,
    const intp_t[::1] labels,
    Py_ssize_t min_count=-1,
    bint is_datetimelike=False,
    bint compute_max=True,
    const uint8_t[:, ::1] mask=None,
    uint8_t[:, ::1] result_mask=None,
):
    """
    Compute minimum/maximum  of columns of `values`, in row groups `labels`.

    Parameters
    ----------
    out : np.ndarray[iu_64_floating_t, ndim=2]
        Array to store result in.
    counts : np.ndarray[int64]
        Input as a zeroed array, populated by group sizes during algorithm
    values : array
        Values to find column-wise min/max of.
    labels : np.ndarray[np.intp]
        Labels to group by.
    min_count : Py_ssize_t, default -1
        The minimum number of non-NA group elements, NA result if threshold
        is not met
    is_datetimelike : bool
        True if `values` contains datetime-like entries.
    compute_max : bint, default True
        True to compute group-wise max, False to compute min
    mask : ndarray[bool, ndim=2], optional
        If not None, indices represent missing values,
        otherwise the mask will not be used
    result_mask : ndarray[bool, ndim=2], optional
        If not None, these specify locations in the output that are NA.
        Modified in-place.

    Notes
    -----
    This method modifies the `out` parameter, rather than returning an object.
    `counts` is modified to hold group sizes
    """
    cdef:
        Py_ssize_t i, j, N, K, lab, ngroups = len(counts)
        iu_64_floating_t val, nan_val
        ndarray[iu_64_floating_t, ndim=2] group_min_or_max
        bint runtime_error = False
        int64_t[:, ::1] nobs
        bint uses_mask = mask is not None
        bint isna_entry

    # TODO(cython3):
    # Instead of `labels.shape[0]` use `len(labels)`
    if not len(values) == labels.shape[0]:
        raise AssertionError("len(index) != len(labels)")

    min_count = max(min_count, 1)
    nobs = np.zeros((<object>out).shape, dtype=np.int64)

    group_min_or_max = np.empty_like(out)
    if iu_64_floating_t is int64_t:
        group_min_or_max[:] = -_int64_max if compute_max else _int64_max
        nan_val = NPY_NAT
    elif iu_64_floating_t is uint64_t:
        # NB: We do not define nan_val because there is no such thing
        # for uint64_t.  We carefully avoid having to reference it in this
        # case.
        group_min_or_max[:] = 0 if compute_max else np.iinfo(np.uint64).max
    else:
        group_min_or_max[:] = -np.inf if compute_max else np.inf
        nan_val = NAN

    N, K = (<object>values).shape

    with nogil:
        for i in range(N):
            lab = labels[i]
            if lab < 0:
                continue

            counts[lab] += 1
            for j in range(K):
                val = values[i, j]

                if uses_mask:
                    isna_entry = mask[i, j]
                else:
                    isna_entry = _treat_as_na(val, is_datetimelike)

                if not isna_entry:
                    nobs[lab, j] += 1
                    if compute_max:
                        if val > group_min_or_max[lab, j]:
                            group_min_or_max[lab, j] = val
                    else:
                        if val < group_min_or_max[lab, j]:
                            group_min_or_max[lab, j] = val

        for i in range(ngroups):
            for j in range(K):
                if nobs[i, j] < min_count:
                    if uses_mask:
                        result_mask[i, j] = True
                        # set out[i, j] to 0 to be deterministic, as
                        #  it was initialized with np.empty. Also ensures
                        #  we can downcast out if appropriate.
                        out[i, j] = 0
                    elif iu_64_floating_t is uint64_t:
                        runtime_error = True
                        break
                    else:
                        out[i, j] = nan_val
                else:
                    out[i, j] = group_min_or_max[i, j]

    if runtime_error:
        # We cannot raise directly above because that is within a nogil
        #  block.
        raise RuntimeError("empty group with uint64_t")


@cython.wraparound(False)
@cython.boundscheck(False)
def group_max(
    iu_64_floating_t[:, ::1] out,
    int64_t[::1] counts,
    ndarray[iu_64_floating_t, ndim=2] values,
    const intp_t[::1] labels,
    Py_ssize_t min_count=-1,
    bint is_datetimelike=False,
    const uint8_t[:, ::1] mask=None,
    uint8_t[:, ::1] result_mask=None,
) -> None:
    """See group_min_max.__doc__"""
    group_min_max(
        out,
        counts,
        values,
        labels,
        min_count=min_count,
        is_datetimelike=is_datetimelike,
        compute_max=True,
        mask=mask,
        result_mask=result_mask,
    )


@cython.wraparound(False)
@cython.boundscheck(False)
def group_min(
    iu_64_floating_t[:, ::1] out,
    int64_t[::1] counts,
    ndarray[iu_64_floating_t, ndim=2] values,
    const intp_t[::1] labels,
    Py_ssize_t min_count=-1,
    bint is_datetimelike=False,
    const uint8_t[:, ::1] mask=None,
    uint8_t[:, ::1] result_mask=None,
) -> None:
    """See group_min_max.__doc__"""
    group_min_max(
        out,
        counts,
        values,
        labels,
        min_count=min_count,
        is_datetimelike=is_datetimelike,
        compute_max=False,
        mask=mask,
        result_mask=result_mask,
    )


@cython.boundscheck(False)
@cython.wraparound(False)
cdef group_cummin_max(
    iu_64_floating_t[:, ::1] out,
    ndarray[iu_64_floating_t, ndim=2] values,
    uint8_t[:, ::1] mask,
    const intp_t[::1] labels,
    int ngroups,
    bint is_datetimelike,
    bint skipna,
    bint compute_max,
):
    """
    Cumulative minimum/maximum of columns of `values`, in row groups `labels`.

    Parameters
    ----------
    out : np.ndarray[iu_64_floating_t, ndim=2]
        Array to store cummin/max in.
    values : np.ndarray[iu_64_floating_t, ndim=2]
        Values to take cummin/max of.
    mask : np.ndarray[bool] or None
        If not None, indices represent missing values,
        otherwise the mask will not be used
    labels : np.ndarray[np.intp]
        Labels to group by.
    ngroups : int
        Number of groups, larger than all entries of `labels`.
    is_datetimelike : bool
        True if `values` contains datetime-like entries.
    skipna : bool
        If True, ignore nans in `values`.
    compute_max : bool
        True if cumulative maximum should be computed, False
        if cumulative minimum should be computed

    Notes
    -----
    This method modifies the `out` parameter, rather than returning an object.
    """
    cdef:
        iu_64_floating_t[:, ::1] accum
        Py_ssize_t i, j, N, K
        iu_64_floating_t val, mval, na_val
        uint8_t[:, ::1] seen_na
        intp_t lab
        bint na_possible
        bint uses_mask = mask is not None
        bint isna_entry

    accum = np.empty((ngroups, (<object>values).shape[1]), dtype=values.dtype)
    if iu_64_floating_t is int64_t:
        accum[:] = -_int64_max if compute_max else _int64_max
    elif iu_64_floating_t is uint64_t:
        accum[:] = 0 if compute_max else np.iinfo(np.uint64).max
    else:
        accum[:] = -np.inf if compute_max else np.inf

    if uses_mask:
        na_possible = True
        # Will never be used, just to avoid uninitialized warning
        na_val = 0
    elif iu_64_floating_t is float64_t or iu_64_floating_t is float32_t:
        na_val = NaN
        na_possible = True
    elif is_datetimelike:
        na_val = NPY_NAT
        na_possible = True
    else:
        # Will never be used, just to avoid uninitialized warning
        na_val = 0
        na_possible = False

    if na_possible:
        seen_na = np.zeros((<object>accum).shape, dtype=np.uint8)

    N, K = (<object>values).shape
    with nogil:
        for i in range(N):
            lab = labels[i]
            if lab < 0:
                continue
            for j in range(K):

                if not skipna and na_possible and seen_na[lab, j]:
                    if uses_mask:
                        mask[i, j] = 1   # FIXME: shouldn't alter inplace
                        # Set to 0 ensures that we are deterministic and can
                        #  downcast if appropriate
                        out[i, j] = 0

                    else:
                        out[i, j] = na_val
                else:
                    val = values[i, j]

                    if uses_mask:
                        isna_entry = mask[i, j]
                    else:
                        isna_entry = _treat_as_na(val, is_datetimelike)

                    if not isna_entry:
                        mval = accum[lab, j]
                        if compute_max:
                            if val > mval:
                                accum[lab, j] = mval = val
                        else:
                            if val < mval:
                                accum[lab, j] = mval = val
                        out[i, j] = mval
                    else:
                        seen_na[lab, j] = 1
                        out[i, j] = val


@cython.boundscheck(False)
@cython.wraparound(False)
def group_cummin(
    iu_64_floating_t[:, ::1] out,
    ndarray[iu_64_floating_t, ndim=2] values,
    const intp_t[::1] labels,
    int ngroups,
    bint is_datetimelike,
    uint8_t[:, ::1] mask=None,
    bint skipna=True,
) -> None:
    """See group_cummin_max.__doc__"""
    group_cummin_max(
        out,
        values,
        mask,
        labels,
        ngroups,
        is_datetimelike,
        skipna,
        compute_max=False
    )


@cython.boundscheck(False)
@cython.wraparound(False)
def group_cummax(
    iu_64_floating_t[:, ::1] out,
    ndarray[iu_64_floating_t, ndim=2] values,
    const intp_t[::1] labels,
    int ngroups,
    bint is_datetimelike,
    uint8_t[:, ::1] mask=None,
    bint skipna=True,
) -> None:
    """See group_cummin_max.__doc__"""
    group_cummin_max(
        out,
        values,
        mask,
        labels,
        ngroups,
        is_datetimelike,
        skipna,
        compute_max=True
    )
