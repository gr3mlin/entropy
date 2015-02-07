# cython: profile=False

cimport numpy as np
from numpy cimport (int8_t, int32_t, int64_t, import_array, ndarray,
                    NPY_INT64, NPY_DATETIME, NPY_TIMEDELTA)
import numpy as np

from cpython cimport (
    PyTypeObject,
    PyFloat_Check,
    PyLong_Check,
    PyObject_RichCompareBool,
    PyObject_RichCompare,
    PyString_Check,
    Py_GT, Py_GE, Py_EQ, Py_NE, Py_LT, Py_LE
)

# Cython < 0.17 doesn't have this in cpython
cdef extern from "Python.h":
    cdef PyTypeObject *Py_TYPE(object)
    int PySlice_Check(object)

cdef extern from "datetime_helper.h":
    double total_seconds(object)

# this is our datetime.pxd
from datetime cimport *
from util cimport is_integer_object, is_float_object, is_datetime64_object, is_timedelta64_object

from libc.stdlib cimport free

cimport util

from datetime cimport *
from khash cimport *
cimport cython

from datetime import timedelta, datetime
from datetime import time as datetime_time

# dateutil compat
from dateutil.tz import (tzoffset, tzlocal as _dateutil_tzlocal, tzfile as _dateutil_tzfile,
                         tzutc as _dateutil_tzutc)
from dateutil.zoneinfo import gettz as _dateutil_gettz

from pytz.tzinfo import BaseTzInfo as _pytz_BaseTzInfo
from pandas.compat import parse_date, string_types, PY3, iteritems

from sys import version_info
import operator
import collections

# GH3363
cdef bint PY2 = version_info[0] == 2

# initialize numpy
import_array()
#import_ufunc()

# import datetime C API
PyDateTime_IMPORT

# in numpy 1.7, will prob need the following:
# numpy_pydatetime_import

cdef int64_t NPY_NAT = util.get_nat()

# < numpy 1.7 compat for NaT
compat_NaT = np.array([NPY_NAT]).astype('m8[ns]').item()

# numpy actual nat object
np_NaT = np.datetime64('NaT')

try:
    basestring
except NameError: # py3
    basestring = str

cdef inline object create_timestamp_from_ts(int64_t value, pandas_datetimestruct dts, object tz, object offset):
    cdef _Timestamp ts_base
    ts_base = _Timestamp.__new__(Timestamp, dts.year, dts.month,
                                 dts.day, dts.hour, dts.min,
                                 dts.sec, dts.us, tz)

    ts_base.value = value
    ts_base.offset = offset
    ts_base.nanosecond = dts.ps / 1000

    return ts_base

cdef inline object create_datetime_from_ts(int64_t value, pandas_datetimestruct dts, object tz, object offset):
    return datetime(dts.year, dts.month, dts.day, dts.hour,
                    dts.min, dts.sec, dts.us, tz)

def ints_to_pydatetime(ndarray[int64_t] arr, tz=None, offset=None, box=False):
    # convert an i8 repr to an ndarray of datetimes or Timestamp (if box == True)

    cdef:
        Py_ssize_t i, n = len(arr)
        pandas_datetimestruct dts
        object dt
        int64_t value
        ndarray[object] result = np.empty(n, dtype=object)
        object (*func_create)(int64_t, pandas_datetimestruct, object, object)

    if box and util.is_string_object(offset):
        from pandas.tseries.frequencies import to_offset
        offset = to_offset(offset)

    if box:
        func_create = create_timestamp_from_ts
    else:
        func_create = create_datetime_from_ts

    if tz is not None:
        if _is_utc(tz):
            for i in range(n):
                value = arr[i]
                if value == iNaT:
                    result[i] = NaT
                else:
                    pandas_datetime_to_datetimestruct(value, PANDAS_FR_ns, &dts)
                    result[i] = func_create(value, dts, tz, offset)
        elif _is_tzlocal(tz) or _is_fixed_offset(tz):
            for i in range(n):
                value = arr[i]
                if value == iNaT:
                    result[i] = NaT
                else:
                    pandas_datetime_to_datetimestruct(value, PANDAS_FR_ns, &dts)
                    dt = func_create(value, dts, tz, offset)
                    if not box:
                        dt = dt + tz.utcoffset(dt)
                    result[i] = dt
        else:
            trans, deltas, typ = _get_dst_info(tz)

            for i in range(n):

                value = arr[i]
                if value == iNaT:
                    result[i] = NaT
                else:

                    # Adjust datetime64 timestamp, recompute datetimestruct
                    pos = trans.searchsorted(value, side='right') - 1
                    if _treat_tz_as_pytz(tz):
                        # find right representation of dst etc in pytz timezone
                        new_tz = tz._tzinfos[tz._transition_info[pos]]
                    else:
                        # no zone-name change for dateutil tzs - dst etc represented in single object.
                        new_tz = tz

                    pandas_datetime_to_datetimestruct(value + deltas[pos], PANDAS_FR_ns, &dts)
                    result[i] = func_create(value, dts, new_tz, offset)
    else:
        for i in range(n):

            value = arr[i]
            if value == iNaT:
                result[i] = NaT
            else:
                pandas_datetime_to_datetimestruct(value, PANDAS_FR_ns, &dts)
                result[i] = func_create(value, dts, None, offset)

    return result

def ints_to_pytimedelta(ndarray[int64_t] arr, box=False):
    # convert an i8 repr to an ndarray of timedelta or Timedelta (if box == True)

    cdef:
        Py_ssize_t i, n = len(arr)
        int64_t value
        ndarray[object] result = np.empty(n, dtype=object)

    for i in range(n):

        value = arr[i]
        if value == iNaT:
            result[i] = NaT
        else:
            if box:
                result[i] = Timedelta(value)
            else:
                result[i] = timedelta(microseconds=int(value)/1000)

    return result


cdef inline bint _is_tzlocal(object tz):
    return isinstance(tz, _dateutil_tzlocal)

cdef inline bint _is_fixed_offset(object tz):
    if _treat_tz_as_dateutil(tz):
        if len(tz._trans_idx) == 0 and len(tz._trans_list) == 0:
            return 1
        else:
            return 0
    elif _treat_tz_as_pytz(tz):
        if len(tz._transition_info) == 0 and len(tz._utc_transition_times) == 0:
            return 1
        else:
            return 0
    return 1


_zero_time = datetime_time(0, 0)

# Python front end to C extension type _Timestamp
# This serves as the box for datetime64
class Timestamp(_Timestamp):
    """TimeStamp is the pandas equivalent of python's Datetime
    and is interchangable with it in most cases. It's the type used
    for the entries that make up a DatetimeIndex, and other timeseries
    oriented data structures in pandas.
    """

    @classmethod
    def fromordinal(cls, ordinal, offset=None, tz=None):
        """ passed an ordinal, translate and convert to a ts
            note: by definition there cannot be any tz info on the ordinal itself """
        return cls(datetime.fromordinal(ordinal),offset=offset,tz=tz)

    @classmethod
    def now(cls, tz=None):
        """
        Return the current time in the local timezone.  Equivalent
        to datetime.now([tz])

        Parameters
        ----------
        tz : string / timezone object, default None
            Timezone to localize to
        """
        if isinstance(tz, basestring):
            tz = maybe_get_tz(tz)
        return cls(datetime.now(tz))

    @classmethod
    def today(cls, tz=None):
        """
        Return the current time in the local timezone.  This differs
        from datetime.today() in that it can be localized to a
        passed timezone.

        Parameters
        ----------
        tz : string / timezone object, default None
            Timezone to localize to
        """
        return cls.now(tz)

    @classmethod
    def utcnow(cls):
        return cls.now('UTC')

    @classmethod
    def utcfromtimestamp(cls, ts):
        return cls(datetime.utcfromtimestamp(ts))

    @classmethod
    def fromtimestamp(cls, ts):
        return cls(datetime.fromtimestamp(ts))

    @classmethod
    def combine(cls, date, time):
        return cls(datetime.combine(date, time))

    def __new__(cls, object ts_input, object offset=None, tz=None, unit=None):
        cdef _TSObject ts
        cdef _Timestamp ts_base

        ts = convert_to_tsobject(ts_input, tz, unit)

        if ts.value == NPY_NAT:
            return NaT

        if util.is_string_object(offset):
            from pandas.tseries.frequencies import to_offset
            offset = to_offset(offset)

        # make datetime happy
        ts_base = _Timestamp.__new__(cls, ts.dts.year, ts.dts.month,
                                     ts.dts.day, ts.dts.hour, ts.dts.min,
                                     ts.dts.sec, ts.dts.us, ts.tzinfo)

        # fill out rest of data
        ts_base.value = ts.value
        ts_base.offset = offset
        ts_base.nanosecond = ts.dts.ps / 1000

        return ts_base

    def __repr__(self):
        stamp = self._repr_base
        zone = None

        try:
            stamp += self.strftime('%z')
            if self.tzinfo:
                zone = _get_zone(self.tzinfo)
        except ValueError:
            year2000 = self.replace(year=2000)
            stamp += year2000.strftime('%z')
            if self.tzinfo:
                zone = _get_zone(self.tzinfo)

        try:
            stamp += zone.strftime(' %%Z')
        except:
            pass

        tz = ", tz='{0}'".format(zone) if zone is not None else ""
        offset = ", offset='{0}'".format(self.offset.freqstr) if self.offset is not None else ""

        return "Timestamp('{stamp}'{tz}{offset})".format(stamp=stamp, tz=tz, offset=offset)

    @property
    def _date_repr(self):
        # Ideal here would be self.strftime("%Y-%m-%d"), but
        # the datetime strftime() methods require year >= 1900
        return '%d-%.2d-%.2d' % (self.year, self.month, self.day)

    @property
    def _time_repr(self):
        result = '%.2d:%.2d:%.2d' % (self.hour, self.minute, self.second)

        if self.nanosecond != 0:
            result += '.%.9d' % (self.nanosecond + 1000 * self.microsecond)
        elif self.microsecond != 0:
            result += '.%.6d' % self.microsecond

        return result

    @property
    def _repr_base(self):
        return '%s %s' % (self._date_repr, self._time_repr)

    @property
    def tz(self):
        """
        Alias for tzinfo
        """
        return self.tzinfo

    @property
    def freq(self):
        return self.offset

    def __setstate__(self, state):
        self.value = state[0]
        self.offset = state[1]
        self.tzinfo = state[2]

    def __reduce__(self):
        object_state = self.value, self.offset, self.tzinfo
        return (Timestamp, object_state)

    def to_period(self, freq=None):
        """
        Return an period of which this timestamp is an observation.
        """
        from pandas.tseries.period import Period

        if freq is None:
            freq = self.freq

        return Period(self, freq=freq)

    @property
    def dayofweek(self):
        return self.weekday()

    @property
    def dayofyear(self):
        return self._get_field('doy')

    @property
    def week(self):
        return self._get_field('woy')

    weekofyear = week

    @property
    def microsecond(self):
        return self._get_field('us')

    @property
    def quarter(self):
        return self._get_field('q')

    @property
    def freqstr(self):
        return getattr(self.offset, 'freqstr', self.offset)

    @property
    def asm8(self):
        return np.int64(self.value).view('M8[ns]')

    @property
    def is_month_start(self):
        return self._get_start_end_field('is_month_start')

    @property
    def is_month_end(self):
        return self._get_start_end_field('is_month_end')

    @property
    def is_quarter_start(self):
        return self._get_start_end_field('is_quarter_start')

    @property
    def is_quarter_end(self):
        return self._get_start_end_field('is_quarter_end')

    @property
    def is_year_start(self):
        return self._get_start_end_field('is_year_start')

    @property
    def is_year_end(self):
        return self._get_start_end_field('is_year_end')

    def tz_localize(self, tz, ambiguous='raise'):
        """
        Convert naive Timestamp to local time zone, or remove
        timezone from tz-aware Timestamp.

        Parameters
        ----------
        tz : string, pytz.timezone, dateutil.tz.tzfile or None
            Time zone for time which Timestamp will be converted to.
            None will remove timezone holding local time.
        ambiguous : bool, 'NaT', default 'raise'
            - bool contains flags to determine if time is dst or not (note
            that this flag is only applicable for ambiguous fall dst dates)
            - 'NaT' will return NaT for an ambiguous time
            - 'raise' will raise an AmbiguousTimeError for an ambiguous time

        Returns
        -------
        localized : Timestamp
        """
        if ambiguous == 'infer':
            raise ValueError('Cannot infer offset with only one time.')

        if self.tzinfo is None:
            # tz naive, localize
            tz = maybe_get_tz(tz)
            if not isinstance(ambiguous, basestring):
                ambiguous   =   [ambiguous]
            value = tz_localize_to_utc(np.array([self.value]), tz,
                                       ambiguous=ambiguous)[0]
            return Timestamp(value, tz=tz)
        else:
            if tz is None:
                # reset tz
                value = tz_convert_single(self.value, 'UTC', self.tz)
                return Timestamp(value, tz=None)
            else:
                raise TypeError('Cannot localize tz-aware Timestamp, use '
                                'tz_convert for conversions')

    def tz_convert(self, tz):
        """
        Convert Timestamp to another time zone or localize to requested time
        zone

        Parameters
        ----------
        tz : string, pytz.timezone, dateutil.tz.tzfile or None
            Time zone for time which Timestamp will be converted to.
            None will remove timezone holding UTC time.

        Returns
        -------
        converted : Timestamp
        """
        if self.tzinfo is None:
            # tz naive, use tz_localize
            raise TypeError('Cannot convert tz-naive Timestamp, use '
                            'tz_localize to localize')
        else:
            # Same UTC timestamp, different time zone
            return Timestamp(self.value, tz=tz)

    astimezone = tz_convert

    def replace(self, **kwds):
        return Timestamp(datetime.replace(self, **kwds),
                         offset=self.offset)

    def to_pydatetime(self, warn=True):
        """
        If warn=True, issue warning if nanoseconds is nonzero
        """
        cdef:
            pandas_datetimestruct dts
            _TSObject ts

        if self.nanosecond != 0 and warn:
            print 'Warning: discarding nonzero nanoseconds'
        ts = convert_to_tsobject(self, self.tzinfo, None)

        return datetime(ts.dts.year, ts.dts.month, ts.dts.day,
                        ts.dts.hour, ts.dts.min, ts.dts.sec,
                        ts.dts.us, ts.tzinfo)

    def isoformat(self, sep='T'):
        base = super(_Timestamp, self).isoformat(sep=sep)
        if self.nanosecond == 0:
            return base

        if self.tzinfo is not None:
            base1, base2 = base[:-6], base[-6:]
        else:
            base1, base2 = base, ""

        if self.microsecond != 0:
            base1 += "%.3d" % self.nanosecond
        else:
            base1 += ".%.9d" % self.nanosecond

        return base1 + base2

    def _has_time_component(self):
        """
        Returns if the Timestamp has a time component
        in addition to the date part
        """
        return (self.time() != _zero_time
                or self.tzinfo is not None
                or self.nanosecond != 0)

    def to_julian_date(self):
        """
        Convert TimeStamp to a Julian Date.
        0 Julian date is noon January 1, 4713 BC.
        """
        year = self.year
        month = self.month
        day = self.day
        if month <= 2:
            year -= 1
            month += 12
        return (day +
                np.fix((153*month - 457)/5) +
                365*year +
                np.floor(year / 4) -
                np.floor(year / 100) +
                np.floor(year / 400) +
                1721118.5 +
                (self.hour +
                 self.minute/60.0 +
                 self.second/3600.0 +
                 self.microsecond/3600.0/1e+6 +
                 self.nanosecond/3600.0/1e+9
                )/24.0)

    def __radd__(self, other):
        # __radd__ on cython extension types like _Timestamp is not used, so
        # define it here instead
        return self + other


_nat_strings = set(['NaT','nat','NAT','nan','NaN','NAN'])
class NaTType(_NaT):
    """(N)ot-(A)-(T)ime, the time equivalent of NaN"""

    def __new__(cls):
        cdef _NaT base

        base = _NaT.__new__(cls, 1, 1, 1)
        mangle_nat(base)
        base.value = NPY_NAT

        return base

    def __repr__(self):
        return 'NaT'

    def __str__(self):
        return 'NaT'

    def __hash__(self):
        return iNaT

    def __int__(self):
        return NPY_NAT

    def __long__(self):
        return NPY_NAT

    def weekday(self):
        return np.nan

    def toordinal(self):
        return -1

    def __reduce__(self):
        return (__nat_unpickle, (None, ))

fields = ['year', 'quarter', 'month', 'day', 'hour',
          'minute', 'second', 'millisecond', 'microsecond', 'nanosecond',
          'week', 'dayofyear']
for field in fields:
    prop = property(fget=lambda self: np.nan)
    setattr(NaTType, field, prop)

def __nat_unpickle(*args):
    # return constant defined in the module
    return NaT

NaT = NaTType()

iNaT = util.get_nat()


cdef inline bint _checknull_with_nat(object val):
    """ utility to check if a value is a nat or not """
    return val is None or (
        PyFloat_Check(val) and val != val) or val is NaT

cdef inline bint _cmp_nat_dt(_NaT lhs, _Timestamp rhs, int op) except -1:
    return _nat_scalar_rules[op]


cdef _tz_format(object obj, object zone):
    try:
        return obj.strftime(' %%Z, tz=%s' % zone)
    except:
        return ', tz=%s' % zone

def is_timestamp_array(ndarray[object] values):
    cdef int i, n = len(values)
    if n == 0:
        return False
    for i in range(n):
        if not is_timestamp(values[i]):
            return False
    return True


cpdef object get_value_box(ndarray arr, object loc):
    cdef:
        Py_ssize_t i, sz
        void* data_ptr

    if util.is_float_object(loc):
        casted = int(loc)
        if casted == loc:
            loc = casted
    i = <Py_ssize_t> loc
    sz = np.PyArray_SIZE(arr)

    if i < 0 and sz > 0:
        i += sz

    if i >= sz or sz == 0 or i < 0:
        raise IndexError('index out of bounds')

    if arr.descr.type_num == NPY_DATETIME:
        return Timestamp(util.get_value_1d(arr, i))
    elif arr.descr.type_num == NPY_TIMEDELTA:
        return Timedelta(util.get_value_1d(arr, i))
    else:
        return util.get_value_1d(arr, i)


# Add the min and max fields at the class level
# These are defined as magic numbers due to strange
# wraparound behavior when using the true int64 lower boundary
cdef int64_t _NS_LOWER_BOUND = -9223285636854775000LL
cdef int64_t _NS_UPPER_BOUND = 9223372036854775807LL

cdef pandas_datetimestruct _NS_MIN_DTS, _NS_MAX_DTS
pandas_datetime_to_datetimestruct(_NS_LOWER_BOUND, PANDAS_FR_ns, &_NS_MIN_DTS)
pandas_datetime_to_datetimestruct(_NS_UPPER_BOUND, PANDAS_FR_ns, &_NS_MAX_DTS)

Timestamp.min = Timestamp(_NS_LOWER_BOUND)
Timestamp.max = Timestamp(_NS_UPPER_BOUND)


#----------------------------------------------------------------------
# Frequency inference

def unique_deltas(ndarray[int64_t] arr):
    cdef:
        Py_ssize_t i, n = len(arr)
        int64_t val
        khiter_t k
        kh_int64_t *table
        int ret = 0
        list uniques = []

    table = kh_init_int64()
    kh_resize_int64(table, 10)
    for i in range(n - 1):
        val = arr[i + 1] - arr[i]
        k = kh_get_int64(table, val)
        if k == table.n_buckets:
            kh_put_int64(table, val, &ret)
            uniques.append(val)
    kh_destroy_int64(table)

    result = np.array(uniques, dtype=np.int64)
    result.sort()
    return result


cdef inline bint _is_multiple(int64_t us, int64_t mult):
    return us % mult == 0


def apply_offset(ndarray[object] values, object offset):
    cdef:
        Py_ssize_t i, n = len(values)
        ndarray[int64_t] new_values
        object boxed

    result = np.empty(n, dtype='M8[ns]')
    new_values = result.view('i8')


cdef inline bint _cmp_scalar(int64_t lhs, int64_t rhs, int op) except -1:
    if op == Py_EQ:
        return lhs == rhs
    elif op == Py_NE:
        return lhs != rhs
    elif op == Py_LT:
        return lhs < rhs
    elif op == Py_LE:
        return lhs <= rhs
    elif op == Py_GT:
        return lhs > rhs
    elif op == Py_GE:
        return lhs >= rhs


cdef int _reverse_ops[6]

_reverse_ops[Py_LT] = Py_GT
_reverse_ops[Py_LE] = Py_GE
_reverse_ops[Py_EQ] = Py_EQ
_reverse_ops[Py_NE] = Py_NE
_reverse_ops[Py_GT] = Py_LT
_reverse_ops[Py_GE] = Py_LE


cdef str _NDIM_STRING = "ndim"

# This is PITA. Because we inherit from datetime, which has very specific
# construction requirements, we need to do object instantiation in python
# (see Timestamp class above). This will serve as a C extension type that
# shadows the python class, where we do any heavy lifting.
cdef class _Timestamp(datetime):
    cdef readonly:
        int64_t value, nanosecond
        object offset       # frequency reference

    def __hash__(_Timestamp self):
        if self.nanosecond:
            return hash(self.value)
        return datetime.__hash__(self)

    def __richcmp__(_Timestamp self, object other, int op):
        cdef:
            _Timestamp ots
            int ndim

        if isinstance(other, _Timestamp):
            if isinstance(other, _NaT):
                return _cmp_nat_dt(other, self, _reverse_ops[op])
            ots = other
        elif isinstance(other, datetime):
            if self.nanosecond == 0:
                val = self.to_datetime()
                return PyObject_RichCompareBool(val, other, op)

            try:
                ots = Timestamp(other)
            except ValueError:
                return self._compare_outside_nanorange(other, op)
        else:
            ndim = getattr(other, _NDIM_STRING, -1)

            if ndim != -1:
                if ndim == 0:
                    if isinstance(other, np.datetime64):
                        other = Timestamp(other)
                    else:
                        if op == Py_EQ:
                            return False
                        elif op == Py_NE:
                            return True

                        # only allow ==, != ops
                        raise TypeError('Cannot compare type %r with type %r' %
                                        (type(self).__name__,
                                         type(other).__name__))
                return PyObject_RichCompare(other, self, _reverse_ops[op])
            else:
                if op == Py_EQ:
                    return False
                elif op == Py_NE:
                    return True
                raise TypeError('Cannot compare type %r with type %r' %
                                (type(self).__name__, type(other).__name__))

        self._assert_tzawareness_compat(other)
        return _cmp_scalar(self.value, ots.value, op)

    cdef bint _compare_outside_nanorange(_Timestamp self, datetime other,
                                         int op) except -1:
        cdef datetime dtval = self.to_datetime()

        self._assert_tzawareness_compat(other)

        if self.nanosecond == 0:
            return PyObject_RichCompareBool(dtval, other, op)
        else:
            if op == Py_EQ:
                return False
            elif op == Py_NE:
                return True
            elif op == Py_LT:
                return dtval < other
            elif op == Py_LE:
                return dtval < other
            elif op == Py_GT:
                return dtval >= other
            elif op == Py_GE:
                return dtval >= other

    cdef int _assert_tzawareness_compat(_Timestamp self,
                                        object other) except -1:
        if self.tzinfo is None:
            if other.tzinfo is not None:
                raise TypeError('Cannot compare tz-naive and tz-aware '
                                 'timestamps')
        elif other.tzinfo is None:
            raise TypeError('Cannot compare tz-naive and tz-aware timestamps')

    cpdef datetime to_datetime(_Timestamp self):
        cdef:
            pandas_datetimestruct dts
            _TSObject ts
        ts = convert_to_tsobject(self, self.tzinfo, None)
        dts = ts.dts
        return datetime(dts.year, dts.month, dts.day,
                        dts.hour, dts.min, dts.sec,
                        dts.us, ts.tzinfo)

    def __add__(self, other):
        cdef int64_t other_int

        if is_timedelta64_object(other):
            other_int = other.astype('timedelta64[ns]').view('i8')
            return Timestamp(self.value + other_int, tz=self.tzinfo, offset=self.offset)

        elif is_integer_object(other):
            if self.offset is None:
                raise ValueError("Cannot add integral value to Timestamp "
                                 "without offset.")
            return Timestamp((self.offset * other).apply(self), offset=self.offset)

        elif isinstance(other, timedelta) or hasattr(other, 'delta'):
            nanos = _delta_to_nanoseconds(other)
            result = Timestamp(self.value + nanos, tz=self.tzinfo, offset=self.offset)
            if getattr(other, 'normalize', False):
                result = Timestamp(normalize_date(result))
            return result

        # index/series like
        elif hasattr(other, '_typ'):
            return other + self

        result = datetime.__add__(self, other)
        if isinstance(result, datetime):
            result = Timestamp(result)
            result.nanosecond = self.nanosecond
        return result

    def __sub__(self, other):
        if is_timedelta64_object(other) or is_integer_object(other) \
                or isinstance(other, timedelta) or hasattr(other, 'delta'):
            neg_other = -other
            return self + neg_other

        # a Timestamp-DatetimeIndex -> yields a negative TimedeltaIndex
        elif getattr(other,'_typ',None) == 'datetimeindex':

            # we may be passed reverse ops
            if get_timezone(getattr(self,'tzinfo',None)) != get_timezone(other.tz):
                    raise TypeError("Timestamp subtraction must have the same timezones or no timezones")

            return -other.__sub__(self)

        # a Timestamp-TimedeltaIndex -> yields a negative TimedeltaIndex
        elif getattr(other,'_typ',None) == 'timedeltaindex':
            return (-other).__add__(self)

        elif other is NaT:
            return NaT

        # coerce if necessary if we are a Timestamp-like
        if isinstance(self, datetime) and (isinstance(other, datetime) or is_datetime64_object(other)):
            self = Timestamp(self)
            other = Timestamp(other)

            # validate tz's
            if get_timezone(self.tzinfo) != get_timezone(other.tzinfo):
                raise TypeError("Timestamp subtraction must have the same timezones or no timezones")

            # scalar Timestamp/datetime - Timestamp/datetime -> yields a Timedelta
            try:
                return Timedelta(self.value-other.value)
            except (OverflowError, OutOfBoundsDatetime):
                pass

        # scalar Timestamp/datetime - Timedelta -> yields a Timestamp (with same timezone if specified)
        return datetime.__sub__(self, other)

    cpdef _get_field(self, field):
        out = get_date_field(np.array([self.value], dtype=np.int64), field)
        return out[0]

    cpdef _get_start_end_field(self, field):
        month_kw = self.freq.kwds.get('startingMonth', self.freq.kwds.get('month', 12)) if self.freq else 12
        freqstr = self.freqstr if self.freq else None
        out = get_start_end_field(np.array([self.value], dtype=np.int64), field, freqstr, month_kw)
        return out[0]


cdef PyTypeObject* ts_type = <PyTypeObject*> Timestamp


cdef inline bint is_timestamp(object o):
    return Py_TYPE(o) == ts_type # isinstance(o, Timestamp)


cdef bint _nat_scalar_rules[6]

_nat_scalar_rules[Py_EQ] = False
_nat_scalar_rules[Py_NE] = True
_nat_scalar_rules[Py_LT] = False
_nat_scalar_rules[Py_LE] = False
_nat_scalar_rules[Py_GT] = False
_nat_scalar_rules[Py_GE] = False


cdef class _NaT(_Timestamp):

    def __hash__(_NaT self):
        # py3k needs this defined here
        return hash(self.value)

    def __richcmp__(_NaT self, object other, int op):
        cdef int ndim = getattr(other, 'ndim', -1)

        if ndim == -1:
            return _nat_scalar_rules[op]

        if ndim == 0:
            if isinstance(other, np.datetime64):
                other = Timestamp(other)
            else:
                raise TypeError('Cannot compare type %r with type %r' %
                                (type(self).__name__, type(other).__name__))
        return PyObject_RichCompare(other, self, _reverse_ops[op])

    def __add__(self, other):
        try:
            result = _Timestamp.__add__(self, other)
            if result is NotImplemented:
                return result
        except (OverflowError, OutOfBoundsDatetime):
            pass
        return NaT

    def __sub__(self, other):

        if type(self) is datetime:
            other, self = self, other
        try:
            result = _Timestamp.__sub__(self, other)
            if result is NotImplemented:
                return result
        except (OverflowError, OutOfBoundsDatetime):
            pass
        return NaT


def _delta_to_nanoseconds(delta):
    if hasattr(delta, 'delta'):
        delta = delta.delta
    if is_timedelta64_object(delta):
        return delta.astype("timedelta64[ns]").item()
    if is_integer_object(delta):
        return delta
    return (delta.days * 24 * 60 * 60 * 1000000
            + delta.seconds * 1000000
            + delta.microseconds) * 1000


# lightweight C object to hold datetime & int64 pair
cdef class _TSObject:
    cdef:
        pandas_datetimestruct dts      # pandas_datetimestruct
        int64_t value               # numpy dt64
        object tzinfo

    property value:
        def __get__(self):
            return self.value

cpdef _get_utcoffset(tzinfo, obj):
    try:
        return tzinfo._utcoffset
    except AttributeError:
        return tzinfo.utcoffset(obj)

# helper to extract datetime and int64 from several different possibilities
cdef convert_to_tsobject(object ts, object tz, object unit):
    """
    Extract datetime and int64 from any of:
        - np.int64 (with unit providing a possible modifier)
        - np.datetime64
        - a float (with unit providing a possible modifier)
        - python int or long object (with unit providing a possible modifier)
        - iso8601 string object
        - python datetime object
        - another timestamp object
    """
    cdef:
        _TSObject obj
        bint utc_convert = 1
        int out_local = 0, out_tzoffset = 0

    if tz is not None:
        tz = maybe_get_tz(tz)

    obj = _TSObject()

    if util.is_string_object(ts):
        if ts in _nat_strings:
            ts = NaT
        elif ts == 'now':
            # Issue 9000, we short-circuit rather than going
            # into np_datetime_strings which returns utc
            ts = Timestamp.now(tz)
        elif ts == 'today':
            # Issue 9000, we short-circuit rather than going
            # into np_datetime_strings which returns a normalized datetime
            ts = Timestamp.today(tz)
        else:
            try:
                _string_to_dts(ts, &obj.dts, &out_local, &out_tzoffset)
                obj.value = pandas_datetimestruct_to_datetime(PANDAS_FR_ns, &obj.dts)
                _check_dts_bounds(&obj.dts)
                if out_local == 1:
                    obj.tzinfo = pytz.FixedOffset(out_tzoffset)
                    obj.value = tz_convert_single(obj.value, obj.tzinfo, 'UTC')
                    if tz is None:
                        _check_dts_bounds(&obj.dts)
                        return obj
                    else:
                        # Keep the converter same as PyDateTime's
                        ts = Timestamp(obj.value, tz=obj.tzinfo)
                else:
                    ts = obj.value
                    if tz is not None:
                        # shift for _localize_tso
                        ts = tz_convert_single(ts, tz, 'UTC')
            except ValueError:
                try:
                    ts = parse_datetime_string(ts)
                except Exception:
                    raise ValueError

    if ts is None or ts is NaT or ts is np_NaT:
        obj.value = NPY_NAT
    elif is_datetime64_object(ts):
        if ts.view('i8') == iNaT:
            obj.value = NPY_NAT
        else:
            obj.value = _get_datetime64_nanos(ts)
            pandas_datetime_to_datetimestruct(obj.value, PANDAS_FR_ns, &obj.dts)
    elif is_integer_object(ts):
        if ts == NPY_NAT:
            obj.value = NPY_NAT
        else:
            ts = ts * cast_from_unit(None,unit)
            obj.value = ts
            pandas_datetime_to_datetimestruct(ts, PANDAS_FR_ns, &obj.dts)
    elif util.is_float_object(ts):
        if ts != ts or ts == NPY_NAT:
            obj.value = NPY_NAT
        else:
            ts = cast_from_unit(ts,unit)
            obj.value = ts
            pandas_datetime_to_datetimestruct(ts, PANDAS_FR_ns, &obj.dts)
    elif PyDateTime_Check(ts):
        if tz is not None:
            # sort of a temporary hack
            if ts.tzinfo is not None:
                if (hasattr(tz, 'normalize') and
                    hasattr(ts.tzinfo, '_utcoffset')):
                    ts = tz.normalize(ts)
                    obj.value = _pydatetime_to_dts(ts, &obj.dts)
                    obj.tzinfo = ts.tzinfo
                else: #tzoffset
                    try:
                        tz = ts.astimezone(tz).tzinfo
                    except:
                        pass
                    obj.value = _pydatetime_to_dts(ts, &obj.dts)
                    ts_offset = _get_utcoffset(ts.tzinfo, ts)
                    obj.value -= _delta_to_nanoseconds(ts_offset)
                    tz_offset = _get_utcoffset(tz, ts)
                    obj.value += _delta_to_nanoseconds(tz_offset)
                    pandas_datetime_to_datetimestruct(obj.value,
                                                      PANDAS_FR_ns, &obj.dts)
                    obj.tzinfo = tz
            elif not _is_utc(tz):
                ts = _localize_pydatetime(ts, tz)
                obj.value = _pydatetime_to_dts(ts, &obj.dts)
                obj.tzinfo = ts.tzinfo
            else:
                # UTC
                obj.value = _pydatetime_to_dts(ts, &obj.dts)
                obj.tzinfo = pytz.utc
        else:
            obj.value = _pydatetime_to_dts(ts, &obj.dts)
            obj.tzinfo = ts.tzinfo

        if obj.tzinfo is not None and not _is_utc(obj.tzinfo):
            offset = _get_utcoffset(obj.tzinfo, ts)
            obj.value -= _delta_to_nanoseconds(offset)

        if is_timestamp(ts):
            obj.value += ts.nanosecond
            obj.dts.ps = ts.nanosecond * 1000
        _check_dts_bounds(&obj.dts)
        return obj
    elif PyDate_Check(ts):
        # Keep the converter same as PyDateTime's
        ts = datetime.combine(ts, datetime_time())
        return convert_to_tsobject(ts, tz, None)
    else:
        raise ValueError("Cannot convert Period to Timestamp unambiguously. Use to_timestamp")

    if obj.value != NPY_NAT:
        _check_dts_bounds(&obj.dts)

    if tz is not None:
        _localize_tso(obj, tz)

    return obj

cdef inline void _localize_tso(_TSObject obj, object tz):
    '''
    Take a TSObject in UTC and localizes to timezone tz.
    '''
    if _is_utc(tz):
        obj.tzinfo = tz
    elif _is_tzlocal(tz):
        pandas_datetime_to_datetimestruct(obj.value, PANDAS_FR_ns, &obj.dts)
        dt = datetime(obj.dts.year, obj.dts.month, obj.dts.day, obj.dts.hour,
                      obj.dts.min, obj.dts.sec, obj.dts.us, tz)
        delta = int(total_seconds(_get_utcoffset(tz, dt))) * 1000000000
        pandas_datetime_to_datetimestruct(obj.value + delta,
                                          PANDAS_FR_ns, &obj.dts)
        obj.tzinfo = tz
    else:
        # Adjust datetime64 timestamp, recompute datetimestruct
        trans, deltas, typ = _get_dst_info(tz)

        pos = trans.searchsorted(obj.value, side='right') - 1


        # static/pytz/dateutil specific code
        if _is_fixed_offset(tz):
            # statictzinfo
            if len(deltas) > 0:
                pandas_datetime_to_datetimestruct(obj.value + deltas[0],
                                                  PANDAS_FR_ns, &obj.dts)
            else:
                pandas_datetime_to_datetimestruct(obj.value, PANDAS_FR_ns, &obj.dts)
            obj.tzinfo = tz
        elif _treat_tz_as_pytz(tz):
            inf = tz._transition_info[pos]
            pandas_datetime_to_datetimestruct(obj.value + deltas[pos],
                                              PANDAS_FR_ns, &obj.dts)
            obj.tzinfo = tz._tzinfos[inf]
        elif _treat_tz_as_dateutil(tz):
            pandas_datetime_to_datetimestruct(obj.value + deltas[pos],
                                              PANDAS_FR_ns, &obj.dts)
            obj.tzinfo = tz
        else:
            obj.tzinfo = tz


def _localize_pydatetime(object dt, object tz):
    '''
    Take a datetime/Timestamp in UTC and localizes to timezone tz.
    '''
    if tz is None:
        return dt
    elif isinstance(dt, Timestamp):
        return dt.tz_localize(tz)
    elif tz == 'UTC' or tz is UTC:
        return UTC.localize(dt)
    try:
        # datetime.replace with pytz may be incorrect result
        return tz.localize(dt)
    except AttributeError:
        return dt.replace(tzinfo=tz)


def get_timezone(tz):
    return _get_zone(tz)

cdef inline bint _is_utc(object tz):
    return tz is UTC or isinstance(tz, _dateutil_tzutc)

cdef inline object _get_zone(object tz):
    '''
    We need to do several things here:
    1/ Distinguish between pytz and dateutil timezones
    2/ Not be over-specific (e.g. US/Eastern with/without DST is same *zone* but a different tz object)
    3/ Provide something to serialize when we're storing a datetime object in pytables.

    We return a string prefaced with dateutil if it's a dateutil tz, else just the tz name. It needs to be a
    string so that we can serialize it with UJSON/pytables. maybe_get_tz (below) is the inverse of this process.
    '''
    if _is_utc(tz):
        return 'UTC'
    else:
        if _treat_tz_as_dateutil(tz):
            if '.tar.gz' in tz._filename:
                raise ValueError('Bad tz filename. Dateutil on python 3 on windows has a bug which causes tzfile._filename to be the same for all '
                                 'timezone files. Please construct dateutil timezones implicitly by passing a string like "dateutil/Europe/London" '
                                 'when you construct your pandas objects instead of passing a timezone object. See https://github.com/pydata/pandas/pull/7362')
            return 'dateutil/' + tz._filename
        else:
            # tz is a pytz timezone or unknown.
            try:
                zone = tz.zone
                if zone is None:
                    return tz
                return zone
            except AttributeError:
                return tz


cpdef inline object maybe_get_tz(object tz):
    '''
    (Maybe) Construct a timezone object from a string. If tz is a string, use it to construct a timezone object.
    Otherwise, just return tz.
    '''
    if isinstance(tz, string_types):
        if tz.startswith('dateutil/'):
            zone = tz[9:]
            tz = _dateutil_gettz(zone)
            # On Python 3 on Windows, the filename is not always set correctly.
            if isinstance(tz, _dateutil_tzfile) and '.tar.gz' in tz._filename:
                tz._filename = zone
        else:
            tz = pytz.timezone(tz)
    elif is_integer_object(tz):
        tz = pytz.FixedOffset(tz / 60)
    return tz



class OutOfBoundsDatetime(ValueError):
    pass

cdef inline _check_dts_bounds(pandas_datetimestruct *dts):
    cdef:
        bint error = False

    if dts.year <= 1677 and cmp_pandas_datetimestruct(dts, &_NS_MIN_DTS) == -1:
        error = True
    elif (
            dts.year >= 2262 and
            cmp_pandas_datetimestruct(dts, &_NS_MAX_DTS) == 1):
        error = True

    if error:
        fmt = '%d-%.2d-%.2d %.2d:%.2d:%.2d' % (dts.year, dts.month,
                                               dts.day, dts.hour,
                                               dts.min, dts.sec)

        raise OutOfBoundsDatetime('Out of bounds nanosecond timestamp: %s' % fmt)

# elif isinstance(ts, _Timestamp):
#     tmp = ts
#     obj.value = (<_Timestamp> ts).value
#     obj.dtval =
# elif isinstance(ts, object):
#     # If all else fails
#     obj.value = _dtlike_to_datetime64(ts, &obj.dts)
#     obj.dtval = _dts_to_pydatetime(&obj.dts)

def datetime_to_datetime64(ndarray[object] values):
    cdef:
        Py_ssize_t i, n = len(values)
        object val, inferred_tz = None
        ndarray[int64_t] iresult
        pandas_datetimestruct dts
        _TSObject _ts

    result = np.empty(n, dtype='M8[ns]')
    iresult = result.view('i8')
    for i in range(n):
        val = values[i]
        if _checknull_with_nat(val):
            iresult[i] = iNaT
        elif PyDateTime_Check(val):
            if val.tzinfo is not None:
                if inferred_tz is not None:
                    if _get_zone(val.tzinfo) != inferred_tz:
                        raise ValueError('Array must be all same time zone')
                else:
                    inferred_tz = _get_zone(val.tzinfo)

                _ts = convert_to_tsobject(val, None, None)
                iresult[i] = _ts.value
                _check_dts_bounds(&_ts.dts)
            else:
                if inferred_tz is not None:
                    raise ValueError('Cannot mix tz-aware with tz-naive values')
                iresult[i] = _pydatetime_to_dts(val, &dts)
                _check_dts_bounds(&dts)
        else:
            raise TypeError('Unrecognized value type: %s' % type(val))

    return result, inferred_tz

_not_datelike_strings = set(['a','A','m','M','p','P','t','T'])

def _does_string_look_like_datetime(date_string):
    if date_string.startswith('0'):
        # Strings starting with 0 are more consistent with a
        # date-like string than a number
        return True

    try:
        if float(date_string) < 1000:
            return False
    except ValueError:
        pass

    if date_string in _not_datelike_strings:
        return False

    return True

def parse_datetime_string(date_string, **kwargs):
    if not _does_string_look_like_datetime(date_string):
        raise ValueError('Given date string not likely a datetime.')

    dt = parse_date(date_string, **kwargs)
    return dt

def array_to_datetime(ndarray[object] values, raise_=False, dayfirst=False,
                      format=None, utc=None, coerce=False, unit=None):
    cdef:
        Py_ssize_t i, n = len(values)
        object val, py_dt
        ndarray[int64_t] iresult
        ndarray[object] oresult
        pandas_datetimestruct dts
        bint utc_convert = bool(utc), seen_integer=0, seen_datetime=0
        _TSObject _ts
        int64_t m = cast_from_unit(None,unit)
        int out_local = 0, out_tzoffset = 0

    try:
        result = np.empty(n, dtype='M8[ns]')
        iresult = result.view('i8')
        for i in range(n):
            val = values[i]
            if _checknull_with_nat(val):
                iresult[i] = iNaT
            elif PyDateTime_Check(val):
                seen_datetime=1
                if val.tzinfo is not None:
                    if utc_convert:
                        _ts = convert_to_tsobject(val, None, unit)
                        iresult[i] = _ts.value
                        try:
                            _check_dts_bounds(&_ts.dts)
                        except ValueError:
                            if coerce:
                                iresult[i] = iNaT
                                continue
                            raise
                    else:
                        raise ValueError('Tz-aware datetime.datetime cannot '
                                         'be converted to datetime64 unless '
                                         'utc=True')
                else:
                    iresult[i] = _pydatetime_to_dts(val, &dts)
                    if is_timestamp(val):
                        iresult[i] += (<_Timestamp>val).nanosecond
                    try:
                        _check_dts_bounds(&dts)
                    except ValueError:
                        if coerce:
                            iresult[i] = iNaT
                            continue
                        raise
            elif PyDate_Check(val):
                iresult[i] = _date_to_datetime64(val, &dts)
                try:
                    _check_dts_bounds(&dts)
                    seen_datetime=1
                except ValueError:
                    if coerce:
                        iresult[i] = iNaT
                        continue
                    raise
            elif util.is_datetime64_object(val):
                if val is np_NaT or val.view('i8') == iNaT:
                    iresult[i] = iNaT
                else:
                    try:
                        iresult[i] = _get_datetime64_nanos(val)
                        seen_datetime=1
                    except ValueError:
                        if coerce:
                            iresult[i] = iNaT
                            continue
                        raise

            # if we are coercing, dont' allow integers
            elif is_integer_object(val) and not coerce:
                if val == iNaT:
                    iresult[i] = iNaT
                else:
                    iresult[i] = val*m
                    seen_integer=1
            elif is_float_object(val) and not coerce:
                if val != val or val == iNaT:
                    iresult[i] = iNaT
                else:
                    iresult[i] = cast_from_unit(val,unit)
                    seen_integer=1
            else:
                try:
                    if len(val) == 0:
                        iresult[i] = iNaT
                        continue

                    elif val in _nat_strings:
                        iresult[i] = iNaT
                        continue

                    _string_to_dts(val, &dts, &out_local, &out_tzoffset)
                    value = pandas_datetimestruct_to_datetime(PANDAS_FR_ns, &dts)
                    if out_local == 1:
                        tz = pytz.FixedOffset(out_tzoffset)
                        value = tz_convert_single(value, tz, 'UTC')
                    iresult[i] = value
                    _check_dts_bounds(&dts)
                except ValueError:
                    try:
                        py_dt = parse_datetime_string(val, dayfirst=dayfirst)
                    except Exception:
                        if coerce:
                            iresult[i] = iNaT
                            continue
                        raise TypeError

                    try:
                        _ts = convert_to_tsobject(py_dt, None, None)
                        iresult[i] = _ts.value
                    except ValueError:
                        if coerce:
                            iresult[i] = iNaT
                            continue
                        raise
                except:
                    if coerce:
                        iresult[i] = iNaT
                        continue
                    raise

        # don't allow mixed integers and datetime like
        # higher levels can catch and coerce to object, for
        # example
        if seen_integer and seen_datetime:
            raise ValueError("mixed datetimes and integers in passed array")

        return result
    except OutOfBoundsDatetime:
        if raise_:
            raise

        oresult = np.empty(n, dtype=object)
        for i in range(n):
            val = values[i]

            # set as nan if is even a datetime NaT
            if _checknull_with_nat(val):
                oresult[i] = np.nan
            elif util.is_datetime64_object(val):
                if val is np_NaT or val.view('i8') == iNaT:
                    oresult[i] = np.nan
                else:
                    oresult[i] = val.item()
            else:
                oresult[i] = val
        return oresult
    except TypeError:
        oresult = np.empty(n, dtype=object)

        for i in range(n):
            val = values[i]
            if _checknull_with_nat(val):
                oresult[i] = val
            elif util.is_string_object(val):
                if len(val) == 0:
                    # TODO: ??
                    oresult[i] = 'NaT'
                    continue
                try:
                    oresult[i] = parse_datetime_string(val, dayfirst=dayfirst)
                    _pydatetime_to_dts(oresult[i], &dts)
                    _check_dts_bounds(&dts)
                except Exception:
                    if raise_:
                        raise
                    return values
                    # oresult[i] = val
            else:
                if raise_:
                    raise
                return values

        return oresult

# Similar to Timestamp/datetime, this is a construction requirement for timedeltas
# we need to do object instantiation in python
# This will serve as a C extension type that
# shadows the python class, where we do any heavy lifting.

cdef class _Timedelta(timedelta):

    cdef readonly:
        int64_t value     # nanoseconds
        object freq       # frequency reference
        bint is_populated # are my components populated
        int64_t _sign, _d, _h, _m, _s, _ms, _us, _ns

    def __hash__(_Timedelta self):
        return hash(self.value)

    def __richcmp__(_Timedelta self, object other, int op):
        cdef:
            _Timedelta ots
            int ndim

        if isinstance(other, _Timedelta):
            if isinstance(other, _NaT):
                return _cmp_nat_dt(other, self, _reverse_ops[op])
            ots = other
        elif isinstance(other, timedelta):
            ots = Timedelta(other)
        else:
            ndim = getattr(other, _NDIM_STRING, -1)

            if ndim != -1:
                if ndim == 0:
                    if isinstance(other, np.timedelta64):
                        other = Timedelta(other)
                    else:
                        if op == Py_EQ:
                            return False
                        elif op == Py_NE:
                            return True

                        # only allow ==, != ops
                        raise TypeError('Cannot compare type %r with type %r' %
                                        (type(self).__name__,
                                         type(other).__name__))
                return PyObject_RichCompare(other, self, _reverse_ops[op])
            else:
                if op == Py_EQ:
                    return False
                elif op == Py_NE:
                    return True
                raise TypeError('Cannot compare type %r with type %r' %
                                (type(self).__name__, type(other).__name__))

        return _cmp_scalar(self.value, ots.value, op)

    def _ensure_components(_Timedelta self):
        """
        compute the components
        """
        cdef int64_t sfrac, ifrac, ivalue = self.value
        cdef float64_t frac

        if self.is_populated:
           return

        # put frac in seconds
        frac   = float(ivalue)/1e9
        if frac < 0:
           self._sign = -1

           # even fraction
           if int(-frac/86400) != -frac/86400.0:
               self._d = int(-frac/86400.0+1)
               frac += 86400*self._d
           else:
               frac = -frac
        else:
           self._sign = 1
           self._d = 0

        if frac >= 86400:
           self._d += int(frac / 86400)
           frac   -= self._d * 86400

        if frac >= 3600:
           self._h  = int(frac / 3600)
           frac    -= self._h * 3600
        else:
           self._h = 0

        if frac >= 60:
           self._m = int(frac / 60)
           frac   -= self._m * 60
        else:
           self._m = 0

        if frac >= 0:
           self._s = int(frac)
           frac   -= self._s
        else:
           self._s = 0

        if frac != 0:

           # reset so we don't lose precision
           sfrac = int((self._h*3600 + self._m*60 + self._s)*1e9)
           if self._sign < 0:
               ifrac = ivalue + self._d*DAY_NS - sfrac
           else:
               ifrac = ivalue - (self._d*DAY_NS + sfrac)

           self._ms = int(ifrac/1e6)
           ifrac -= self._ms*1000*1000
           self._us = int(ifrac/1e3)
           ifrac -= self._us*1000
           self._ns = ifrac
        else:
           self._ms = 0
           self._us = 0
           self._ns = 0

        self.is_populated = 1

    cpdef timedelta to_pytimedelta(_Timedelta self):
        """
        return an actual datetime.timedelta object
        note: we lose nanosecond resolution if any
        """
        return timedelta(microseconds=int(self.value)/1000)

# components named tuple
Components = collections.namedtuple('Components',['days','hours','minutes','seconds','milliseconds','microseconds','nanoseconds'])

# Python front end to C extension type _Timedelta
# This serves as the box for timedelta64
class Timedelta(_Timedelta):
    """
    Represents a duration, the difference between two dates or times.

    Timedelta is the pandas equivalent of python's ``datetime.timedelta``
    and is interchangable with it in most cases.

    Parameters
    ----------
    value : Timedelta, timedelta, np.timedelta64, string, or integer
    unit : string, [D,h,m,s,ms,us,ns]
        Denote the unit of the input, if input is an integer. Default 'ns'.
    days, seconds, microseconds, milliseconds, minutes, hours, weeks : numeric, optional
        Values for construction in compat with datetime.timedelta.
        np ints and floats will be coereced to python ints and floats.

    Notes
    -----
    The ``.value`` attribute is always in ns.

    """

    def __new__(cls, object value=None, unit=None, **kwargs):
        cdef _Timedelta td_base

        if value is None:
            if not len(kwargs):
                raise ValueError("cannot construct a TimeDelta without a value/unit or descriptive keywords (days,seconds....)")

            def _to_py_int_float(v):
                if is_integer_object(v):
                    return int(v)
                elif is_float_object(v):
                    return float(v)
                raise TypeError("Invalid type {0}. Must be int or float.".format(type(v)))

            kwargs = dict([ (k, _to_py_int_float(v)) for k, v in iteritems(kwargs) ])

            try:
                value = timedelta(**kwargs)
            except TypeError as e:
                raise ValueError("cannot construct a TimeDelta from the passed arguments, allowed keywords are "
                                 "[days, seconds, microseconds, milliseconds, minutes, hours, weeks]")

        if isinstance(value, Timedelta):
            value = value.value
        elif util.is_string_object(value):
            from pandas import to_timedelta
            value = to_timedelta(value,unit=unit,box=False)
        elif isinstance(value, timedelta):
            value = convert_to_timedelta64(value,'ns',False)
        elif isinstance(value, np.timedelta64):
            if unit is not None:
                value = value.astype('timedelta64[{0}]'.format(unit))
            value = value.astype('timedelta64[ns]')
        elif hasattr(value,'delta'):
            value = np.timedelta64(_delta_to_nanoseconds(value.delta),'ns')
        elif is_integer_object(value) or util.is_float_object(value):
            # unit=None is de-facto 'ns'
            value = convert_to_timedelta64(value,unit,False)
        elif _checknull_with_nat(value):
            return NaT
        else:
            raise ValueError("Value must be Timedelta, string, integer, float, timedelta or convertible")

        if isinstance(value, np.timedelta64):
            value = value.view('i8')

        # nat
        if value == NPY_NAT:
            return NaT

        # make timedelta happy
        td_base = _Timedelta.__new__(cls, microseconds=int(value)/1000)
        td_base.value = value
        td_base.is_populated = 0
        return td_base

    @property
    def delta(self):
        """ return out delta in ns (for internal compat) """
        return self.value

    @property
    def asm8(self):
        """ return a numpy timedelta64 array view of myself """
        return np.int64(self.value).view('m8[ns]')

    @property
    def resolution(self):
        """ return a string representing the lowest resolution that we have """

        self._ensure_components()
        if self._ns:
           return "ns"
        elif self._us:
           return "us"
        elif self._ms:
           return "ms"
        elif self._s:
           return "s"
        elif self._m:
           return "m"
        elif self._h:
           return "h"
        elif self._d:
           return "D"
        raise ValueError("invalid resolution")

    def round(self, reso):
        """
        return a new Timedelta rounded to this resolution

        Parameters
        ----------
        reso : a string indicating the rouding resolution, accepting values
           d,h,m,s,ms,us

        """
        cdef int64_t frac, value = np.abs(self.value)

        self._ensure_components()
        frac = int(self._ms*1e6 + self._us*1e3+ self._ns)
        if reso == 'us':
           value -= self._ns
        elif reso == 'ms':
           value -= self._us*1000 + self._ns
        elif reso == 's':
           value -= frac
        elif reso == 'm':
           value -= int(self._s*1e9) + frac
        elif reso == 'h':
           value -= int((60*self._m + self._s)*1e9) + frac
        elif reso == 'd' or reso == 'D':
           value -= int((3600*self._h + 60*self._m + self._s)*1e9) + frac
        else:
           raise ValueError("invalid resolution")

        if self._sign < 0:
           value *= -1
        return Timedelta(value,unit='ns')

    def _repr_base(self, format=None):
        """

        Parameters
        ----------
        format : None|all|even_day|sub_day|long

        Returns
        -------
        converted : string of a Timedelta

        """
        cdef object sign_pretty, sign2_pretty, seconds_pretty, subs

        self._ensure_components()

        if self._sign < 0:
           sign_pretty = "-"
           sign2_pretty = " +"
        else:
           sign_pretty = ""
           sign2_pretty = " "

        # show everything
        if format == 'all':
           seconds_pretty = "%02d.%03d%03d%03d" % (self._s, self._ms, self._us, self._ns)
           return "%s%d days%s%02d:%02d:%s" % (sign_pretty, self._d, sign2_pretty, self._h, self._m, seconds_pretty)

        # by default not showing nano
        if self._ms or self._us or self._ns:
           seconds_pretty = "%02d.%03d%03d" % (self._s, self._ms, self._us)
        else:
           seconds_pretty = "%02d" % self._s

        # if we have a partial day
        subs = self._h or self._m or self._s or self._ms or self._us or self._ns

        if format == 'even_day':
           if not subs:
               return "%s%d days" % (sign_pretty, self._d)

        elif format == 'sub_day':
           if not self._d:

               # degenerate, don't need the extra space
               if self._sign > 0:
                   sign2_pretty = ""
               return "%s%s%02d:%02d:%s" % (sign_pretty, sign2_pretty, self._h, self._m, seconds_pretty)

        if subs or format=='long':
           return "%s%d days%s%02d:%02d:%s" % (sign_pretty, self._d, sign2_pretty, self._h, self._m, seconds_pretty)
        return "%s%d days" % (sign_pretty, self._d)


    def __repr__(self):
        return "Timedelta('{0}')".format(self._repr_base(format='long'))
    def __str__(self):
        return self._repr_base(format='long')

    @property
    def components(self):
        """ Return a Components NamedTuple-like """
        self._ensure_components()
        if self._sign < 0:
           return Components(-self._d,self._h,self._m,self._s,self._ms,self._us,self._ns)

        # return the named tuple
        return Components(self._d,self._h,self._m,self._s,self._ms,self._us,self._ns)

    @property
    def days(self):
        """ The days for the Timedelta """
        self._ensure_components()
        if self._sign < 0:
            return -1*self._d
        return self._d

    @property
    def hours(self):
        """ The hours for the Timedelta """
        self._ensure_components()
        return self._h

    @property
    def minutes(self):
        """ The minutes for the Timedelta """
        self._ensure_components()
        return self._m

    @property
    def seconds(self):
        """ The seconds for the Timedelta """
        self._ensure_components()
        return self._s

    @property
    def milliseconds(self):
        """ The milliseconds for the Timedelta """
        self._ensure_components()
        return self._ms

    @property
    def microseconds(self):
        """ The microseconds for the Timedelta """
        self._ensure_components()
        return self._us

    @property
    def nanoseconds(self):
        """ The nanoseconds for the Timedelta """
        self._ensure_components()
        return self._ns

    def __setstate__(self, state):
        (value) = state
        self.value = value

    def __reduce__(self):
        object_state = self.value,
        return (Timedelta, object_state)

    def view(self, dtype):
        """ array view compat """
        return np.timedelta64(self.value).view(dtype)

    def to_timedelta64(self):
        """ Returns a numpy.timedelta64 object with 'ns' precision """
        return np.timedelta64(self.value, 'ns')

    def _validate_ops_compat(self, other):
        # return True if we are compat with operating
        if _checknull_with_nat(other):
             return True
        elif isinstance(other, (Timedelta, timedelta, np.timedelta64)):
             return True
        elif util.is_string_object(other):
             return True
        elif hasattr(other,'delta'):
             return True
        return False

    # higher than np.ndarray and np.matrix
    __array_priority__ = 100

    def _binary_op_method_timedeltalike(op, name):
        # define a binary operation that only works if the other argument is
        # timedelta like or an array of timedeltalike
        def f(self, other):
            # an offset
            if hasattr(other, 'delta') and not isinstance(other, Timedelta):
                return op(self, other.delta)

            # a datetimelike
            if (isinstance(other, (datetime, np.datetime64))
                    and not isinstance(other, (Timestamp, NaTType))):
                return op(self, Timestamp(other))

            # nd-array like
            if hasattr(other, 'dtype'):
                if other.dtype.kind not in ['m', 'M']:
                    # raise rathering than letting numpy return wrong answer
                    return NotImplemented
                return op(self.to_timedelta64(), other)

            if not self._validate_ops_compat(other):
                return NotImplemented

            other = Timedelta(other)
            if other is NaT:
                return NaT
            return Timedelta(op(self.value, other.value), unit='ns')
        f.__name__ = name
        return f

    __add__ = _binary_op_method_timedeltalike(lambda x, y: x + y, '__add__')
    __radd__ = _binary_op_method_timedeltalike(lambda x, y: x + y, '__radd__')
    __sub__ = _binary_op_method_timedeltalike(lambda x, y: x - y, '__sub__')
    __rsub__ = _binary_op_method_timedeltalike(lambda x, y: y - x, '__rsub__')

    def __mul__(self, other):

        # nd-array like
        if hasattr(other, 'dtype'):
            return other * self.to_timedelta64()

        if other is NaT:
            return NaT

        # only integers allowed
        if not is_integer_object(other):
           return NotImplemented

        return Timedelta(other*self.value, unit='ns')

    __rmul__ = __mul__

    def __truediv__(self, other):

        if hasattr(other, 'dtype'):
            return self.to_timedelta64() / other

        # pure integers
        if is_integer_object(other):
           return Timedelta(self.value/other, unit='ns')

        if not self._validate_ops_compat(other):
            return NotImplemented

        other = Timedelta(other)
        if other is NaT:
            return NaT
        return self.value/float(other.value)

    def __rtruediv__(self, other):
        if hasattr(other, 'dtype'):
            return other / self.to_timedelta64()

        if not self._validate_ops_compat(other):
            return NotImplemented

        other = Timedelta(other)
        if other is NaT:
            return NaT
        return float(other.value) / self.value

    if not PY3:
       __div__ = __truediv__
       __rdiv__ = __rtruediv__

    def _not_implemented(self, *args, **kwargs):
        return NotImplemented

    __floordiv__  = _not_implemented
    __rfloordiv__ = _not_implemented

    def _op_unary_method(func, name):

        def f(self):
            return Timedelta(func(self.value), unit='ns')
        f.__name__ = name
        return f

    __inv__ = _op_unary_method(lambda x: -x, '__inv__')
    __neg__ = _op_unary_method(lambda x: -x, '__neg__')
    __pos__ = _op_unary_method(lambda x: x, '__pos__')
    __abs__ = _op_unary_method(lambda x: abs(x), '__abs__')

cdef PyTypeObject* td_type = <PyTypeObject*> Timedelta

cdef inline bint is_timedelta(object o):
    return Py_TYPE(o) == td_type # isinstance(o, Timedelta)

def array_to_timedelta64(ndarray[object] values, unit='ns', coerce=False):
    """ convert an ndarray to an array of ints that are timedeltas
        force conversion if coerce = True,
        else will raise if cannot convert """
    cdef:
        Py_ssize_t i, n
        ndarray[int64_t] iresult

    n = values.shape[0]
    result = np.empty(n, dtype='m8[ns]')
    iresult = result.view('i8')

    for i in range(n):
        result[i] = convert_to_timedelta64(values[i], unit, coerce)
    return iresult

def convert_to_timedelta(object ts, object unit='ns', coerce=False):
    return convert_to_timedelta64(ts, unit, coerce)

cdef inline convert_to_timedelta64(object ts, object unit, object coerce):
    """
    Convert an incoming object to a timedelta64 if possible

    Handle these types of objects:
        - timedelta/Timedelta
        - timedelta64
        - an offset
        - np.int64 (with unit providing a possible modifier)
        - None/NaT

    if coerce, set a non-valid value to NaT

    Return a ns based int64

    # kludgy here until we have a timedelta scalar
    # handle the numpy < 1.7 case
    """
    if _checknull_with_nat(ts):
        return np.timedelta64(iNaT)
    elif isinstance(ts, Timedelta):
        # already in the proper format
        ts = np.timedelta64(ts.value)
    elif util.is_datetime64_object(ts):
        # only accept a NaT here
        if ts.astype('int64') == iNaT:
            return np.timedelta64(iNaT)
    elif isinstance(ts, np.timedelta64):
        ts = ts.astype("m8[{0}]".format(unit.lower()))
    elif is_integer_object(ts):
        if ts == iNaT:
            return np.timedelta64(iNaT)
        else:
            if util.is_array(ts):
                ts = ts.astype('int64').item()
            if unit in ['Y','M','W']:
                ts = np.timedelta64(ts, unit)
            else:
                ts = cast_from_unit(ts, unit)
                ts = np.timedelta64(ts)
    elif is_float_object(ts):
        if util.is_array(ts):
            ts = ts.astype('int64').item()
        if unit in ['Y','M','W']:
            ts = np.timedelta64(int(ts), unit)
        else:
            ts = cast_from_unit(ts, unit)
            ts = np.timedelta64(ts)
    elif util.is_string_object(ts):
        if ts in _nat_strings or coerce:
            return np.timedelta64(iNaT)
        else:
            raise ValueError("Invalid type for timedelta scalar: %s" % type(ts))
    elif hasattr(ts,'delta'):
        ts = np.timedelta64(_delta_to_nanoseconds(ts),'ns')

    if isinstance(ts, timedelta):
        ts = np.timedelta64(ts)
    elif not isinstance(ts, np.timedelta64):
        if coerce:
            return np.timedelta64(iNaT)
        raise ValueError("Invalid type for timedelta scalar: %s" % type(ts))
    return ts.astype('timedelta64[ns]')

def array_strptime(ndarray[object] values, object fmt, bint exact=True, bint coerce=False):
    """
    Parameters
    ----------
    values : ndarray of string-like objects
    fmt : string-like regex
    exact : matches must be exact if True, search if False
    coerce : if invalid values found, coerce to NaT
    """

    cdef:
        Py_ssize_t i, n = len(values)
        pandas_datetimestruct dts
        ndarray[int64_t] iresult
        int year, month, day, minute, hour, second, weekday, julian, tz
        int week_of_year, week_of_year_start
        int64_t us, ns
        object val, group_key, ampm, found
        dict found_key

    global _TimeRE_cache, _regex_cache
    with _cache_lock:
        if _getlang() != _TimeRE_cache.locale_time.lang:
            _TimeRE_cache = TimeRE()
            _regex_cache.clear()
        if len(_regex_cache) > _CACHE_MAX_SIZE:
            _regex_cache.clear()
        locale_time = _TimeRE_cache.locale_time
        format_regex = _regex_cache.get(fmt)
        if not format_regex:
            try:
                format_regex = _TimeRE_cache.compile(fmt)
            # KeyError raised when a bad format is found; can be specified as
            # \\, in which case it was a stray % but with a space after it
            except KeyError, err:
                bad_directive = err.args[0]
                if bad_directive == "\\":
                    bad_directive = "%"
                del err
                raise ValueError("'%s' is a bad directive in format '%s'" %
                                    (bad_directive, fmt))
            # IndexError only occurs when the format string is "%"
            except IndexError:
                raise ValueError("stray %% in format '%s'" % fmt)
            _regex_cache[fmt] = format_regex

    result = np.empty(n, dtype='M8[ns]')
    iresult = result.view('i8')

    dts.us = dts.ps = dts.as = 0

    cdef dict _parse_code_table = {
        'y': 0,
        'Y': 1,
        'm': 2,
        'B': 3,
        'b': 4,
        'd': 5,
        'H': 6,
        'I': 7,
        'M': 8,
        'S': 9,
        'f': 10,
        'A': 11,
        'a': 12,
        'w': 13,
        'j': 14,
        'U': 15,
        'W': 16,
        'Z': 17,
        'p': 18   # just an additional key, works only with I
    }
    cdef int parse_code

    for i in range(n):
        val = values[i]
        if util.is_string_object(val):
            if val in _nat_strings:
                iresult[i] = iNaT
                continue
        else:
            if _checknull_with_nat(val):
                iresult[i] = iNaT
                continue
            else:
                val = str(val)

        # exact matching
        if exact:
            found = format_regex.match(val)
            if not found:
                if coerce:
                    iresult[i] = iNaT
                    continue
                raise ValueError("time data %r does not match format %r (match)" %
                                 (values[i], fmt))
            if len(val) != found.end():
                if coerce:
                    iresult[i] = iNaT
                    continue
                raise ValueError("unconverted data remains: %s" %
                                  values[i][found.end():])

        # search
        else:
            found = format_regex.search(val)
            if not found:
                if coerce:
                    iresult[i] = iNaT
                    continue
                raise ValueError("time data %r does not match format %r (search)" %
                                 (values[i], fmt))

        year = 1900
        month = day = 1
        hour = minute = second = ns = us = 0
        tz = -1
        # Default to -1 to signify that values not known; not critical to have,
        # though
        week_of_year = -1
        week_of_year_start = -1
        # weekday and julian defaulted to -1 so as to signal need to calculate
        # values
        weekday = julian = -1
        found_dict = found.groupdict()
        for group_key in found_dict.iterkeys():
            # Directives not explicitly handled below:
            #   c, x, X
            #      handled by making out of other directives
            #   U, W
            #      worthless without day of the week
            parse_code = _parse_code_table[group_key]

            if parse_code == 0:
                year = int(found_dict['y'])
                # Open Group specification for strptime() states that a %y
                #value in the range of [00, 68] is in the century 2000, while
                #[69,99] is in the century 1900
                if year <= 68:
                    year += 2000
                else:
                    year += 1900
            elif parse_code == 1:
                year = int(found_dict['Y'])
            elif parse_code == 2:
                month = int(found_dict['m'])
            elif parse_code == 3:
            # elif group_key == 'B':
                month = locale_time.f_month.index(found_dict['B'].lower())
            elif parse_code == 4:
            # elif group_key == 'b':
                month = locale_time.a_month.index(found_dict['b'].lower())
            elif parse_code == 5:
            # elif group_key == 'd':
                day = int(found_dict['d'])
            elif parse_code == 6:
            # elif group_key == 'H':
                hour = int(found_dict['H'])
            elif parse_code == 7:
                hour = int(found_dict['I'])
                ampm = found_dict.get('p', '').lower()
                # If there was no AM/PM indicator, we'll treat this like AM
                if ampm in ('', locale_time.am_pm[0]):
                    # We're in AM so the hour is correct unless we're
                    # looking at 12 midnight.
                    # 12 midnight == 12 AM == hour 0
                    if hour == 12:
                        hour = 0
                elif ampm == locale_time.am_pm[1]:
                    # We're in PM so we need to add 12 to the hour unless
                    # we're looking at 12 noon.
                    # 12 noon == 12 PM == hour 12
                    if hour != 12:
                        hour += 12
            elif parse_code == 8:
                minute = int(found_dict['M'])
            elif parse_code == 9:
                second = int(found_dict['S'])
            elif parse_code == 10:
                s = found_dict['f']
                # Pad to always return nanoseconds
                s += "0" * (9 - len(s))
                us = long(s)
                ns = us % 1000
                us = us / 1000
            elif parse_code == 11:
                weekday = locale_time.f_weekday.index(found_dict['A'].lower())
            elif parse_code == 12:
                weekday = locale_time.a_weekday.index(found_dict['a'].lower())
            elif parse_code == 13:
                weekday = int(found_dict['w'])
                if weekday == 0:
                    weekday = 6
                else:
                    weekday -= 1
            elif parse_code == 14:
                julian = int(found_dict['j'])
            elif parse_code == 15 or parse_code == 16:
                week_of_year = int(found_dict[group_key])
                if group_key == 'U':
                    # U starts week on Sunday.
                    week_of_year_start = 6
                else:
                    # W starts week on Monday.
                    week_of_year_start = 0
            elif parse_code == 17:
                # Since -1 is default value only need to worry about setting tz
                # if it can be something other than -1.
                found_zone = found_dict['Z'].lower()
                for value, tz_values in enumerate(locale_time.timezone):
                    if found_zone in tz_values:
                        # Deal w/ bad locale setup where timezone names are the
                        # same and yet time.daylight is true; too ambiguous to
                        # be able to tell what timezone has daylight savings
                        if (time.tzname[0] == time.tzname[1] and
                           time.daylight and found_zone not in ("utc", "gmt")):
                            break
                        else:
                            tz = value
                            break
        # If we know the wk of the year and what day of that wk, we can figure
        # out the Julian day of the year.
        if julian == -1 and week_of_year != -1 and weekday != -1:
            week_starts_Mon = True if week_of_year_start == 0 else False
            julian = _calc_julian_from_U_or_W(year, week_of_year, weekday,
                                                week_starts_Mon)
        # Cannot pre-calculate datetime_date() since can change in Julian
        # calculation and thus could have different value for the day of the wk
        # calculation.
        if julian == -1:
            # Need to add 1 to result since first day of the year is 1, not 0.
            julian = datetime_date(year, month, day).toordinal() - \
                      datetime_date(year, 1, 1).toordinal() + 1
        else: # Assume that if they bothered to include Julian day it will
            # be accurate.
            datetime_result = datetime_date.fromordinal(
                (julian - 1) + datetime_date(year, 1, 1).toordinal())
            year = datetime_result.year
            month = datetime_result.month
            day = datetime_result.day
        if weekday == -1:
            weekday = datetime_date(year, month, day).weekday()

        dts.year = year
        dts.month = month
        dts.day = day
        dts.hour = hour
        dts.min = minute
        dts.sec = second
        dts.us = us
        dts.ps = ns * 1000

        iresult[i] = pandas_datetimestruct_to_datetime(PANDAS_FR_ns, &dts)
        try:
            _check_dts_bounds(&dts)
        except ValueError:
            if coerce:
                iresult[i] = iNaT
                continue
            raise

    return result


cdef inline _get_datetime64_nanos(object val):
    cdef:
        pandas_datetimestruct dts
        PANDAS_DATETIMEUNIT unit
        npy_datetime ival

    unit = get_datetime64_unit(val)
    if unit == 3:
        raise ValueError('NumPy 1.6.1 business freq not supported')

    ival = get_datetime64_value(val)

    if unit != PANDAS_FR_ns:
        pandas_datetime_to_datetimestruct(ival, unit, &dts)
        _check_dts_bounds(&dts)
        return pandas_datetimestruct_to_datetime(PANDAS_FR_ns, &dts)
    else:
        return ival

cpdef inline int64_t cast_from_unit(object ts, object unit) except? -1:
    """ return a casting of the unit represented to nanoseconds
        round the fractional part of a float to our precision, p """

    if unit == 'D' or unit == 'd':
        m = 1000000000L * 86400
        p = 6
    elif unit == 'h':
        m = 1000000000L * 3600
        p = 6
    elif unit == 'm':
        m = 1000000000L * 60
        p = 6
    elif unit == 's':
        m = 1000000000L
        p = 6
    elif unit == 'ms':
        m = 1000000L
        p = 3
    elif unit == 'us':
        m = 1000L
        p = 0
    elif unit == 'ns' or unit is None:
        m = 1L
        p = 0
    else:
        raise ValueError("cannot cast unit {0}".format(unit))

    # just give me the unit back
    if ts is None:
        return m

    # cast the unit, multiply base/frace separately
    # to avoid precision issues from float -> int
    base = <int64_t> ts
    frac = ts-base
    if p:
        frac = round(frac,p)
    return <int64_t> (base*m) + <int64_t> (frac*m)

def cast_to_nanoseconds(ndarray arr):
    cdef:
        Py_ssize_t i, n = arr.size
        ndarray[int64_t] ivalues, iresult
        PANDAS_DATETIMEUNIT unit
        pandas_datetimestruct dts

    shape = (<object> arr).shape

    ivalues = arr.view(np.int64).ravel()

    result = np.empty(shape, dtype='M8[ns]')
    iresult = result.ravel().view(np.int64)

    if len(iresult) == 0:
        return result

    unit = get_datetime64_unit(arr.flat[0])
    if unit == 3:
        raise ValueError('NumPy 1.6.1 business freq not supported')

    for i in range(n):
        pandas_datetime_to_datetimestruct(ivalues[i], unit, &dts)
        iresult[i] = pandas_datetimestruct_to_datetime(PANDAS_FR_ns, &dts)
        _check_dts_bounds(&dts)

    return result

#----------------------------------------------------------------------
# Conversion routines


def pydt_to_i8(object pydt):
    '''
    Convert to int64 representation compatible with numpy datetime64; converts
    to UTC
    '''
    cdef:
        _TSObject ts

    ts = convert_to_tsobject(pydt, None, None)

    return ts.value

def i8_to_pydt(int64_t i8, object tzinfo = None):
    '''
    Inverse of pydt_to_i8
    '''
    return Timestamp(i8)

#----------------------------------------------------------------------
# time zone conversion helpers

try:
    import pytz
    UTC = pytz.utc
    have_pytz = True
except:
    have_pytz = False

def tz_convert(ndarray[int64_t] vals, object tz1, object tz2):
    cdef:
        ndarray[int64_t] utc_dates, result, trans, deltas
        Py_ssize_t i, pos, n = len(vals)
        int64_t v, offset
        pandas_datetimestruct dts
        Py_ssize_t trans_len

    if not have_pytz:
        import pytz

    if len(vals) == 0:
        return np.array([], dtype=np.int64)

    # Convert to UTC

    if _get_zone(tz1) != 'UTC':
        utc_dates = np.empty(n, dtype=np.int64)
        if _is_tzlocal(tz1):
            for i in range(n):
                v = vals[i]
                pandas_datetime_to_datetimestruct(v, PANDAS_FR_ns, &dts)
                dt = datetime(dts.year, dts.month, dts.day, dts.hour,
                              dts.min, dts.sec, dts.us, tz1)
                delta = (int(total_seconds(_get_utcoffset(tz1, dt)))
                         * 1000000000)
                utc_dates[i] = v - delta
        else:
            trans, deltas, typ = _get_dst_info(tz1)

            trans_len = len(trans)
            pos = trans.searchsorted(vals[0]) - 1
            if pos < 0:
                raise ValueError('First time before start of DST info')

            offset = deltas[pos]
            for i in range(n):
                v = vals[i]
                while pos + 1 < trans_len and v >= trans[pos + 1]:
                    pos += 1
                    offset = deltas[pos]
                utc_dates[i] = v - offset
    else:
        utc_dates = vals

    if _get_zone(tz2) == 'UTC':
        return utc_dates

    result = np.empty(n, dtype=np.int64)
    if _is_tzlocal(tz2):
        for i in range(n):
            v = utc_dates[i]
            pandas_datetime_to_datetimestruct(v, PANDAS_FR_ns, &dts)
            dt = datetime(dts.year, dts.month, dts.day, dts.hour,
                          dts.min, dts.sec, dts.us, tz2)
            delta = int(total_seconds(_get_utcoffset(tz2, dt))) * 1000000000
            result[i] = v + delta
            return result

    # Convert UTC to other timezone
    trans, deltas, typ = _get_dst_info(tz2)
    trans_len = len(trans)

    pos = trans.searchsorted(utc_dates[0]) - 1
    if pos < 0:
        raise ValueError('First time before start of DST info')

    # TODO: this assumed sortedness :/
    offset = deltas[pos]
    for i in range(n):
        v = utc_dates[i]
        if vals[i] == NPY_NAT:
            result[i] = vals[i]
        else:
            while pos + 1 < trans_len and v >= trans[pos + 1]:
                pos += 1
                offset = deltas[pos]
            result[i] = v + offset
    return result

def tz_convert_single(int64_t val, object tz1, object tz2):
    cdef:
        ndarray[int64_t] trans, deltas
        Py_ssize_t pos
        int64_t v, offset, utc_date
        pandas_datetimestruct dts

    if not have_pytz:
        import pytz

    if val == NPY_NAT:
        return val

    # Convert to UTC
    if _is_tzlocal(tz1):
        pandas_datetime_to_datetimestruct(val, PANDAS_FR_ns, &dts)
        dt = datetime(dts.year, dts.month, dts.day, dts.hour,
                      dts.min, dts.sec, dts.us, tz1)
        delta = int(total_seconds(_get_utcoffset(tz1, dt))) * 1000000000
        utc_date = val - delta
    elif _get_zone(tz1) != 'UTC':
        trans, deltas, typ = _get_dst_info(tz1)
        pos = trans.searchsorted(val, side='right') - 1
        if pos < 0:
            raise ValueError('First time before start of DST info')
        offset = deltas[pos]
        utc_date = val - offset
    else:
        utc_date = val

    if _get_zone(tz2) == 'UTC':
        return utc_date
    if _is_tzlocal(tz2):
        pandas_datetime_to_datetimestruct(val, PANDAS_FR_ns, &dts)
        dt = datetime(dts.year, dts.month, dts.day, dts.hour,
                      dts.min, dts.sec, dts.us, tz2)
        delta = int(total_seconds(_get_utcoffset(tz2, dt))) * 1000000000
        return utc_date + delta
    # Convert UTC to other timezone
    trans, deltas, typ = _get_dst_info(tz2)

    pos = trans.searchsorted(utc_date, side='right') - 1
    if pos < 0:
        raise ValueError('First time before start of DST info')

    offset = deltas[pos]
    return utc_date + offset

# Timezone data caches, key is the pytz string or dateutil file name.
dst_cache = {}

cdef inline bint _treat_tz_as_pytz(object tz):
    return hasattr(tz, '_utc_transition_times') and hasattr(tz, '_transition_info')

cdef inline bint _treat_tz_as_dateutil(object tz):
    return hasattr(tz, '_trans_list') and hasattr(tz, '_trans_idx')


def _p_tz_cache_key(tz):
    ''' Python interface for cache function to facilitate testing.'''
    return _tz_cache_key(tz)


cdef inline object _tz_cache_key(object tz):
    """
    Return the key in the cache for the timezone info object or None if unknown.

    The key is currently the tz string for pytz timezones, the filename for dateutil timezones.

    Notes
    =====
    This cannot just be the hash of a timezone object. Unfortunately, the hashes of two dateutil tz objects
    which represent the same timezone are not equal (even though the tz objects will compare equal and
    represent the same tz file).
    Also, pytz objects are not always hashable so we use str(tz) instead.
    """
    if isinstance(tz, _pytz_BaseTzInfo):
        return tz.zone
    elif isinstance(tz, _dateutil_tzfile):
        if '.tar.gz' in tz._filename:
            raise ValueError('Bad tz filename. Dateutil on python 3 on windows has a bug which causes tzfile._filename to be the same for all '
                             'timezone files. Please construct dateutil timezones implicitly by passing a string like "dateutil/Europe/London" '
                             'when you construct your pandas objects instead of passing a timezone object. See https://github.com/pydata/pandas/pull/7362')
        return 'dateutil' + tz._filename
    else:
        return None


cdef object _get_dst_info(object tz):
    """
    return a tuple of :
      (UTC times of DST transitions,
       UTC offsets in microseconds corresponding to DST transitions,
       string of type of transitions)

    """
    cache_key = _tz_cache_key(tz)
    if cache_key is None:
        num = int(total_seconds(_get_utcoffset(tz, None))) * 1000000000
        return (np.array([NPY_NAT + 1], dtype=np.int64),
                np.array([num], dtype=np.int64),
                None)

    if cache_key not in dst_cache:
        if _treat_tz_as_pytz(tz):
            trans = np.array(tz._utc_transition_times, dtype='M8[ns]')
            trans = trans.view('i8')
            try:
                if tz._utc_transition_times[0].year == 1:
                    trans[0] = NPY_NAT + 1
            except Exception:
                pass
            deltas = _unbox_utcoffsets(tz._transition_info)
            typ = 'pytz'

        elif _treat_tz_as_dateutil(tz):
            if len(tz._trans_list):
                # get utc trans times
                trans_list = _get_utc_trans_times_from_dateutil_tz(tz)
                trans = np.hstack([np.array([0], dtype='M8[s]'), # place holder for first item
                                  np.array(trans_list, dtype='M8[s]')]).astype('M8[ns]')  # all trans listed
                trans = trans.view('i8')
                trans[0] = NPY_NAT + 1

                # deltas
                deltas = np.array([v.offset for v in (tz._ttinfo_before,) + tz._trans_idx], dtype='i8')  # + (tz._ttinfo_std,)
                deltas *= 1000000000
                typ = 'dateutil'

            elif _is_fixed_offset(tz):
                trans = np.array([NPY_NAT + 1], dtype=np.int64)
                deltas = np.array([tz._ttinfo_std.offset], dtype='i8') * 1000000000
                typ = 'fixed'
            else:
                trans = np.array([], dtype='M8[ns]')
                deltas = np.array([], dtype='i8')
                typ = None


        else:
            # static tzinfo
            trans = np.array([NPY_NAT + 1], dtype=np.int64)
            num = int(total_seconds(_get_utcoffset(tz, None))) * 1000000000
            deltas = np.array([num], dtype=np.int64)
            typ = 'static'

        dst_cache[cache_key] = (trans, deltas, typ)

    return dst_cache[cache_key]

cdef object _get_utc_trans_times_from_dateutil_tz(object tz):
    '''
    Transition times in dateutil timezones are stored in local non-dst time. This code
    converts them to UTC. It's the reverse of the code in dateutil.tz.tzfile.__init__.
    '''
    new_trans = list(tz._trans_list)
    last_std_offset = 0
    for i, (trans, tti) in enumerate(zip(tz._trans_list, tz._trans_idx)):
        if not tti.isdst:
            last_std_offset = tti.offset
        new_trans[i] = trans - last_std_offset
    return new_trans

def tot_seconds(td):
    return total_seconds(td)

cpdef ndarray _unbox_utcoffsets(object transinfo):
    cdef:
        Py_ssize_t i, sz
        ndarray[int64_t] arr

    sz = len(transinfo)
    arr = np.empty(sz, dtype='i8')

    for i in range(sz):
        arr[i] = int(total_seconds(transinfo[i][0])) * 1000000000

    return arr


@cython.boundscheck(False)
@cython.wraparound(False)
def tz_localize_to_utc(ndarray[int64_t] vals, object tz, object ambiguous=None):
    """
    Localize tzinfo-naive DateRange to given time zone (using pytz). If
    there are ambiguities in the values, raise AmbiguousTimeError.

    Returns
    -------
    localized : DatetimeIndex
    """
    cdef:
        ndarray[int64_t] trans, deltas, idx_shifted
        Py_ssize_t i, idx, pos, ntrans, n = len(vals)
        int64_t *tdata
        int64_t v, left, right
        ndarray[int64_t] result, result_a, result_b, dst_hours
        pandas_datetimestruct dts
        bint infer_dst = False, is_dst = False, fill = False

    # Vectorized version of DstTzInfo.localize

    if not have_pytz:
        raise Exception("Could not find pytz module")

    if tz == UTC or tz is None:
        return vals

    result = np.empty(n, dtype=np.int64)

    if _is_tzlocal(tz):
        for i in range(n):
            v = vals[i]
            pandas_datetime_to_datetimestruct(v, PANDAS_FR_ns, &dts)
            dt = datetime(dts.year, dts.month, dts.day, dts.hour,
                          dts.min, dts.sec, dts.us, tz)
            delta = int(total_seconds(_get_utcoffset(tz, dt))) * 1000000000
            result[i] = v - delta
        return result

    if isinstance(ambiguous, string_types):
        if ambiguous == 'infer':
            infer_dst = True
        elif ambiguous == 'NaT':
            fill = True
    elif hasattr(ambiguous, '__iter__'):
        is_dst = True
        if len(ambiguous) != len(vals):
            raise ValueError("Length of ambiguous bool-array must be the same size as vals")

    trans, deltas, typ = _get_dst_info(tz)

    tdata = <int64_t*> trans.data
    ntrans = len(trans)

    result_a = np.empty(n, dtype=np.int64)
    result_b = np.empty(n, dtype=np.int64)
    result_a.fill(NPY_NAT)
    result_b.fill(NPY_NAT)

    # left side
    idx_shifted = (np.maximum(0, trans.searchsorted(vals - DAY_NS, side='right') - 1)).astype(np.int64)

    for i in range(n):
        v = vals[i] - deltas[idx_shifted[i]]
        pos = bisect_right_i8(tdata, v, ntrans) - 1

        # timestamp falls to the left side of the DST transition
        if v + deltas[pos] == vals[i]:
            result_a[i] = v

    # right side
    idx_shifted = (np.maximum(0, trans.searchsorted(vals + DAY_NS, side='right') - 1)).astype(np.int64)

    for i in range(n):
        v = vals[i] - deltas[idx_shifted[i]]
        pos = bisect_right_i8(tdata, v, ntrans) - 1

        # timestamp falls to the right side of the DST transition
        if v + deltas[pos] == vals[i]:
            result_b[i] = v

    if infer_dst:
        dst_hours = np.empty(n, dtype=np.int64)
        dst_hours.fill(NPY_NAT)

        # Get the ambiguous hours (given the above, these are the hours
        # where result_a != result_b and neither of them are NAT)
        both_nat = np.logical_and(result_a != NPY_NAT, result_b != NPY_NAT)
        both_eq  = result_a == result_b
        trans_idx = np.squeeze(np.nonzero(np.logical_and(both_nat, ~both_eq)))
        if trans_idx.size == 1:
            stamp = Timestamp(vals[trans_idx])
            raise pytz.AmbiguousTimeError("Cannot infer dst time from %s as"
                                          "there are no repeated times" % stamp)
        # Split the array into contiguous chunks (where the difference between
        # indices is 1).  These are effectively dst transitions in different years
        # which is useful for checking that there is not an ambiguous transition
        # in an individual year.
        if trans_idx.size > 0:
            one_diff = np.where(np.diff(trans_idx)!=1)[0]+1
            trans_grp = np.array_split(trans_idx, one_diff)

            # Iterate through each day, if there are no hours where the delta is negative
            # (indicates a repeat of hour) the switch cannot be inferred
            for grp in trans_grp:

                delta = np.diff(result_a[grp])
                if grp.size == 1 or np.all(delta>0):
                    stamp = Timestamp(vals[grp[0]])
                    raise pytz.AmbiguousTimeError(stamp)

                # Find the index for the switch and pull from a for dst and b for standard
                switch_idx = (delta<=0).nonzero()[0]
                if switch_idx.size > 1:
                    raise pytz.AmbiguousTimeError("There are %i dst switches "
                                                  "when there should only be 1."
                                                  % switch_idx.size)
                switch_idx = switch_idx[0]+1 # Pull the only index and adjust
                a_idx = grp[:switch_idx]
                b_idx = grp[switch_idx:]
                dst_hours[grp] = np.hstack((result_a[a_idx], result_b[b_idx]))

    for i in range(n):
        left = result_a[i]
        right = result_b[i]
        if vals[i] == NPY_NAT:
            result[i] = vals[i]
        elif left != NPY_NAT and right != NPY_NAT:
            if left == right:
                result[i] = left
            else:
                if infer_dst and dst_hours[i] != NPY_NAT:
                    result[i] = dst_hours[i]
                elif is_dst:
                    if ambiguous[i]:
                        result[i] = left
                    else:
                        result[i] = right
                elif fill:
                    result[i] = NPY_NAT
                else:
                    stamp = Timestamp(vals[i])
                    raise pytz.AmbiguousTimeError("Cannot infer dst time from %r, "\
                                                  "try using the 'ambiguous' argument"
                                                  % stamp)
        elif left != NPY_NAT:
            result[i] = left
        elif right != NPY_NAT:
            result[i] = right
        else:
            stamp = Timestamp(vals[i])
            raise pytz.NonExistentTimeError(stamp)

    return result

cdef inline bisect_right_i8(int64_t *data, int64_t val, Py_ssize_t n):
    cdef Py_ssize_t pivot, left = 0, right = n

    # edge cases
    if val > data[n - 1]:
        return n

    if val < data[0]:
        return 0

    while left < right:
        pivot = left + (right - left) // 2

        if data[pivot] <= val:
            left = pivot + 1
        else:
            right = pivot

    return left


# Accessors
#----------------------------------------------------------------------

def build_field_sarray(ndarray[int64_t] dtindex):
    '''
    Datetime as int64 representation to a structured array of fields
    '''
    cdef:
        Py_ssize_t i, count = 0
        int isleap
        pandas_datetimestruct dts
        ndarray[int32_t] years, months, days, hours, minutes, seconds, mus

    count = len(dtindex)

    sa_dtype = [('Y', 'i4'), # year
                ('M', 'i4'), # month
                ('D', 'i4'), # day
                ('h', 'i4'), # hour
                ('m', 'i4'), # min
                ('s', 'i4'), # second
                ('u', 'i4')] # microsecond

    out = np.empty(count, dtype=sa_dtype)

    years = out['Y']
    months = out['M']
    days = out['D']
    hours = out['h']
    minutes = out['m']
    seconds = out['s']
    mus = out['u']

    for i in range(count):
        pandas_datetime_to_datetimestruct(dtindex[i], PANDAS_FR_ns, &dts)
        years[i] = dts.year
        months[i] = dts.month
        days[i] = dts.day
        hours[i] = dts.hour
        minutes[i] = dts.min
        seconds[i] = dts.sec
        mus[i] = dts.us

    return out

def get_time_micros(ndarray[int64_t] dtindex):
    '''
    Datetime as int64 representation to a structured array of fields
    '''
    cdef:
        Py_ssize_t i, n = len(dtindex)
        pandas_datetimestruct dts
        ndarray[int64_t] micros

    micros = np.empty(n, dtype=np.int64)

    for i in range(n):
        pandas_datetime_to_datetimestruct(dtindex[i], PANDAS_FR_ns, &dts)
        micros[i] = 1000000LL * (dts.hour * 60 * 60 +
                                 60 * dts.min + dts.sec) + dts.us

    return micros

@cython.wraparound(False)
def get_date_field(ndarray[int64_t] dtindex, object field):
    '''
    Given a int64-based datetime index, extract the year, month, etc.,
    field and return an array of these values.
    '''
    cdef:
        _TSObject ts
        Py_ssize_t i, count = 0
        ndarray[int32_t] out
        ndarray[int32_t, ndim=2] _month_offset
        int isleap, isleap_prev
        pandas_datetimestruct dts
        int mo_off, doy, dow, woy

    _month_offset = np.array(
        [[ 0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334, 365 ],
         [ 0, 31, 60, 91, 121, 152, 182, 213, 244, 274, 305, 335, 366 ]],
         dtype=np.int32 )

    count = len(dtindex)
    out = np.empty(count, dtype='i4')

    if field == 'Y':
        for i in range(count):
            if dtindex[i] == NPY_NAT: out[i] = -1; continue

            pandas_datetime_to_datetimestruct(dtindex[i], PANDAS_FR_ns, &dts)
            out[i] = dts.year
        return out

    elif field == 'M':
        for i in range(count):
            if dtindex[i] == NPY_NAT: out[i] = -1; continue

            pandas_datetime_to_datetimestruct(dtindex[i], PANDAS_FR_ns, &dts)
            out[i] = dts.month
        return out

    elif field == 'D':
        for i in range(count):
            if dtindex[i] == NPY_NAT: out[i] = -1; continue

            pandas_datetime_to_datetimestruct(dtindex[i], PANDAS_FR_ns, &dts)
            out[i] = dts.day
        return out

    elif field == 'h':
        for i in range(count):
            if dtindex[i] == NPY_NAT: out[i] = -1; continue

            pandas_datetime_to_datetimestruct(dtindex[i], PANDAS_FR_ns, &dts)
            out[i] = dts.hour
        return out

    elif field == 'm':
        for i in range(count):
            if dtindex[i] == NPY_NAT: out[i] = -1; continue

            pandas_datetime_to_datetimestruct(dtindex[i], PANDAS_FR_ns, &dts)
            out[i] = dts.min
        return out

    elif field == 's':
        for i in range(count):
            if dtindex[i] == NPY_NAT: out[i] = -1; continue

            pandas_datetime_to_datetimestruct(dtindex[i], PANDAS_FR_ns, &dts)
            out[i] = dts.sec
        return out

    elif field == 'us':
        for i in range(count):
            if dtindex[i] == NPY_NAT: out[i] = -1; continue

            pandas_datetime_to_datetimestruct(dtindex[i], PANDAS_FR_ns, &dts)
            out[i] = dts.us
        return out

    elif field == 'ns':
        for i in range(count):
            if dtindex[i] == NPY_NAT: out[i] = -1; continue

            pandas_datetime_to_datetimestruct(dtindex[i], PANDAS_FR_ns, &dts)
            out[i] = dts.ps / 1000
        return out
    elif field == 'doy':
        for i in range(count):
            if dtindex[i] == NPY_NAT: out[i] = -1; continue

            pandas_datetime_to_datetimestruct(dtindex[i], PANDAS_FR_ns, &dts)
            isleap = is_leapyear(dts.year)
            out[i] = _month_offset[isleap, dts.month-1] + dts.day
        return out

    elif field == 'dow':
        for i in range(count):
            if dtindex[i] == NPY_NAT: out[i] = -1; continue

            ts = convert_to_tsobject(dtindex[i], None, None)
            out[i] = ts_dayofweek(ts)
        return out

    elif field == 'woy':
        for i in range(count):
            if dtindex[i] == NPY_NAT: out[i] = -1; continue

            pandas_datetime_to_datetimestruct(dtindex[i], PANDAS_FR_ns, &dts)
            ts = convert_to_tsobject(dtindex[i], None, None)
            isleap = is_leapyear(dts.year)
            isleap_prev = is_leapyear(dts.year - 1)
            mo_off = _month_offset[isleap, dts.month - 1]
            doy = mo_off + dts.day
            dow = ts_dayofweek(ts)

            #estimate
            woy = (doy - 1) - dow + 3
            if woy >= 0:
                woy = woy / 7 + 1

            # verify
            if woy < 0:
                if (woy > -2) or (woy == -2 and isleap_prev):
                    woy = 53
                else:
                    woy = 52
            elif woy == 53:
                if 31 - dts.day + dow < 3:
                    woy = 1

            out[i] = woy
        return out

    elif field == 'q':
        for i in range(count):
            if dtindex[i] == NPY_NAT: out[i] = -1; continue

            pandas_datetime_to_datetimestruct(dtindex[i], PANDAS_FR_ns, &dts)
            out[i] = dts.month
            out[i] = ((out[i] - 1) / 3) + 1
        return out

    raise ValueError("Field %s not supported" % field)


@cython.wraparound(False)
def get_start_end_field(ndarray[int64_t] dtindex, object field, object freqstr=None, int month_kw=12):
    '''
    Given an int64-based datetime index return array of indicators
    of whether timestamps are at the start/end of the month/quarter/year
    (defined by frequency).
    '''
    cdef:
        _TSObject ts
        Py_ssize_t i
        int count = 0
        bint is_business = 0
        int end_month = 12
        int start_month = 1
        ndarray[int8_t] out
        ndarray[int32_t, ndim=2] _month_offset
        bint isleap
        pandas_datetimestruct dts
        int mo_off, dom, doy, dow, ldom

    _month_offset = np.array(
        [[ 0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334, 365 ],
         [ 0, 31, 60, 91, 121, 152, 182, 213, 244, 274, 305, 335, 366 ]],
         dtype=np.int32 )

    count = len(dtindex)
    out = np.zeros(count, dtype='int8')

    if freqstr:
        if freqstr == 'C':
            raise ValueError("Custom business days is not supported by %s" % field)
        is_business = freqstr[0] == 'B'

        # YearBegin(), BYearBegin() use month = starting month of year
        # QuarterBegin(), BQuarterBegin() use startingMonth = starting month of year
        # other offests use month, startingMonth as ending month of year.

        if (freqstr[0:2] in ['MS', 'QS', 'AS']) or (freqstr[1:3] in ['MS', 'QS', 'AS']):
            end_month = 12 if month_kw == 1 else month_kw - 1
            start_month = month_kw
        else:
            end_month = month_kw
            start_month = (end_month % 12) + 1
    else:
        end_month = 12
        start_month = 1

    if field == 'is_month_start':
        if is_business:
            for i in range(count):
                if dtindex[i] == NPY_NAT: out[i] = -1; continue

                pandas_datetime_to_datetimestruct(dtindex[i], PANDAS_FR_ns, &dts)
                ts = convert_to_tsobject(dtindex[i], None, None)
                dom = dts.day
                dow = ts_dayofweek(ts)

                if (dom == 1 and dow < 5) or (dom <= 3 and dow == 0):
                    out[i] = 1
            return out.view(bool)
        else:
            for i in range(count):
                if dtindex[i] == NPY_NAT: out[i] = -1; continue

                pandas_datetime_to_datetimestruct(dtindex[i], PANDAS_FR_ns, &dts)
                dom = dts.day

                if dom == 1:
                    out[i] = 1
            return out.view(bool)

    elif field == 'is_month_end':
        if is_business:
            for i in range(count):
                if dtindex[i] == NPY_NAT: out[i] = -1; continue

                pandas_datetime_to_datetimestruct(dtindex[i], PANDAS_FR_ns, &dts)
                ts = convert_to_tsobject(dtindex[i], None, None)
                isleap = is_leapyear(dts.year)
                mo_off = _month_offset[isleap, dts.month - 1]
                dom = dts.day
                doy = mo_off + dom
                ldom = _month_offset[isleap, dts.month]
                dow = ts_dayofweek(ts)

                if (ldom == doy and dow < 5) or (dow == 4 and (ldom - doy <= 2)):
                    out[i] = 1
            return out.view(bool)
        else:
            for i in range(count):
                if dtindex[i] == NPY_NAT: out[i] = -1; continue

                pandas_datetime_to_datetimestruct(dtindex[i], PANDAS_FR_ns, &dts)
                isleap = is_leapyear(dts.year)
                mo_off = _month_offset[isleap, dts.month - 1]
                dom = dts.day
                doy = mo_off + dom
                ldom = _month_offset[isleap, dts.month]

                if ldom == doy:
                    out[i] = 1
            return out.view(bool)

    elif field == 'is_quarter_start':
        if is_business:
            for i in range(count):
                if dtindex[i] == NPY_NAT: out[i] = -1; continue

                pandas_datetime_to_datetimestruct(dtindex[i], PANDAS_FR_ns, &dts)
                ts = convert_to_tsobject(dtindex[i], None, None)
                dom = dts.day
                dow = ts_dayofweek(ts)

                if ((dts.month - start_month) % 3 == 0) and ((dom == 1 and dow < 5) or (dom <= 3 and dow == 0)):
                    out[i] = 1
            return out.view(bool)
        else:
            for i in range(count):
                if dtindex[i] == NPY_NAT: out[i] = -1; continue

                pandas_datetime_to_datetimestruct(dtindex[i], PANDAS_FR_ns, &dts)
                dom = dts.day

                if ((dts.month - start_month) % 3 == 0) and dom == 1:
                    out[i] = 1
            return out.view(bool)

    elif field == 'is_quarter_end':
        if is_business:
            for i in range(count):
                if dtindex[i] == NPY_NAT: out[i] = -1; continue

                pandas_datetime_to_datetimestruct(dtindex[i], PANDAS_FR_ns, &dts)
                ts = convert_to_tsobject(dtindex[i], None, None)
                isleap = is_leapyear(dts.year)
                mo_off = _month_offset[isleap, dts.month - 1]
                dom = dts.day
                doy = mo_off + dom
                ldom = _month_offset[isleap, dts.month]
                dow = ts_dayofweek(ts)

                if ((dts.month - end_month) % 3 == 0) and ((ldom == doy and dow < 5) or (dow == 4 and (ldom - doy <= 2))):
                    out[i] = 1
            return out.view(bool)
        else:
            for i in range(count):
                if dtindex[i] == NPY_NAT: out[i] = -1; continue

                pandas_datetime_to_datetimestruct(dtindex[i], PANDAS_FR_ns, &dts)
                isleap = is_leapyear(dts.year)
                mo_off = _month_offset[isleap, dts.month - 1]
                dom = dts.day
                doy = mo_off + dom
                ldom = _month_offset[isleap, dts.month]

                if ((dts.month - end_month) % 3 == 0) and (ldom == doy):
                    out[i] = 1
            return out.view(bool)

    elif field == 'is_year_start':
        if is_business:
            for i in range(count):
                if dtindex[i] == NPY_NAT: out[i] = -1; continue

                pandas_datetime_to_datetimestruct(dtindex[i], PANDAS_FR_ns, &dts)
                ts = convert_to_tsobject(dtindex[i], None, None)
                dom = dts.day
                dow = ts_dayofweek(ts)

                if (dts.month == start_month) and ((dom == 1 and dow < 5) or (dom <= 3 and dow == 0)):
                    out[i] = 1
            return out.view(bool)
        else:
            for i in range(count):
                if dtindex[i] == NPY_NAT: out[i] = -1; continue

                pandas_datetime_to_datetimestruct(dtindex[i], PANDAS_FR_ns, &dts)
                dom = dts.day

                if (dts.month == start_month) and dom == 1:
                    out[i] = 1
            return out.view(bool)

    elif field == 'is_year_end':
        if is_business:
            for i in range(count):
                if dtindex[i] == NPY_NAT: out[i] = -1; continue

                pandas_datetime_to_datetimestruct(dtindex[i], PANDAS_FR_ns, &dts)
                ts = convert_to_tsobject(dtindex[i], None, None)
                isleap = is_leapyear(dts.year)
                dom = dts.day
                mo_off = _month_offset[isleap, dts.month - 1]
                doy = mo_off + dom
                dow = ts_dayofweek(ts)
                ldom = _month_offset[isleap, dts.month]

                if (dts.month == end_month) and ((ldom == doy and dow < 5) or (dow == 4 and (ldom - doy <= 2))):
                    out[i] = 1
            return out.view(bool)
        else:
            for i in range(count):
                if dtindex[i] == NPY_NAT: out[i] = -1; continue

                pandas_datetime_to_datetimestruct(dtindex[i], PANDAS_FR_ns, &dts)
                ts = convert_to_tsobject(dtindex[i], None, None)
                isleap = is_leapyear(dts.year)
                mo_off = _month_offset[isleap, dts.month - 1]
                dom = dts.day
                doy = mo_off + dom
                ldom = _month_offset[isleap, dts.month]

                if (dts.month == end_month) and (ldom == doy):
                    out[i] = 1
            return out.view(bool)

    raise ValueError("Field %s not supported" % field)


cdef inline int m8_weekday(int64_t val):
    ts = convert_to_tsobject(val, None, None)
    return ts_dayofweek(ts)

cdef int64_t DAY_NS = 86400000000000LL


def date_normalize(ndarray[int64_t] stamps, tz=None):
    cdef:
        Py_ssize_t i, n = len(stamps)
        pandas_datetimestruct dts
        _TSObject tso
        ndarray[int64_t] result = np.empty(n, dtype=np.int64)

    if tz is not None:
        tso = _TSObject()
        tz = maybe_get_tz(tz)
        result = _normalize_local(stamps, tz)
    else:
        for i in range(n):
            if stamps[i] == NPY_NAT:
                result[i] = NPY_NAT
                continue
            pandas_datetime_to_datetimestruct(stamps[i], PANDAS_FR_ns, &dts)
            result[i] = _normalized_stamp(&dts)

    return result

cdef _normalize_local(ndarray[int64_t] stamps, object tz):
    cdef:
        Py_ssize_t n = len(stamps)
        ndarray[int64_t] result = np.empty(n, dtype=np.int64)
        ndarray[int64_t] trans, deltas, pos
        pandas_datetimestruct dts

    if _is_utc(tz):
        for i in range(n):
            if stamps[i] == NPY_NAT:
                result[i] = NPY_NAT
                continue
            pandas_datetime_to_datetimestruct(stamps[i], PANDAS_FR_ns, &dts)
            result[i] = _normalized_stamp(&dts)
    elif _is_tzlocal(tz):
        for i in range(n):
            if stamps[i] == NPY_NAT:
                result[i] = NPY_NAT
                continue
            pandas_datetime_to_datetimestruct(stamps[i], PANDAS_FR_ns,
                                              &dts)
            dt = datetime(dts.year, dts.month, dts.day, dts.hour,
                          dts.min, dts.sec, dts.us, tz)
            delta = int(total_seconds(_get_utcoffset(tz, dt))) * 1000000000
            pandas_datetime_to_datetimestruct(stamps[i] + delta,
                                              PANDAS_FR_ns, &dts)
            result[i] = _normalized_stamp(&dts)
    else:
        # Adjust datetime64 timestamp, recompute datetimestruct
        trans, deltas, typ = _get_dst_info(tz)

        _pos = trans.searchsorted(stamps, side='right') - 1
        if _pos.dtype != np.int64:
            _pos = _pos.astype(np.int64)
        pos = _pos

        # statictzinfo
        if typ not in ['pytz','dateutil']:
            for i in range(n):
                if stamps[i] == NPY_NAT:
                    result[i] = NPY_NAT
                    continue
                pandas_datetime_to_datetimestruct(stamps[i] + deltas[0],
                                                  PANDAS_FR_ns, &dts)
                result[i] = _normalized_stamp(&dts)
        else:
            for i in range(n):
                if stamps[i] == NPY_NAT:
                    result[i] = NPY_NAT
                    continue
                pandas_datetime_to_datetimestruct(stamps[i] + deltas[pos[i]],
                                                  PANDAS_FR_ns, &dts)
                result[i] = _normalized_stamp(&dts)

    return result

cdef inline int64_t _normalized_stamp(pandas_datetimestruct *dts):
    dts.hour = 0
    dts.min = 0
    dts.sec = 0
    dts.us = 0
    dts.ps = 0
    return pandas_datetimestruct_to_datetime(PANDAS_FR_ns, dts)


def dates_normalized(ndarray[int64_t] stamps, tz=None):
    cdef:
        Py_ssize_t i, n = len(stamps)
        pandas_datetimestruct dts

    if tz is None or _is_utc(tz):
        for i in range(n):
            pandas_datetime_to_datetimestruct(stamps[i], PANDAS_FR_ns, &dts)
            if (dts.hour + dts.min + dts.sec + dts.us) > 0:
                return False
    elif _is_tzlocal(tz):
        for i in range(n):
            pandas_datetime_to_datetimestruct(stamps[i], PANDAS_FR_ns, &dts)
            if (dts.min + dts.sec + dts.us) > 0:
                return False
            dt = datetime(dts.year, dts.month, dts.day, dts.hour, dts.min,
                          dts.sec, dts.us, tz)
            dt = dt + tz.utcoffset(dt)
            if dt.hour > 0:
                return False
    else:
        trans, deltas, typ = _get_dst_info(tz)

        for i in range(n):
            # Adjust datetime64 timestamp, recompute datetimestruct
            pos = trans.searchsorted(stamps[i]) - 1
            inf = tz._transition_info[pos]

            pandas_datetime_to_datetimestruct(stamps[i] + deltas[pos],
                                              PANDAS_FR_ns, &dts)
            if (dts.hour + dts.min + dts.sec + dts.us) > 0:
                return False

    return True

# Some general helper functions
#----------------------------------------------------------------------

def isleapyear(int64_t year):
    return is_leapyear(year)

def monthrange(int64_t year, int64_t month):
    cdef:
        int64_t days
        int64_t day_of_week

    if month < 1 or month > 12:
        raise ValueError("bad month number 0; must be 1-12")

    days = days_per_month_table[is_leapyear(year)][month-1]

    return (dayofweek(year, month, 1), days)

cdef inline int64_t ts_dayofweek(_TSObject ts):
    return dayofweek(ts.dts.year, ts.dts.month, ts.dts.day)


cpdef normalize_date(object dt):
    '''
    Normalize datetime.datetime value to midnight. Returns datetime.date as a
    datetime.datetime at midnight

    Returns
    -------
    normalized : datetime.datetime or Timestamp
    '''
    if PyDateTime_Check(dt):
        return dt.replace(hour=0, minute=0, second=0, microsecond=0)
    elif PyDate_Check(dt):
        return datetime(dt.year, dt.month, dt.day)
    else:
        raise TypeError('Unrecognized type: %s' % type(dt))

cdef ndarray[int64_t] localize_dt64arr_to_period(ndarray[int64_t] stamps,
                                                 int freq, object tz):
    cdef:
        Py_ssize_t n = len(stamps)
        ndarray[int64_t] result = np.empty(n, dtype=np.int64)
        ndarray[int64_t] trans, deltas, pos
        pandas_datetimestruct dts

    if not have_pytz:
        raise Exception('Could not find pytz module')

    if _is_utc(tz):
        for i in range(n):
            if stamps[i] == NPY_NAT:
                result[i] = NPY_NAT
                continue
            pandas_datetime_to_datetimestruct(stamps[i], PANDAS_FR_ns, &dts)
            result[i] = get_period_ordinal(dts.year, dts.month, dts.day,
                                           dts.hour, dts.min, dts.sec, dts.us, dts.ps, freq)

    elif _is_tzlocal(tz):
        for i in range(n):
            if stamps[i] == NPY_NAT:
                result[i] = NPY_NAT
                continue
            pandas_datetime_to_datetimestruct(stamps[i], PANDAS_FR_ns,
                                              &dts)
            dt = datetime(dts.year, dts.month, dts.day, dts.hour,
                          dts.min, dts.sec, dts.us, tz)
            delta = int(total_seconds(_get_utcoffset(tz, dt))) * 1000000000
            pandas_datetime_to_datetimestruct(stamps[i] + delta,
                                              PANDAS_FR_ns, &dts)
            result[i] = get_period_ordinal(dts.year, dts.month, dts.day,
                                           dts.hour, dts.min, dts.sec, dts.us, dts.ps, freq)
    else:
        # Adjust datetime64 timestamp, recompute datetimestruct
        trans, deltas, typ = _get_dst_info(tz)

        _pos = trans.searchsorted(stamps, side='right') - 1
        if _pos.dtype != np.int64:
            _pos = _pos.astype(np.int64)
        pos = _pos

        # statictzinfo
        if typ not in ['pytz','dateutil']:
            for i in range(n):
                if stamps[i] == NPY_NAT:
                    result[i] = NPY_NAT
                    continue
                pandas_datetime_to_datetimestruct(stamps[i] + deltas[0],
                                                  PANDAS_FR_ns, &dts)
                result[i] = get_period_ordinal(dts.year, dts.month, dts.day,
                                               dts.hour, dts.min, dts.sec, dts.us, dts.ps, freq)
        else:
            for i in range(n):
                if stamps[i] == NPY_NAT:
                    result[i] = NPY_NAT
                    continue
                pandas_datetime_to_datetimestruct(stamps[i] + deltas[pos[i]],
                                                  PANDAS_FR_ns, &dts)
                result[i] = get_period_ordinal(dts.year, dts.month, dts.day,
                                               dts.hour, dts.min, dts.sec, dts.us, dts.ps, freq)

    return result


cdef extern from "period.h":
    ctypedef struct date_info:
        int64_t absdate
        double abstime
        double second
        int minute
        int hour
        int day
        int month
        int quarter
        int year
        int day_of_week
        int day_of_year
        int calendar

    ctypedef struct asfreq_info:
        int from_week_end
        int to_week_end

        int from_a_year_end
        int to_a_year_end

        int from_q_year_end
        int to_q_year_end

    ctypedef int64_t (*freq_conv_func)(int64_t, char, asfreq_info*)

    void initialize_daytime_conversion_factor_matrix()
    int64_t asfreq(int64_t dtordinal, int freq1, int freq2, char relation) except INT32_MIN
    freq_conv_func get_asfreq_func(int fromFreq, int toFreq)
    void get_asfreq_info(int fromFreq, int toFreq, asfreq_info *af_info)

    int64_t get_period_ordinal(int year, int month, int day,
                          int hour, int minute, int second, int microseconds, int picoseconds,
                          int freq) except INT32_MIN

    int64_t get_python_ordinal(int64_t period_ordinal, int freq) except INT32_MIN

    int get_date_info(int64_t ordinal, int freq, date_info *dinfo) except INT32_MIN
    double getAbsTime(int, int64_t, int64_t)

    int pyear(int64_t ordinal, int freq) except INT32_MIN
    int pqyear(int64_t ordinal, int freq) except INT32_MIN
    int pquarter(int64_t ordinal, int freq) except INT32_MIN
    int pmonth(int64_t ordinal, int freq) except INT32_MIN
    int pday(int64_t ordinal, int freq) except INT32_MIN
    int pweekday(int64_t ordinal, int freq) except INT32_MIN
    int pday_of_week(int64_t ordinal, int freq) except INT32_MIN
    int pday_of_year(int64_t ordinal, int freq) except INT32_MIN
    int pweek(int64_t ordinal, int freq) except INT32_MIN
    int phour(int64_t ordinal, int freq) except INT32_MIN
    int pminute(int64_t ordinal, int freq) except INT32_MIN
    int psecond(int64_t ordinal, int freq) except INT32_MIN
    char *c_strftime(date_info *dinfo, char *fmt)
    int get_yq(int64_t ordinal, int freq, int *quarter, int *year)

initialize_daytime_conversion_factor_matrix()

# Period logic
#----------------------------------------------------------------------

cdef inline int64_t apply_mult(int64_t period_ord, int64_t mult):
    """
    Get freq+multiple ordinal value from corresponding freq-only ordinal value.
    For example, 5min ordinal will be 1/5th the 1min ordinal (rounding down to
    integer).
    """
    if mult == 1:
        return period_ord

    return (period_ord - 1) // mult

cdef inline int64_t remove_mult(int64_t period_ord_w_mult, int64_t mult):
    """
    Get freq-only ordinal value from corresponding freq+multiple ordinal.
    """
    if mult == 1:
        return period_ord_w_mult

    return period_ord_w_mult * mult + 1;

def dt64arr_to_periodarr(ndarray[int64_t] dtarr, int freq, tz=None):
    """
    Convert array of datetime64 values (passed in as 'i8' dtype) to a set of
    periods corresponding to desired frequency, per period convention.
    """
    cdef:
        ndarray[int64_t] out
        Py_ssize_t i, l
        pandas_datetimestruct dts

    l = len(dtarr)

    out = np.empty(l, dtype='i8')

    if tz is None:
        for i in range(l):
            if dtarr[i] == iNaT:
                out[i] = iNaT
                continue
            pandas_datetime_to_datetimestruct(dtarr[i], PANDAS_FR_ns, &dts)
            out[i] = get_period_ordinal(dts.year, dts.month, dts.day,
                                        dts.hour, dts.min, dts.sec, dts.us, dts.ps, freq)
    else:
        out = localize_dt64arr_to_period(dtarr, freq, tz)
    return out

def periodarr_to_dt64arr(ndarray[int64_t] periodarr, int freq):
    """
    Convert array to datetime64 values from a set of ordinals corresponding to
    periods per period convention.
    """
    cdef:
        ndarray[int64_t] out
        Py_ssize_t i, l

    l = len(periodarr)

    out = np.empty(l, dtype='i8')

    for i in range(l):
        if periodarr[i] == iNaT:
            out[i] = iNaT
            continue
        out[i] = period_ordinal_to_dt64(periodarr[i], freq)

    return out

cdef char START = 'S'
cdef char END = 'E'

cpdef int64_t period_asfreq(int64_t period_ordinal, int freq1, int freq2,
                            bint end):
    """
    Convert period ordinal from one frequency to another, and if upsampling,
    choose to use start ('S') or end ('E') of period.
    """
    cdef:
        int64_t retval

    if period_ordinal == iNaT:
        return iNaT

    if end:
        retval = asfreq(period_ordinal, freq1, freq2, END)
    else:
        retval = asfreq(period_ordinal, freq1, freq2, START)

    if retval == INT32_MIN:
        raise ValueError('Frequency conversion failed')

    return retval

def period_asfreq_arr(ndarray[int64_t] arr, int freq1, int freq2, bint end):
    """
    Convert int64-array of period ordinals from one frequency to another, and
    if upsampling, choose to use start ('S') or end ('E') of period.
    """
    cdef:
        ndarray[int64_t] result
        Py_ssize_t i, n
        freq_conv_func func
        asfreq_info finfo
        int64_t val, ordinal
        char relation

    n = len(arr)
    result = np.empty(n, dtype=np.int64)

    func = get_asfreq_func(freq1, freq2)
    get_asfreq_info(freq1, freq2, &finfo)

    if end:
        relation = END
    else:
        relation = START

    mask = arr == iNaT
    if mask.any():      # NaT process
        for i in range(n):
            val = arr[i]
            if val != iNaT:
                val = func(val, relation, &finfo)
                if val == INT32_MIN:
                    raise ValueError("Unable to convert to desired frequency.")
            result[i] = val
    else:
        for i in range(n):
            val = func(arr[i], relation, &finfo)
            if val == INT32_MIN:
                raise ValueError("Unable to convert to desired frequency.")
            result[i] = val

    return result

def period_ordinal(int y, int m, int d, int h, int min, int s, int us, int ps, int freq):
    cdef:
        int64_t ordinal

    return get_period_ordinal(y, m, d, h, min, s, us, ps, freq)


cpdef int64_t period_ordinal_to_dt64(int64_t ordinal, int freq):
    cdef:
        pandas_datetimestruct dts
        date_info dinfo
        float subsecond_fraction

    if ordinal == iNaT:
        return NPY_NAT

    get_date_info(ordinal, freq, &dinfo)

    dts.year = dinfo.year
    dts.month = dinfo.month
    dts.day = dinfo.day
    dts.hour = dinfo.hour
    dts.min = dinfo.minute
    dts.sec = int(dinfo.second)
    subsecond_fraction = dinfo.second - dts.sec
    dts.us = int((subsecond_fraction) * 1e6)
    dts.ps = int(((subsecond_fraction) * 1e6 - dts.us) * 1e6)

    return pandas_datetimestruct_to_datetime(PANDAS_FR_ns, &dts)

def period_format(int64_t value, int freq, object fmt=None):
    cdef:
        int freq_group

    if value == iNaT:
        return repr(NaT)

    if fmt is None:
        freq_group = (freq // 1000) * 1000
        if freq_group == 1000: # FR_ANN
            fmt = b'%Y'
        elif freq_group == 2000: # FR_QTR
            fmt = b'%FQ%q'
        elif freq_group == 3000: # FR_MTH
            fmt = b'%Y-%m'
        elif freq_group == 4000: # WK
            left = period_asfreq(value, freq, 6000, 0)
            right = period_asfreq(value, freq, 6000, 1)
            return '%s/%s' % (period_format(left, 6000),
                              period_format(right, 6000))
        elif (freq_group == 5000 # BUS
              or freq_group == 6000): # DAY
            fmt = b'%Y-%m-%d'
        elif freq_group == 7000: # HR
            fmt = b'%Y-%m-%d %H:00'
        elif freq_group == 8000: # MIN
            fmt = b'%Y-%m-%d %H:%M'
        elif freq_group == 9000: # SEC
            fmt = b'%Y-%m-%d %H:%M:%S'
        elif freq_group == 10000: # MILLISEC
            fmt = b'%Y-%m-%d %H:%M:%S.%l'
        elif freq_group == 11000: # MICROSEC
            fmt = b'%Y-%m-%d %H:%M:%S.%u'
        elif freq_group == 12000: # NANOSEC
            fmt = b'%Y-%m-%d %H:%M:%S.%n'
        else:
            raise ValueError('Unknown freq: %d' % freq)

    return _period_strftime(value, freq, fmt)


cdef list extra_fmts = [(b"%q", b"^`AB`^"),
                        (b"%f", b"^`CD`^"),
                        (b"%F", b"^`EF`^"),
                        (b"%l", b"^`GH`^"),
                        (b"%u", b"^`IJ`^"),
                        (b"%n", b"^`KL`^")]

cdef list str_extra_fmts = ["^`AB`^", "^`CD`^", "^`EF`^", "^`GH`^", "^`IJ`^", "^`KL`^"]

cdef object _period_strftime(int64_t value, int freq, object fmt):
    import sys

    cdef:
        Py_ssize_t i
        date_info dinfo
        char *formatted
        object pat, repl, result
        list found_pat = [False] * len(extra_fmts)
        int year, quarter

    if PyUnicode_Check(fmt):
        fmt = fmt.encode('utf-8')

    get_date_info(value, freq, &dinfo)
    for i in range(len(extra_fmts)):
        pat = extra_fmts[i][0]
        repl = extra_fmts[i][1]
        if pat in fmt:
            fmt = fmt.replace(pat, repl)
            found_pat[i] = True

    formatted = c_strftime(&dinfo, <char*> fmt)

    result = util.char_to_string(formatted)
    free(formatted)

    for i in range(len(extra_fmts)):
        if found_pat[i]:
            if get_yq(value, freq, &quarter, &year) < 0:
                raise ValueError('Unable to get quarter and year')

            if i == 0:
                repl = '%d' % quarter
            elif i == 1:  # %f, 2-digit year
                repl = '%.2d' % (year % 100)
            elif i == 2:
                repl = '%d' % year
            elif i == 3:
                repl = '%03d' % (value % 1000)
            elif i == 4:
                repl = '%06d' % (value % 1000000)
            elif i == 5:
                repl = '%09d' % (value % 1000000000)

            result = result.replace(str_extra_fmts[i], repl)

    if PY2:
        result = result.decode('utf-8', 'ignore')

    return result

# period accessors

ctypedef int (*accessor)(int64_t ordinal, int freq) except INT32_MIN

def get_period_field(int code, int64_t value, int freq):
    cdef accessor f = _get_accessor_func(code)
    if f is NULL:
        raise ValueError('Unrecognized period code: %d' % code)
    if value == iNaT:
        return np.nan
    return f(value, freq)

def get_period_field_arr(int code, ndarray[int64_t] arr, int freq):
    cdef:
        Py_ssize_t i, sz
        ndarray[int64_t] out
        accessor f

    f = _get_accessor_func(code)
    if f is NULL:
        raise ValueError('Unrecognized period code: %d' % code)

    sz = len(arr)
    out = np.empty(sz, dtype=np.int64)

    for i in range(sz):
        if arr[i] == iNaT:
            out[i] = -1
            continue
        out[i] = f(arr[i], freq)

    return out



cdef accessor _get_accessor_func(int code):
    if code == 0:
        return &pyear
    elif code == 1:
        return &pqyear
    elif code == 2:
        return &pquarter
    elif code == 3:
        return &pmonth
    elif code == 4:
        return &pday
    elif code == 5:
        return &phour
    elif code == 6:
        return &pminute
    elif code == 7:
        return &psecond
    elif code == 8:
        return &pweek
    elif code == 9:
        return &pday_of_year
    elif code == 10:
        return &pweekday
    return NULL


def extract_ordinals(ndarray[object] values, freq):
    cdef:
        Py_ssize_t i, n = len(values)
        ndarray[int64_t] ordinals = np.empty(n, dtype=np.int64)
        object p

    for i in range(n):
        p = values[i]
        ordinals[i] = p.ordinal
        if p.freq != freq:
            raise ValueError("%s is wrong freq" % p)

    return ordinals

cpdef resolution(ndarray[int64_t] stamps, tz=None):
    cdef:
        Py_ssize_t i, n = len(stamps)
        pandas_datetimestruct dts
        int reso = D_RESO, curr_reso

    if tz is not None:
        tz = maybe_get_tz(tz)
        return _reso_local(stamps, tz)
    else:
        for i in range(n):
            if stamps[i] == NPY_NAT:
                continue
            pandas_datetime_to_datetimestruct(stamps[i], PANDAS_FR_ns, &dts)
            curr_reso = _reso_stamp(&dts)
            if curr_reso < reso:
                reso = curr_reso
        return reso

US_RESO = 0
MS_RESO = 1
S_RESO = 2
T_RESO = 3
H_RESO = 4
D_RESO = 5

cdef inline int _reso_stamp(pandas_datetimestruct *dts):
    if dts.us != 0:
        if dts.us % 1000 == 0:
            return MS_RESO
        return US_RESO
    elif dts.sec != 0:
        return S_RESO
    elif dts.min != 0:
        return T_RESO
    elif dts.hour != 0:
        return H_RESO
    return D_RESO

cdef _reso_local(ndarray[int64_t] stamps, object tz):
    cdef:
        Py_ssize_t n = len(stamps)
        int reso = D_RESO, curr_reso
        ndarray[int64_t] trans, deltas, pos
        pandas_datetimestruct dts

    if _is_utc(tz):
        for i in range(n):
            if stamps[i] == NPY_NAT:
                continue
            pandas_datetime_to_datetimestruct(stamps[i], PANDAS_FR_ns, &dts)
            curr_reso = _reso_stamp(&dts)
            if curr_reso < reso:
                reso = curr_reso
    elif _is_tzlocal(tz):
        for i in range(n):
            if stamps[i] == NPY_NAT:
                continue
            pandas_datetime_to_datetimestruct(stamps[i], PANDAS_FR_ns,
                                              &dts)
            dt = datetime(dts.year, dts.month, dts.day, dts.hour,
                          dts.min, dts.sec, dts.us, tz)
            delta = int(total_seconds(_get_utcoffset(tz, dt))) * 1000000000
            pandas_datetime_to_datetimestruct(stamps[i] + delta,
                                              PANDAS_FR_ns, &dts)
            curr_reso = _reso_stamp(&dts)
            if curr_reso < reso:
                reso = curr_reso
    else:
        # Adjust datetime64 timestamp, recompute datetimestruct
        trans, deltas, typ = _get_dst_info(tz)

        _pos = trans.searchsorted(stamps, side='right') - 1
        if _pos.dtype != np.int64:
            _pos = _pos.astype(np.int64)
        pos = _pos

        # statictzinfo
        if typ not in ['pytz','dateutil']:
            for i in range(n):
                if stamps[i] == NPY_NAT:
                    continue
                pandas_datetime_to_datetimestruct(stamps[i] + deltas[0],
                                                  PANDAS_FR_ns, &dts)
                curr_reso = _reso_stamp(&dts)
                if curr_reso < reso:
                    reso = curr_reso
        else:
            for i in range(n):
                if stamps[i] == NPY_NAT:
                    continue
                pandas_datetime_to_datetimestruct(stamps[i] + deltas[pos[i]],
                                                  PANDAS_FR_ns, &dts)
                curr_reso = _reso_stamp(&dts)
                if curr_reso < reso:
                    reso = curr_reso

    return reso

#----------------------------------------------------------------------
# Don't even ask

"""Strptime-related classes and functions.

CLASSES:
    LocaleTime -- Discovers and stores locale-specific time information
    TimeRE -- Creates regexes for pattern matching a string of text containing
                time information

FUNCTIONS:
    _getlang -- Figure out what language is being used for the locale
    strptime -- Calculates the time struct represented by the passed-in string

"""
import time
import locale
import calendar
from re import compile as re_compile
from re import IGNORECASE
from re import escape as re_escape
from datetime import date as datetime_date

# Python 2 vs Python 3
try:
    from thread import allocate_lock as _thread_allocate_lock
except:
    try:
        from _thread import allocate_lock as _thread_allocate_lock
    except:
        try:
            from dummy_thread import allocate_lock as _thread_allocate_lock
        except:
            from _dummy_thread import allocate_lock as _thread_allocate_lock

__all__ = []

def _getlang():
    # Figure out what the current language is set to.
    return locale.getlocale(locale.LC_TIME)

class LocaleTime(object):
    """Stores and handles locale-specific information related to time.

    ATTRIBUTES:
        f_weekday -- full weekday names (7-item list)
        a_weekday -- abbreviated weekday names (7-item list)
        f_month -- full month names (13-item list; dummy value in [0], which
                    is added by code)
        a_month -- abbreviated month names (13-item list, dummy value in
                    [0], which is added by code)
        am_pm -- AM/PM representation (2-item list)
        LC_date_time -- format string for date/time representation (string)
        LC_date -- format string for date representation (string)
        LC_time -- format string for time representation (string)
        timezone -- daylight- and non-daylight-savings timezone representation
                    (2-item list of sets)
        lang -- Language used by instance (2-item tuple)
    """

    def __init__(self):
        """Set all attributes.

        Order of methods called matters for dependency reasons.

        The locale language is set at the offset and then checked again before
        exiting.  This is to make sure that the attributes were not set with a
        mix of information from more than one locale.  This would most likely
        happen when using threads where one thread calls a locale-dependent
        function while another thread changes the locale while the function in
        the other thread is still running.  Proper coding would call for
        locks to prevent changing the locale while locale-dependent code is
        running.  The check here is done in case someone does not think about
        doing this.

        Only other possible issue is if someone changed the timezone and did
        not call tz.tzset .  That is an issue for the programmer, though,
        since changing the timezone is worthless without that call.

        """
        self.lang = _getlang()
        self.__calc_weekday()
        self.__calc_month()
        self.__calc_am_pm()
        self.__calc_timezone()
        self.__calc_date_time()
        if _getlang() != self.lang:
            raise ValueError("locale changed during initialization")

    def __pad(self, seq, front):
        # Add '' to seq to either the front (is True), else the back.
        seq = list(seq)
        if front:
            seq.insert(0, '')
        else:
            seq.append('')
        return seq

    def __calc_weekday(self):
        # Set self.a_weekday and self.f_weekday using the calendar
        # module.
        a_weekday = [calendar.day_abbr[i].lower() for i in range(7)]
        f_weekday = [calendar.day_name[i].lower() for i in range(7)]
        self.a_weekday = a_weekday
        self.f_weekday = f_weekday

    def __calc_month(self):
        # Set self.f_month and self.a_month using the calendar module.
        a_month = [calendar.month_abbr[i].lower() for i in range(13)]
        f_month = [calendar.month_name[i].lower() for i in range(13)]
        self.a_month = a_month
        self.f_month = f_month

    def __calc_am_pm(self):
        # Set self.am_pm by using time.strftime().

        # The magic date (1999,3,17,hour,44,55,2,76,0) is not really that
        # magical; just happened to have used it everywhere else where a
        # static date was needed.
        am_pm = []
        for hour in (01,22):
            time_tuple = time.struct_time((1999,3,17,hour,44,55,2,76,0))
            am_pm.append(time.strftime("%p", time_tuple).lower())
        self.am_pm = am_pm

    def __calc_date_time(self):
        # Set self.date_time, self.date, & self.time by using
        # time.strftime().

        # Use (1999,3,17,22,44,55,2,76,0) for magic date because the amount of
        # overloaded numbers is minimized.  The order in which searches for
        # values within the format string is very important; it eliminates
        # possible ambiguity for what something represents.
        time_tuple = time.struct_time((1999,3,17,22,44,55,2,76,0))
        date_time = [None, None, None]
        date_time[0] = time.strftime("%c", time_tuple).lower()
        date_time[1] = time.strftime("%x", time_tuple).lower()
        date_time[2] = time.strftime("%X", time_tuple).lower()
        replacement_pairs = [('%', '%%'), (self.f_weekday[2], '%A'),
                    (self.f_month[3], '%B'), (self.a_weekday[2], '%a'),
                    (self.a_month[3], '%b'), (self.am_pm[1], '%p'),
                    ('1999', '%Y'), ('99', '%y'), ('22', '%H'),
                    ('44', '%M'), ('55', '%S'), ('76', '%j'),
                    ('17', '%d'), ('03', '%m'), ('3', '%m'),
                    # '3' needed for when no leading zero.
                    ('2', '%w'), ('10', '%I')]
        replacement_pairs.extend([(tz, "%Z") for tz_values in self.timezone
                                                for tz in tz_values])
        for offset,directive in ((0,'%c'), (1,'%x'), (2,'%X')):
            current_format = date_time[offset]
            for old, new in replacement_pairs:
                # Must deal with possible lack of locale info
                # manifesting itself as the empty string (e.g., Swedish's
                # lack of AM/PM info) or a platform returning a tuple of empty
                # strings (e.g., MacOS 9 having timezone as ('','')).
                if old:
                    current_format = current_format.replace(old, new)
            # If %W is used, then Sunday, 2005-01-03 will fall on week 0 since
            # 2005-01-03 occurs before the first Monday of the year.  Otherwise
            # %U is used.
            time_tuple = time.struct_time((1999,1,3,1,1,1,6,3,0))
            if '00' in time.strftime(directive, time_tuple):
                U_W = '%W'
            else:
                U_W = '%U'
            date_time[offset] = current_format.replace('11', U_W)
        self.LC_date_time = date_time[0]
        self.LC_date = date_time[1]
        self.LC_time = date_time[2]

    def __calc_timezone(self):
        # Set self.timezone by using time.tzname.
        # Do not worry about possibility of time.tzname[0] == timetzname[1]
        # and time.daylight; handle that in strptime .
        try:
            time.tzset()
        except AttributeError:
            pass
        no_saving = frozenset(["utc", "gmt", time.tzname[0].lower()])
        if time.daylight:
            has_saving = frozenset([time.tzname[1].lower()])
        else:
            has_saving = frozenset()
        self.timezone = (no_saving, has_saving)


class TimeRE(dict):
    """Handle conversion from format directives to regexes."""

    def __init__(self, locale_time=None):
        """Create keys/values.

        Order of execution is important for dependency reasons.

        """
        if locale_time:
            self.locale_time = locale_time
        else:
            self.locale_time = LocaleTime()
        base = super(TimeRE, self)
        base.__init__({
            # The " \d" part of the regex is to make %c from ANSI C work
            'd': r"(?P<d>3[0-1]|[1-2]\d|0[1-9]|[1-9]| [1-9])",
            'f': r"(?P<f>[0-9]{1,9})",
            'H': r"(?P<H>2[0-3]|[0-1]\d|\d)",
            'I': r"(?P<I>1[0-2]|0[1-9]|[1-9])",
            'j': r"(?P<j>36[0-6]|3[0-5]\d|[1-2]\d\d|0[1-9]\d|00[1-9]|[1-9]\d|0[1-9]|[1-9])",
            'm': r"(?P<m>1[0-2]|0[1-9]|[1-9])",
            'M': r"(?P<M>[0-5]\d|\d)",
            'S': r"(?P<S>6[0-1]|[0-5]\d|\d)",
            'U': r"(?P<U>5[0-3]|[0-4]\d|\d)",
            'w': r"(?P<w>[0-6])",
            # W is set below by using 'U'
            'y': r"(?P<y>\d\d)",
            #XXX: Does 'Y' need to worry about having less or more than
            #     4 digits?
            'Y': r"(?P<Y>\d\d\d\d)",
            'A': self.__seqToRE(self.locale_time.f_weekday, 'A'),
            'a': self.__seqToRE(self.locale_time.a_weekday, 'a'),
            'B': self.__seqToRE(self.locale_time.f_month[1:], 'B'),
            'b': self.__seqToRE(self.locale_time.a_month[1:], 'b'),
            'p': self.__seqToRE(self.locale_time.am_pm, 'p'),
            'Z': self.__seqToRE((tz for tz_names in self.locale_time.timezone
                                        for tz in tz_names),
                                'Z'),
            '%': '%'})
        base.__setitem__('W', base.__getitem__('U').replace('U', 'W'))
        base.__setitem__('c', self.pattern(self.locale_time.LC_date_time))
        base.__setitem__('x', self.pattern(self.locale_time.LC_date))
        base.__setitem__('X', self.pattern(self.locale_time.LC_time))

    def __seqToRE(self, to_convert, directive):
        """Convert a list to a regex string for matching a directive.

        Want possible matching values to be from longest to shortest.  This
        prevents the possibility of a match occuring for a value that also
        a substring of a larger value that should have matched (e.g., 'abc'
        matching when 'abcdef' should have been the match).

        """
        to_convert = sorted(to_convert, key=len, reverse=True)
        for value in to_convert:
            if value != '':
                break
        else:
            return ''
        regex = '|'.join(re_escape(stuff) for stuff in to_convert)
        regex = '(?P<%s>%s' % (directive, regex)
        return '%s)' % regex

    def pattern(self, format):
        """Return regex pattern for the format string.

        Need to make sure that any characters that might be interpreted as
        regex syntax are escaped.

        """
        processed_format = ''
        # The sub() call escapes all characters that might be misconstrued
        # as regex syntax.  Cannot use re.escape since we have to deal with
        # format directives (%m, etc.).
        regex_chars = re_compile(r"([\\.^$*+?\(\){}\[\]|])")
        format = regex_chars.sub(r"\\\1", format)
        whitespace_replacement = re_compile('\s+')
        format = whitespace_replacement.sub('\s+', format)
        while '%' in format:
            directive_index = format.index('%')+1
            processed_format = "%s%s%s" % (processed_format,
                                           format[:directive_index-1],
                                           self[format[directive_index]])
            format = format[directive_index+1:]
        return "%s%s" % (processed_format, format)

    def compile(self, format):
        """Return a compiled re object for the format string."""
        return re_compile(self.pattern(format), IGNORECASE)

_cache_lock = _thread_allocate_lock()
# DO NOT modify _TimeRE_cache or _regex_cache without acquiring the cache lock
# first!
_TimeRE_cache = TimeRE()
_CACHE_MAX_SIZE = 5 # Max number of regexes stored in _regex_cache
_regex_cache = {}

cdef _calc_julian_from_U_or_W(int year, int week_of_year, int day_of_week, int week_starts_Mon):
    """Calculate the Julian day based on the year, week of the year, and day of
    the week, with week_start_day representing whether the week of the year
    assumes the week starts on Sunday or Monday (6 or 0)."""

    cdef:
        int first_weekday,  week_0_length, days_to_week

    first_weekday = datetime_date(year, 1, 1).weekday()
    # If we are dealing with the %U directive (week starts on Sunday), it's
    # easier to just shift the view to Sunday being the first day of the
    # week.
    if not week_starts_Mon:
        first_weekday = (first_weekday + 1) % 7
        day_of_week = (day_of_week + 1) % 7
    # Need to watch out for a week 0 (when the first day of the year is not
    # the same as that specified by %U or %W).
    week_0_length = (7 - first_weekday) % 7
    if week_of_year == 0:
        return 1 + day_of_week - first_weekday
    else:
        days_to_week = week_0_length + (7 * (week_of_year - 1))
        return 1 + days_to_week + day_of_week

# def _strptime_time(data_string, format="%a %b %d %H:%M:%S %Y"):
#     return _strptime(data_string, format)[0]
