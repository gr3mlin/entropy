.. currentmodule:: pandas
.. _computation:

.. ipython:: python
   :suppress:

   import numpy as np
   np.random.seed(123456)
   from pandas import *
   import pandas.util.testing as tm
   randn = np.random.randn
   np.set_printoptions(precision=4, suppress=True)
   import matplotlib.pyplot as plt
   plt.close('all')
   options.display.mpl_style='default'
   options.display.max_rows=15

Computational tools
===================

Statistical functions
---------------------

.. _computation.pct_change:

Percent Change
~~~~~~~~~~~~~~

``Series``, ``DataFrame``, and ``Panel`` all have a method ``pct_change`` to compute the
percent change over a given number of periods (using ``fill_method`` to fill
NA/null values *before* computing the percent change).

.. ipython:: python

   ser = Series(randn(8))

   ser.pct_change()

.. ipython:: python

   df = DataFrame(randn(10, 4))

   df.pct_change(periods=3)

.. _computation.covariance:

Covariance
~~~~~~~~~~

The ``Series`` object has a method ``cov`` to compute covariance between series
(excluding NA/null values).

.. ipython:: python

   s1 = Series(randn(1000))
   s2 = Series(randn(1000))
   s1.cov(s2)

Analogously, ``DataFrame`` has a method ``cov`` to compute pairwise covariances
among the series in the DataFrame, also excluding NA/null values.

.. _computation.covariance.caveats:

.. note::

    Assuming the missing data are missing at random this results in an estimate
    for the covariance matrix which is unbiased. However, for many applications
    this estimate may not be acceptable because the estimated covariance matrix
    is not guaranteed to be positive semi-definite. This could lead to
    estimated correlations having absolute values which are greater than one,
    and/or a non-invertible covariance matrix. See `Estimation of covariance
    matrices <http://en.wikipedia.org/w/index.php?title=Estimation_of_covariance_matrices>`_
    for more details.

.. ipython:: python

   frame = DataFrame(randn(1000, 5), columns=['a', 'b', 'c', 'd', 'e'])
   frame.cov()

``DataFrame.cov`` also supports an optional ``min_periods`` keyword that
specifies the required minimum number of observations for each column pair
in order to have a valid result.

.. ipython:: python

   frame = DataFrame(randn(20, 3), columns=['a', 'b', 'c'])
   frame.ix[:5, 'a'] = np.nan
   frame.ix[5:10, 'b'] = np.nan

   frame.cov()

   frame.cov(min_periods=12)


.. _computation.correlation:

Correlation
~~~~~~~~~~~

Several methods for computing correlations are provided:

.. csv-table::
    :header: "Method name", "Description"
    :widths: 20, 80

    ``pearson (default)``, Standard correlation coefficient
    ``kendall``, Kendall Tau correlation coefficient
    ``spearman``, Spearman rank correlation coefficient

.. \rho = \cov(x, y) / \sigma_x \sigma_y

All of these are currently computed using pairwise complete observations.

.. note::

    Please see the :ref:`caveats <computation.covariance.caveats>` associated
    with this method of calculating correlation matrices in the
    :ref:`covariance section <computation.covariance>`.

.. ipython:: python

   frame = DataFrame(randn(1000, 5), columns=['a', 'b', 'c', 'd', 'e'])
   frame.ix[::2] = np.nan

   # Series with Series
   frame['a'].corr(frame['b'])
   frame['a'].corr(frame['b'], method='spearman')

   # Pairwise correlation of DataFrame columns
   frame.corr()

Note that non-numeric columns will be automatically excluded from the
correlation calculation.

Like ``cov``, ``corr`` also supports the optional ``min_periods`` keyword:

.. ipython:: python

   frame = DataFrame(randn(20, 3), columns=['a', 'b', 'c'])
   frame.ix[:5, 'a'] = np.nan
   frame.ix[5:10, 'b'] = np.nan

   frame.corr()

   frame.corr(min_periods=12)


A related method ``corrwith`` is implemented on DataFrame to compute the
correlation between like-labeled Series contained in different DataFrame
objects.

.. ipython:: python

   index = ['a', 'b', 'c', 'd', 'e']
   columns = ['one', 'two', 'three', 'four']
   df1 = DataFrame(randn(5, 4), index=index, columns=columns)
   df2 = DataFrame(randn(4, 4), index=index[:4], columns=columns)
   df1.corrwith(df2)
   df2.corrwith(df1, axis=1)

.. _computation.ranking:

Data ranking
~~~~~~~~~~~~

The ``rank`` method produces a data ranking with ties being assigned the mean
of the ranks (by default) for the group:

.. ipython:: python

   s = Series(np.random.randn(5), index=list('abcde'))
   s['d'] = s['b'] # so there's a tie
   s.rank()

``rank`` is also a DataFrame method and can rank either the rows (``axis=0``)
or the columns (``axis=1``). ``NaN`` values are excluded from the ranking.

.. ipython:: python

   df = DataFrame(np.random.randn(10, 6))
   df[4] = df[2][:5] # some ties
   df
   df.rank(1)

``rank`` optionally takes a parameter ``ascending`` which by default is true;
when false, data is reverse-ranked, with larger values assigned a smaller rank.

``rank`` supports different tie-breaking methods, specified with the ``method``
parameter:

  - ``average`` : average rank of tied group
  - ``min`` : lowest rank in the group
  - ``max`` : highest rank in the group
  - ``first`` : ranks assigned in the order they appear in the array


.. currentmodule:: pandas

.. currentmodule:: pandas.stats.api

.. _stats.moments:

Moving (rolling) statistics / moments
-------------------------------------

For working with time series data, a number of functions are provided for
computing common *moving* or *rolling* statistics. Among these are count, sum,
mean, median, correlation, variance, covariance, standard deviation, skewness,
and kurtosis. All of these methods are in the :mod:`pandas` namespace, but
otherwise they can be found in :mod:`pandas.stats.moments`.

.. csv-table::
    :header: "Function", "Description"
    :widths: 20, 80

    ``rolling_count``, Number of non-null observations
    ``rolling_sum``, Sum of values
    ``rolling_mean``, Mean of values
    ``rolling_median``, Arithmetic median of values
    ``rolling_min``, Minimum
    ``rolling_max``, Maximum
    ``rolling_std``, Unbiased standard deviation
    ``rolling_var``, Unbiased variance
    ``rolling_skew``, Unbiased skewness (3rd moment)
    ``rolling_kurt``, Unbiased kurtosis (4th moment)
    ``rolling_quantile``, Sample quantile (value at %)
    ``rolling_apply``, Generic apply
    ``rolling_cov``, Unbiased covariance (binary)
    ``rolling_corr``, Correlation (binary)
    ``rolling_window``, Moving window function

Generally these methods all have the same interface. The binary operators
(e.g. ``rolling_corr``) take two Series or DataFrames. Otherwise, they all
accept the following arguments:

  - ``window``: size of moving window
  - ``min_periods``: threshold of non-null data points to require (otherwise
    result is NA)
  - ``freq``: optionally specify a :ref:`frequency string <timeseries.alias>`
    or :ref:`DateOffset <timeseries.offsets>` to pre-conform the data to.
    Note that prior to pandas v0.8.0, a keyword argument ``time_rule`` was used
    instead of ``freq`` that referred to the legacy time rule constants
  - ``how``: optionally specify method for down or re-sampling.  Default is
    is min for ``rolling_min``, max for ``rolling_max``, median for
    ``rolling_median``, and mean for all other rolling functions.  See
    :meth:`DataFrame.resample`'s how argument for more information.

These functions can be applied to ndarrays or Series objects:

.. ipython:: python

   ts = Series(randn(1000), index=date_range('1/1/2000', periods=1000))
   ts = ts.cumsum()

   ts.plot(style='k--')

   @savefig rolling_mean_ex.png
   rolling_mean(ts, 60).plot(style='k')

They can also be applied to DataFrame objects. This is really just syntactic
sugar for applying the moving window operator to all of the DataFrame's columns:

.. ipython:: python
   :suppress:

   plt.close('all')

.. ipython:: python

   df = DataFrame(randn(1000, 4), index=ts.index,
                  columns=['A', 'B', 'C', 'D'])
   df = df.cumsum()

   @savefig rolling_mean_frame.png
   rolling_sum(df, 60).plot(subplots=True)

The ``rolling_apply`` function takes an extra ``func`` argument and performs
generic rolling computations. The ``func`` argument should be a single function
that produces a single value from an ndarray input. Suppose we wanted to
compute the mean absolute deviation on a rolling basis:

.. ipython:: python

   mad = lambda x: np.fabs(x - x.mean()).mean()
   @savefig rolling_apply_ex.png
   rolling_apply(ts, 60, mad).plot(style='k')

The ``rolling_window`` function performs a generic rolling window computation
on the input data. The weights used in the window are specified by the ``win_type``
keyword. The list of recognized types are:

    - ``boxcar``
    - ``triang``
    - ``blackman``
    - ``hamming``
    - ``bartlett``
    - ``parzen``
    - ``bohman``
    - ``blackmanharris``
    - ``nuttall``
    - ``barthann``
    - ``kaiser`` (needs beta)
    - ``gaussian`` (needs std)
    - ``general_gaussian`` (needs power, width)
    - ``slepian`` (needs width).

.. ipython:: python

   ser = Series(randn(10), index=date_range('1/1/2000', periods=10))

   rolling_window(ser, 5, 'triang')

Note that the ``boxcar`` window is equivalent to ``rolling_mean``.

.. ipython:: python

   rolling_window(ser, 5, 'boxcar')

   rolling_mean(ser, 5)

For some windowing functions, additional parameters must be specified:

.. ipython:: python

   rolling_window(ser, 5, 'gaussian', std=0.1)

By default the labels are set to the right edge of the window, but a
``center`` keyword is available so the labels can be set at the center.
This keyword is available in other rolling functions as well.

.. ipython:: python

   rolling_window(ser, 5, 'boxcar')

   rolling_window(ser, 5, 'boxcar', center=True)

   rolling_mean(ser, 5, center=True)

.. _stats.moments.normalization:

.. note::

    In rolling sum mode (``mean=False``) there is no normalization done to the
    weights. Passing custom weights of ``[1, 1, 1]`` will yield a different
    result than passing weights of ``[2, 2, 2]``, for example. When passing a
    ``win_type`` instead of explicitly specifying the weights, the weights are
    already normalized so that the largest weight is 1.

    In contrast, the nature of the rolling mean calculation (``mean=True``)is
    such that the weights are normalized with respect to each other. Weights
    of ``[1, 1, 1]`` and ``[2, 2, 2]`` yield the same result.

.. _stats.moments.binary:

Binary rolling moments
~~~~~~~~~~~~~~~~~~~~~~

``rolling_cov`` and ``rolling_corr`` can compute moving window statistics about
two ``Series`` or any combination of ``DataFrame/Series`` or
``DataFrame/DataFrame``. Here is the behavior in each case:

- two ``Series``: compute the statistic for the pairing.
- ``DataFrame/Series``: compute the statistics for each column of the DataFrame
  with the passed Series, thus returning a DataFrame.
- ``DataFrame/DataFrame``: by default compute the statistic for matching column
  names, returning a DataFrame. If the keyword argument ``pairwise=True`` is
  passed then computes the statistic for each pair of columns, returning a
  ``Panel`` whose ``items`` are the dates in question (see :ref:`the next section
  <stats.moments.corr_pairwise>`).

For example:

.. ipython:: python

   df2 = df[:20]
   rolling_corr(df2, df2['B'], window=5)

.. _stats.moments.corr_pairwise:

Computing rolling pairwise covariances and correlations
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

In financial data analysis and other fields it's common to compute covariance
and correlation matrices for a collection of time series. Often one is also
interested in moving-window covariance and correlation matrices. This can be
done by passing the ``pairwise`` keyword argument, which in the case of
``DataFrame`` inputs will yield a ``Panel`` whose ``items`` are the dates in
question. In the case of a single DataFrame argument the ``pairwise`` argument
can even be omitted:

.. note::

    Missing values are ignored and each entry is computed using the pairwise
    complete observations.  Please see the :ref:`covariance section
    <computation.covariance>` for :ref:`caveats
    <computation.covariance.caveats>` associated with this method of
    calculating covariance and correlation matrices.

.. ipython:: python

   covs = rolling_cov(df[['B','C','D']], df[['A','B','C']], 50, pairwise=True)
   covs[df.index[-50]]

.. ipython:: python

   correls = rolling_corr(df, 50)
   correls[df.index[-50]]

.. note::

    Prior to version 0.14 this was available through ``rolling_corr_pairwise``
    which is now simply syntactic sugar for calling ``rolling_corr(...,
    pairwise=True)`` and deprecated. This is likely to be removed in a future
    release.

You can efficiently retrieve the time series of correlations between two
columns using ``ix`` indexing:

.. ipython:: python
   :suppress:

   plt.close('all')

.. ipython:: python

   @savefig rolling_corr_pairwise_ex.png
   correls.ix[:, 'A', 'C'].plot()

.. _stats.moments.expanding:

Expanding window moment functions
---------------------------------
A common alternative to rolling statistics is to use an *expanding* window,
which yields the value of the statistic with all the data available up to that
point in time. As these calculations are a special case of rolling statistics,
they are implemented in pandas such that the following two calls are equivalent:

.. ipython:: python

   rolling_mean(df, window=len(df), min_periods=1)[:5]

   expanding_mean(df)[:5]

Like the ``rolling_`` functions, the following methods are included in the
``pandas`` namespace or can be located in ``pandas.stats.moments``.

.. csv-table::
    :header: "Function", "Description"
    :widths: 20, 80

    ``expanding_count``, Number of non-null observations
    ``expanding_sum``, Sum of values
    ``expanding_mean``, Mean of values
    ``expanding_median``, Arithmetic median of values
    ``expanding_min``, Minimum
    ``expanding_max``, Maximum
    ``expanding_std``, Unbiased standard deviation
    ``expanding_var``, Unbiased variance
    ``expanding_skew``, Unbiased skewness (3rd moment)
    ``expanding_kurt``, Unbiased kurtosis (4th moment)
    ``expanding_quantile``, Sample quantile (value at %)
    ``expanding_apply``, Generic apply
    ``expanding_cov``, Unbiased covariance (binary)
    ``expanding_corr``, Correlation (binary)

Aside from not having a ``window`` parameter, these functions have the same
interfaces as their ``rolling_`` counterpart. Like above, the parameters they
all accept are:

  - ``min_periods``: threshold of non-null data points to require. Defaults to
    minimum needed to compute statistic. No ``NaNs`` will be output once
    ``min_periods`` non-null data points have been seen.
  - ``freq``: optionally specify a :ref:`frequency string <timeseries.alias>`
    or :ref:`DateOffset <timeseries.offsets>` to pre-conform the data to.
    Note that prior to pandas v0.8.0, a keyword argument ``time_rule`` was used
    instead of ``freq`` that referred to the legacy time rule constants

.. note::

   The output of the ``rolling_`` and ``expanding_`` functions do not return a
   ``NaN`` if there are at least ``min_periods`` non-null values in the current
   window. This differs from ``cumsum``, ``cumprod``, ``cummax``, and
   ``cummin``, which return ``NaN`` in the output wherever a ``NaN`` is
   encountered in the input.

An expanding window statistic will be more stable (and less responsive) than
its rolling window counterpart as the increasing window size decreases the
relative impact of an individual data point. As an example, here is the
``expanding_mean`` output for the previous time series dataset:

.. ipython:: python
   :suppress:

   plt.close('all')

.. ipython:: python

   ts.plot(style='k--')

   @savefig expanding_mean_frame.png
   expanding_mean(ts).plot(style='k')

.. _stats.moments.exponentially_weighted:

Exponentially weighted moment functions
---------------------------------------

A related set of functions are exponentially weighted versions of several of
the above statistics. A number of expanding EW (exponentially weighted)
functions are provided:

.. csv-table::
    :header: "Function", "Description"
    :widths: 20, 80

    ``ewma``, EW moving average
    ``ewmvar``, EW moving variance
    ``ewmstd``, EW moving standard deviation
    ``ewmcorr``, EW moving correlation
    ``ewmcov``, EW moving covariance

In general, a weighted moving average is calculated as

.. math::

    y_t = \frac{\sum_{i=0}^t w_i x_{t-i}}{\sum_{i=0}^t w_i},

where :math:`x_t` is the input at :math:`y_t` is the result.

The EW functions support two variants of exponential weights:
The default, ``adjust=True``, uses the weights :math:`w_i = (1 - \alpha)^i`.
When ``adjust=False`` is specified, moving averages are calculated as

.. math::

    y_0 &= x_0 \\
    y_t &= (1 - \alpha) y_{t-1} + \alpha x_t,

which is equivalent to using weights

.. math::

    w_i = \begin{cases}
        \alpha (1 - \alpha)^i & \text{if } i < t \\
        (1 - \alpha)^i        & \text{if } i = t.
    \end{cases}

.. note::

   These equations are sometimes written in terms of :math:`\alpha' = 1 - \alpha`, e.g.

   .. math::

      y_t = \alpha' y_{t-1} + (1 - \alpha') x_t.

One must have :math:`0 < \alpha \leq 1`, but rather than pass :math:`\alpha`
directly, it's easier to think about either the **span**, **center of mass
(com)** or **halflife** of an EW moment:

.. math::

   \alpha =
    \begin{cases}
        \frac{2}{s + 1},               & s = \text{span}\\
        \frac{1}{1 + c},               & c = \text{center of mass}\\
        1 - \exp^{\frac{\log 0.5}{h}}, & h = \text{half life}
    \end{cases}

One must specify precisely one of the three to the EW functions. **Span**
corresponds to what is commonly called a "20-day EW moving average" for
example. **Center of mass** has a more physical interpretation. For example,
**span** = 20 corresponds to **com** = 9.5. **Halflife** is the period of
time for the exponential weight to reduce to one half.

Here is an example for a univariate time series:

.. ipython:: python

   plt.close('all')
   ts.plot(style='k--')

   @savefig ewma_ex.png
   ewma(ts, span=20).plot(style='k')

All the EW functions have a ``min_periods`` argument, which has the same
meaning it does for all the ``expanding_`` and ``rolling_`` functions:
no output values will be set until at least ``min_periods`` non-null values
are encountered in the (expanding) window.
(This is a change from versions prior to 0.15.0, in which the ``min_periods``
argument affected only the ``min_periods`` consecutive entries starting at the
first non-null value.)

All the EW functions also have an ``ignore_na`` argument, which deterines how
intermediate null values affect the calculation of the weights.
When ``ignore_na=False`` (the default), weights are calculated based on absolute
positions, so that intermediate null values affect the result.
When ``ignore_na=True`` (which reproduces the behavior in versions prior to 0.15.0),
weights are calculated by ignoring intermediate null values.
For example, assuming ``adjust=True``, if ``ignore_na=False``, the weighted
average of ``3, NaN, 5`` would be calculated as

.. math::

	\frac{(1-\alpha)^2 \cdot 3 + 1 \cdot 5}{(1-\alpha)^2 + 1}

Whereas if ``ignore_na=True``, the weighted average would be calculated as

.. math::

	\frac{(1-\alpha) \cdot 3 + 1 \cdot 5}{(1-\alpha) + 1}.

The ``ewmvar``, ``ewmstd``, and ``ewmcov`` functions have a ``bias`` argument,
specifying whether the result should contain biased or unbiased statistics.
For example, if ``bias=True``, ``ewmvar(x)`` is calculated as
``ewmvar(x) = ewma(x**2) - ewma(x)**2``;
whereas if ``bias=False`` (the default), the biased variance statistics
are scaled by debiasing factors

.. math::

    \frac{\left(\sum_{i=0}^t w_i\right)^2}{\left(\sum_{i=0}^t w_i\right)^2 - \sum_{i=0}^t w_i^2}.

(For :math:`w_i = 1`, this reduces to the usual :math:`N / (N - 1)` factor,
with :math:`N = t + 1`.)
See http://en.wikipedia.org/wiki/Weighted_arithmetic_mean#Weighted_sample_variance
for further details.
