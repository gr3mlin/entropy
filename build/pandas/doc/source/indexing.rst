.. _indexing:

.. currentmodule:: pandas

.. ipython:: python
   :suppress:

   import numpy as np
   import random
   np.random.seed(123456)
   from pandas import *
   options.display.max_rows=15
   import pandas as pd
   randn = np.random.randn
   randint = np.random.randint
   np.set_printoptions(precision=4, suppress=True)
   from pandas.compat import range, zip

***************************
Indexing and Selecting Data
***************************

The axis labeling information in pandas objects serves many purposes:

  - Identifies data (i.e. provides *metadata*) using known indicators,
    important for analysis, visualization, and interactive console display
  - Enables automatic and explicit data alignment
  - Allows intuitive getting and setting of subsets of the data set

In this section, we will focus on the final point: namely, how to slice, dice,
and generally get and set subsets of pandas objects. The primary focus will be
on Series and DataFrame as they have received more development attention in
this area. Expect more work to be invested higher-dimensional data structures
(including ``Panel``) in the future, especially in label-based advanced
indexing.

.. note::

   The Python and NumPy indexing operators ``[]`` and attribute operator ``.``
   provide quick and easy access to pandas data structures across a wide range
   of use cases. This makes interactive work intuitive, as there's little new
   to learn if you already know how to deal with Python dictionaries and NumPy
   arrays. However, since the type of the data to be accessed isn't known in
   advance, directly using standard operators has some optimization limits. For
   production code, we recommended that you take advantage of the optimized
   pandas data access methods exposed in this chapter.

.. warning::

   Whether a copy or a reference is returned for a setting operation, may
   depend on the context.  This is sometimes called ``chained assignment`` and
   should be avoided.  See :ref:`Returning a View versus Copy
   <indexing.view_versus_copy>`

.. warning::

   In 0.15.0 ``Index`` has internally been refactored to no longer sub-class ``ndarray``
   but instead subclass ``PandasObject``, similarly to the rest of the pandas objects. This should be
   a transparent change with only very limited API implications (See the :ref:`Internal Refactoring <whatsnew_0150.refactoring>`)

See the :ref:`MultiIndex / Advanced Indexing <advanced>` for ``MultiIndex`` and more advanced indexing documentation.

See the :ref:`cookbook<cookbook.selection>` for some advanced strategies

Different Choices for Indexing
------------------------------

.. versionadded:: 0.11.0

Object selection has had a number of user-requested additions in order to
support more explicit location based indexing. pandas now supports three types
of multi-axis indexing.

- ``.loc`` is strictly label based, will raise ``KeyError`` when the items are
  not found, allowed inputs are:

  - A single label, e.g. ``5`` or ``'a'``, (note that ``5`` is interpreted as a
    *label* of the index. This use is **not** an integer position along the
    index)
  - A list or array of labels ``['a', 'b', 'c']``
  - A slice object with labels ``'a':'f'``, (note that contrary to usual python
    slices, **both** the start and the stop are included!)
  - A boolean array

  See more at :ref:`Selection by Label <indexing.label>`

- ``.iloc`` is primarily integer position based (from ``0`` to
  ``length-1`` of the axis), but may also be used with a boolean
  array.  ``.iloc`` will raise ``IndexError`` if a requested 
  indexer is out-of-bounds, except *slice* indexers which allow
  out-of-bounds indexing.  (this conforms with python/numpy *slice*
  semantics).  Allowed inputs are:

  - An integer e.g. ``5``
  - A list or array of integers ``[4, 3, 0]``
  - A slice object with ints ``1:7``
  - A boolean array

  See more at :ref:`Selection by Position <indexing.integer>`

- ``.ix`` supports mixed integer and label based access. It is primarily label
  based, but will fall back to integer positional access unless the corresponding
  axis is of integer type. ``.ix`` is the most general and will
  support any of the inputs in ``.loc`` and ``.iloc``. ``.ix`` also supports floating point
  label schemes. ``.ix`` is exceptionally useful when dealing with mixed positional
  and label based hierachical indexes.

  However, when an axis is integer based, ONLY
  label based access and not positional access is supported.
  Thus, in such cases, it's usually better to be explicit and use ``.iloc`` or ``.loc``.

  See more at :ref:`Advanced Indexing <advanced>` and :ref:`Advanced
  Hierarchical <advanced.advanced_hierarchical>`.

Getting values from an object with multi-axes selection uses the following
notation (using ``.loc`` as an example, but applies to ``.iloc`` and ``.ix`` as
well). Any of the axes accessors may be the null slice ``:``. Axes left out of
the specification are assumed to be ``:``. (e.g. ``p.loc['a']`` is equiv to
``p.loc['a', :, :]``)

.. csv-table::
    :header: "Object Type", "Indexers"
    :widths: 30, 50
    :delim: ;

    Series; ``s.loc[indexer]``
    DataFrame; ``df.loc[row_indexer,column_indexer]``
    Panel; ``p.loc[item_indexer,major_indexer,minor_indexer]``

Deprecations
------------

Beginning with version 0.11.0, it's recommended that you transition away from
the following methods as they *may* be deprecated in future versions.

  - ``irow``
  - ``icol``
  - ``iget_value``

See the section :ref:`Selection by Position <indexing.integer>` for substitutes.

.. _indexing.basics:

Basics
------

As mentioned when introducing the data structures in the :ref:`last section
<basics>`, the primary function of indexing with ``[]`` (a.k.a. ``__getitem__``
for those familiar with implementing class behavior in Python) is selecting out
lower-dimensional slices. Thus,

.. csv-table::
    :header: "Object Type", "Selection", "Return Value Type"
    :widths: 30, 30, 60
    :delim: ;

    Series; ``series[label]``; scalar value
    DataFrame; ``frame[colname]``; ``Series`` corresponding to colname
    Panel; ``panel[itemname]``; ``DataFrame`` corresponing to the itemname

Here we construct a simple time series data set to use for illustrating the
indexing functionality:

.. ipython:: python

   dates = date_range('1/1/2000', periods=8)
   df = DataFrame(randn(8, 4), index=dates, columns=['A', 'B', 'C', 'D'])
   df
   panel = Panel({'one' : df, 'two' : df - df.mean()})
   panel

.. note::

   None of the indexing functionality is time series specific unless
   specifically stated.

Thus, as per above, we have the most basic indexing using ``[]``:

.. ipython:: python

   s = df['A']
   s[dates[5]]
   panel['two']

You can pass a list of columns to ``[]`` to select columns in that order.
If a column is not contained in the DataFrame, an exception will be
raised. Multiple columns can also be set in this manner:

.. ipython:: python

   df
   df[['B', 'A']] = df[['A', 'B']]
   df

You may find this useful for applying a transform (in-place) to a subset of the
columns.

Attribute Access
----------------

.. _indexing.columns.multiple:

.. _indexing.df_cols:

.. _indexing.attribute_access:

You may access an index on a ``Series``, column on a ``DataFrame``, and a item on a ``Panel`` directly
as an attribute:

.. ipython:: python

   sa = Series([1,2,3],index=list('abc'))
   dfa = df.copy()

.. ipython:: python

   sa.b
   dfa.A
   panel.one

You can use attribute access to modify an existing element of a Series or column of a DataFrame, but be careful;
if you try to use attribute access to create a new column, it fails silently, creating a new attribute rather than a
new column.

.. ipython:: python

   sa.a = 5
   sa
   dfa.A = list(range(len(dfa.index)))       # ok if A already exists
   dfa
   dfa['A'] = list(range(len(dfa.index)))    # use this form to create a new column
   dfa

.. warning::

   - You can use this access only if the index element is a valid python identifier, e.g. ``s.1`` is not allowed.
     See `here for an explanation of valid identifiers
     <http://docs.python.org/2.7/reference/lexical_analysis.html#identifiers>`__.

   - The attribute will not be available if it conflicts with an existing method name, e.g. ``s.min`` is not allowed.

   - Similarly, the attribute will not be available if it conflicts with any of the following list: ``index``,
     ``major_axis``, ``minor_axis``, ``items``, ``labels``.

   - In any of these cases, standard indexing will still work, e.g. ``s['1']``, ``s['min']``, and ``s['index']`` will
     access the corresponding element or column.

   - The ``Series/Panel`` accesses are available starting in 0.13.0.

If you are using the IPython environment, you may also use tab-completion to
see these accessible attributes.

Slicing ranges
--------------

The most robust and consistent way of slicing ranges along arbitrary axes is
described in the :ref:`Selection by Position <indexing.integer>` section
detailing the ``.iloc`` method. For now, we explain the semantics of slicing using the ``[]`` operator.

With Series, the syntax works exactly as with an ndarray, returning a slice of
the values and the corresponding labels:

.. ipython:: python

   s[:5]
   s[::2]
   s[::-1]

Note that setting works as well:

.. ipython:: python

   s2 = s.copy()
   s2[:5] = 0
   s2

With DataFrame, slicing inside of ``[]`` **slices the rows**. This is provided
largely as a convenience since it is such a common operation.

.. ipython:: python

   df[:3]
   df[::-1]

.. _indexing.label:

Selection By Label
------------------

.. warning::

   Whether a copy or a reference is returned for a setting operation, may depend on the context.
   This is sometimes called ``chained assignment`` and should be avoided.
   See :ref:`Returning a View versus Copy <indexing.view_versus_copy>`

pandas provides a suite of methods in order to have **purely label based indexing**. This is a strict inclusion based protocol.
**at least 1** of the labels for which you ask, must be in the index or a ``KeyError`` will be raised! When slicing, the start bound is *included*, **AND** the stop bound is *included*. Integers are valid labels, but they refer to the label **and not the position**.

The ``.loc`` attribute is the primary access method. The following are valid inputs:

- A single label, e.g. ``5`` or ``'a'``, (note that ``5`` is interpreted as a *label* of the index. This use is **not** an integer position along the index)
- A list or array of labels ``['a', 'b', 'c']``
- A slice object with labels ``'a':'f'`` (note that contrary to usual python slices, **both** the start and the stop are included!)
- A boolean array

.. ipython:: python

   s1 = Series(np.random.randn(6),index=list('abcdef'))
   s1
   s1.loc['c':]
   s1.loc['b']

Note that setting works as well:

.. ipython:: python

   s1.loc['c':] = 0
   s1

With a DataFrame

.. ipython:: python

   df1 = DataFrame(np.random.randn(6,4),
                   index=list('abcdef'),
                   columns=list('ABCD'))
   df1
   df1.loc[['a','b','d'],:]

Accessing via label slices

.. ipython:: python

   df1.loc['d':,'A':'C']

For getting a cross section using a label (equiv to ``df.xs('a')``)

.. ipython:: python

   df1.loc['a']

For getting values with a boolean array

.. ipython:: python

   df1.loc['a']>0
   df1.loc[:,df1.loc['a']>0]

For getting a value explicitly (equiv to deprecated ``df.get_value('a','A')``)

.. ipython:: python

   # this is also equivalent to ``df1.at['a','A']``
   df1.loc['a','A']

.. _indexing.integer:

Selection By Position
---------------------

.. warning::

   Whether a copy or a reference is returned for a setting operation, may depend on the context.
   This is sometimes called ``chained assignment`` and should be avoided.
   See :ref:`Returning a View versus Copy <indexing.view_versus_copy>`

pandas provides a suite of methods in order to get **purely integer based indexing**. The semantics follow closely python and numpy slicing. These are ``0-based`` indexing. When slicing, the start bounds is *included*, while the upper bound is *excluded*. Trying to use a non-integer, even a **valid** label will raise a ``IndexError``.

The ``.iloc`` attribute is the primary access method. The following are valid inputs:

- An integer e.g. ``5``
- A list or array of integers ``[4, 3, 0]``
- A slice object with ints ``1:7``
- A boolean array

.. ipython:: python

   s1 = Series(np.random.randn(5),index=list(range(0,10,2)))
   s1
   s1.iloc[:3]
   s1.iloc[3]

Note that setting works as well:

.. ipython:: python

   s1.iloc[:3] = 0
   s1

With a DataFrame

.. ipython:: python

   df1 = DataFrame(np.random.randn(6,4),
                   index=list(range(0,12,2)),
                   columns=list(range(0,8,2)))
   df1

Select via integer slicing

.. ipython:: python

   df1.iloc[:3]
   df1.iloc[1:5,2:4]

Select via integer list

.. ipython:: python

   df1.iloc[[1,3,5],[1,3]]

For slicing rows explicitly (equiv to deprecated ``df.irow(slice(1,3))``).

.. ipython:: python

   df1.iloc[1:3,:]

For slicing columns explicitly (equiv to deprecated ``df.icol(slice(1,3))``).

.. ipython:: python

   df1.iloc[:,1:3]

For getting a scalar via integer position (equiv to deprecated ``df.get_value(1,1)``)

.. ipython:: python

   # this is also equivalent to ``df1.iat[1,1]``
   df1.iloc[1,1]

For getting a cross section using an integer position (equiv to ``df.xs(1)``)

.. ipython:: python

   df1.iloc[1]

Out of range slice indexes are handled gracefully just as in Python/Numpy.

.. ipython:: python

    # these are allowed in python/numpy.
    # Only works in Pandas starting from v0.14.0.
    x = list('abcdef')
    x
    x[4:10]
    x[8:10]
    s = Series(x)
    s
    s.iloc[4:10]
    s.iloc[8:10]

.. note::

    Prior to v0.14.0, ``iloc`` would not accept out of bounds indexers for
    slices, e.g. a value that exceeds the length of the object being indexed.


Note that this could result in an empty axis (e.g. an empty DataFrame being
returned)

.. ipython:: python

   dfl = DataFrame(np.random.randn(5,2),columns=list('AB'))
   dfl
   dfl.iloc[:,2:3]
   dfl.iloc[:,1:3]
   dfl.iloc[4:6]

A single indexer that is out of bounds will raise an ``IndexError``.
A list of indexers where any element is out of bounds will raise an
``IndexError``

.. code-block:: python

   dfl.iloc[[4,5,6]]
   IndexError: positional indexers are out-of-bounds

   dfl.iloc[:,4]
   IndexError: single positional indexer is out-of-bounds

.. _indexing.basics.partial_setting:

Setting With Enlargement
------------------------

.. versionadded:: 0.13

The ``.loc/.ix/[]`` operations can perform enlargement when setting a non-existant key for that axis.

In the ``Series`` case this is effectively an appending operation

.. ipython:: python

   se = Series([1,2,3])
   se
   se[5] = 5.
   se

A ``DataFrame`` can be enlarged on either axis via ``.loc``

.. ipython:: python

   dfi = DataFrame(np.arange(6).reshape(3,2),
                   columns=['A','B'])
   dfi
   dfi.loc[:,'C'] = dfi.loc[:,'A']
   dfi

This is like an ``append`` operation on the ``DataFrame``.

.. ipython:: python

   dfi.loc[3] = 5
   dfi

.. _indexing.basics.get_value:

Fast scalar value getting and setting
-------------------------------------

Since indexing with ``[]`` must handle a lot of cases (single-label access,
slicing, boolean indexing, etc.), it has a bit of overhead in order to figure
out what you're asking for. If you only want to access a scalar value, the
fastest way is to use the ``at`` and ``iat`` methods, which are implemented on
all of the data structures.

Similarly to ``loc``, ``at`` provides **label** based scalar lookups, while, ``iat`` provides **integer** based lookups analogously to ``iloc``

.. ipython:: python

   s.iat[5]
   df.at[dates[5], 'A']
   df.iat[3, 0]

You can also set using these same indexers.

.. ipython:: python

   df.at[dates[5], 'E'] = 7
   df.iat[3, 0] = 7

``at`` may enlarge the object in-place as above if the indexer is missing.

.. ipython:: python

   df.at[dates[-1]+1, 0] = 7
   df

Boolean indexing
----------------

.. _indexing.boolean:

Another common operation is the use of boolean vectors to filter the data.
The operators are: ``|`` for ``or``, ``&`` for ``and``, and ``~`` for ``not``. These **must** be grouped by using parentheses.

Using a boolean vector to index a Series works exactly as in a numpy ndarray:

.. ipython:: python

   s[s > 0]
   s[(s < 0) & (s > -0.5)]
   s[(s < -1) | (s > 1 )]
   s[~(s < 0)]

You may select rows from a DataFrame using a boolean vector the same length as
the DataFrame's index (for example, something derived from one of the columns
of the DataFrame):

.. ipython:: python

   df[df['A'] > 0]

List comprehensions and ``map`` method of Series can also be used to produce
more complex criteria:

.. ipython:: python

   df2 = DataFrame({'a' : ['one', 'one', 'two', 'three', 'two', 'one', 'six'],
                    'b' : ['x', 'y', 'y', 'x', 'y', 'x', 'x'],
                    'c' : randn(7)})

   # only want 'two' or 'three'
   criterion = df2['a'].map(lambda x: x.startswith('t'))

   df2[criterion]

   # equivalent but slower
   df2[[x.startswith('t') for x in df2['a']]]

   # Multiple criteria
   df2[criterion & (df2['b'] == 'x')]

Note, with the choice methods :ref:`Selection by Label <indexing.label>`, :ref:`Selection by Position <indexing.integer>`,
and :ref:`Advanced Indexing <advanced>` you may select along more than one axis using boolean vectors combined with other indexing expressions.

.. ipython:: python

   df2.loc[criterion & (df2['b'] == 'x'),'b':'c']

.. _indexing.basics.indexing_isin:

Indexing with isin
------------------

Consider the ``isin`` method of Series, which returns a boolean vector that is
true wherever the Series elements exist in the passed list. This allows you to
select rows where one or more columns have values you want:

.. ipython:: python

   s = Series(np.arange(5),index=np.arange(5)[::-1],dtype='int64')
   s
   s.isin([2, 4, 6])
   s[s.isin([2, 4, 6])]

The same method is available for ``Index`` objects and is useful for the cases
when you don't know which of the sought labels are in fact present:

.. ipython:: python

   s[s.index.isin([2, 4, 6])]

   # compare it to the following
   s[[2, 4, 6]]

In addition to that, ``MultiIndex`` allows selecting a separate level to use
in the membership check:

.. ipython:: python

   s_mi = Series(np.arange(6),
                 index=pd.MultiIndex.from_product([[0, 1], ['a', 'b', 'c']]))
   s_mi
   s_mi.iloc[s_mi.index.isin([(1, 'a'), (2, 'b'), (0, 'c')])]
   s_mi.iloc[s_mi.index.isin(['a', 'c', 'e'], level=1)]

DataFrame also has an ``isin`` method.  When calling ``isin``, pass a set of
values as either an array or dict.  If values is an array, ``isin`` returns
a DataFrame of booleans that is the same shape as the original DataFrame, with True
wherever the element is in the sequence of values.

.. ipython:: python

   df = DataFrame({'vals': [1, 2, 3, 4], 'ids': ['a', 'b', 'f', 'n'],
                   'ids2': ['a', 'n', 'c', 'n']})

   values = ['a', 'b', 1, 3]

   df.isin(values)

Oftentimes you'll want to match certain values with certain columns.
Just make values a ``dict`` where the key is the column, and the value is
a list of items you want to check for.

.. ipython:: python

   values = {'ids': ['a', 'b'], 'vals': [1, 3]}

   df.isin(values)

Combine DataFrame's ``isin`` with the ``any()`` and ``all()`` methods to
quickly select subsets of your data that meet a given criteria.
To select a row where each column meets its own criterion:

.. ipython:: python

  values = {'ids': ['a', 'b'], 'ids2': ['a', 'c'], 'vals': [1, 3]}

  row_mask = df.isin(values).all(1)

  df[row_mask]

The :meth:`~pandas.DataFrame.where` Method and Masking
------------------------------------------------------

Selecting values from a Series with a boolean vector generally returns a
subset of the data. To guarantee that selection output has the same shape as
the original data, you can use the ``where`` method in ``Series`` and ``DataFrame``.

To return only the selected rows

.. ipython:: python

   s[s > 0]

To return a Series of the same shape as the original

.. ipython:: python

   s.where(s > 0)

Selecting values from a DataFrame with a boolean criterion now also preserves
input data shape. ``where`` is used under the hood as the implementation.
Equivalent is ``df.where(df < 0)``

.. ipython:: python
   :suppress:

   dates = date_range('1/1/2000', periods=8)
   df = DataFrame(randn(8, 4), index=dates, columns=['A', 'B', 'C', 'D'])

.. ipython:: python

   df[df < 0]

In addition, ``where`` takes an optional ``other`` argument for replacement of
values where the condition is False, in the returned copy.

.. ipython:: python

   df.where(df < 0, -df)

You may wish to set values based on some boolean criteria.
This can be done intuitively like so:

.. ipython:: python

   s2 = s.copy()
   s2[s2 < 0] = 0
   s2

   df2 = df.copy()
   df2[df2 < 0] = 0
   df2

By default, ``where`` returns a modified copy of the data. There is an
optional parameter ``inplace`` so that the original data can be modified
without creating a copy:

.. ipython:: python

   df_orig = df.copy()
   df_orig.where(df > 0, -df, inplace=True);
   df_orig

**alignment**

Furthermore, ``where`` aligns the input boolean condition (ndarray or DataFrame),
such that partial selection with setting is possible. This is analogous to
partial setting via ``.ix`` (but on the contents rather than the axis labels)

.. ipython:: python

   df2 = df.copy()
   df2[ df2[1:4] > 0 ] = 3
   df2

.. versionadded:: 0.13

Where can also accept ``axis`` and ``level`` parameters to align the input when
performing the ``where``.

.. ipython:: python

   df2 = df.copy()
   df2.where(df2>0,df2['A'],axis='index')

This is equivalent (but faster than) the following.

.. ipython:: python

   df2 = df.copy()
   df.apply(lambda x, y: x.where(x>0,y), y=df['A'])

**mask**

``mask`` is the inverse boolean operation of ``where``.

.. ipython:: python

   s.mask(s >= 0)
   df.mask(df >= 0)

.. _indexing.query:

The :meth:`~pandas.DataFrame.query` Method (Experimental)
---------------------------------------------------------

.. versionadded:: 0.13

:class:`~pandas.DataFrame` objects have a :meth:`~pandas.DataFrame.query`
method that allows selection using an expression.

You can get the value of the frame where column ``b`` has values
between the values of columns ``a`` and ``c``. For example:

.. ipython:: python
   :suppress:

   from numpy.random import randint, rand
   np.random.seed(1234)

.. ipython:: python

   n = 10
   df = DataFrame(rand(n, 3), columns=list('abc'))
   df

   # pure python
   df[(df.a < df.b) & (df.b < df.c)]

   # query
   df.query('(a < b) & (b < c)')

Do the same thing but fall back on a named index if there is no column
with the name ``a``.

.. ipython:: python

   df = DataFrame(randint(n / 2, size=(n, 2)), columns=list('bc'))
   df.index.name = 'a'
   df
   df.query('a < b and b < c')

If instead you don't want to or cannot name your index, you can use the name
``index`` in your query expression:

.. ipython:: python
   :suppress:

   old_index = index
   del index

.. ipython:: python

   df = DataFrame(randint(n, size=(n, 2)), columns=list('bc'))
   df
   df.query('index < b < c')

.. ipython:: python
   :suppress:

   index = old_index
   del old_index


.. note::

   If the name of your index overlaps with a column name, the column name is
   given precedence. For example,

   .. ipython:: python

      df = DataFrame({'a': randint(5, size=5)})
      df.index.name = 'a'
      df.query('a > 2') # uses the column 'a', not the index

   You can still use the index in a query expression by using the special
   identifier 'index':

   .. ipython:: python

      df.query('index > 2')

   If for some reason you have a column named ``index``, then you can refer to
   the index as ``ilevel_0`` as well, but at this point you should consider
   renaming your columns to something less ambiguous.


:class:`~pandas.MultiIndex` :meth:`~pandas.DataFrame.query` Syntax
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

You can also use the levels of a ``DataFrame`` with a
:class:`~pandas.MultiIndex` as if they were columns in the frame:

.. ipython:: python

   import pandas.util.testing as tm

   n = 10
   colors = tm.choice(['red', 'green'], size=n)
   foods = tm.choice(['eggs', 'ham'], size=n)
   colors
   foods

   index = MultiIndex.from_arrays([colors, foods], names=['color', 'food'])
   df = DataFrame(randn(n, 2), index=index)
   df
   df.query('color == "red"')

If the levels of the ``MultiIndex`` are unnamed, you can refer to them using
special names:


.. ipython:: python

   df.index.names = [None, None]
   df
   df.query('ilevel_0 == "red"')


The convention is ``ilevel_0``, which means "index level 0" for the 0th level
of the ``index``.


:meth:`~pandas.DataFrame.query` Use Cases
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

A use case for :meth:`~pandas.DataFrame.query` is when you have a collection of
:class:`~pandas.DataFrame` objects that have a subset of column names (or index
levels/names) in common. You can pass the same query to both frames *without*
having to specify which frame you're interested in querying

.. ipython:: python

   df = DataFrame(rand(n, 3), columns=list('abc'))
   df
   df2 = DataFrame(rand(n + 2, 3), columns=df.columns)
   df2
   expr = '0.0 <= a <= c <= 0.5'
   map(lambda frame: frame.query(expr), [df, df2])

:meth:`~pandas.DataFrame.query` Python versus pandas Syntax Comparison
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Full numpy-like syntax

.. ipython:: python

   df = DataFrame(randint(n, size=(n, 3)), columns=list('abc'))
   df
   df.query('(a < b) & (b < c)')
   df[(df.a < df.b) & (df.b < df.c)]

Slightly nicer by removing the parentheses (by binding making comparison
operators bind tighter than ``&``/``|``)

.. ipython:: python

   df.query('a < b & b < c')

Use English instead of symbols

.. ipython:: python

   df.query('a < b and b < c')

Pretty close to how you might write it on paper

.. ipython:: python

   df.query('a < b < c')

The ``in`` and ``not in`` operators
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

:meth:`~pandas.DataFrame.query` also supports special use of Python's ``in`` and
``not in`` comparison operators, providing a succinct syntax for calling the
``isin`` method of a ``Series`` or ``DataFrame``.

.. ipython:: python
   :suppress:

   try:
       old_d = d
       del d
   except NameError:
       pass

.. ipython:: python

   # get all rows where columns "a" and "b" have overlapping values
   df = DataFrame({'a': list('aabbccddeeff'), 'b': list('aaaabbbbcccc'),
                   'c': randint(5, size=12), 'd': randint(9, size=12)})
   df
   df.query('a in b')

   # How you'd do it in pure Python
   df[df.a.isin(df.b)]

   df.query('a not in b')

   # pure Python
   df[~df.a.isin(df.b)]


You can combine this with other expressions for very succinct queries:


.. ipython:: python

   # rows where cols a and b have overlapping values and col c's values are less than col d's
   df.query('a in b and c < d')

   # pure Python
   df[df.b.isin(df.a) & (df.c < df.d)]


.. note::

   Note that ``in`` and ``not in`` are evaluated in Python, since ``numexpr``
   has no equivalent of this operation. However, **only the** ``in``/``not in``
   **expression itself** is evaluated in vanilla Python. For example, in the
   expression

   .. code-block:: python

      df.query('a in b + c + d')

   ``(b + c + d)`` is evaluated by ``numexpr`` and *then* the ``in``
   operation is evaluated in plain Python. In general, any operations that can
   be evaluated using ``numexpr`` will be.

Special use of the ``==`` operator with ``list`` objects
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Comparing a ``list`` of values to a column using ``==``/``!=`` works similarly
to ``in``/``not in``

.. ipython:: python

   df.query('b == ["a", "b", "c"]')

   # pure Python
   df[df.b.isin(["a", "b", "c"])]

   df.query('c == [1, 2]')

   df.query('c != [1, 2]')

   # using in/not in
   df.query('[1, 2] in c')

   df.query('[1, 2] not in c')

   # pure Python
   df[df.c.isin([1, 2])]


Boolean Operators
~~~~~~~~~~~~~~~~~

You can negate boolean expressions with the word ``not`` or the ``~`` operator.

.. ipython:: python

   df = DataFrame(rand(n, 3), columns=list('abc'))
   df['bools'] = rand(len(df)) > 0.5
   df.query('~bools')
   df.query('not bools')
   df.query('not bools') == df[~df.bools]

Of course, expressions can be arbitrarily complex too

.. ipython:: python

   # short query syntax
   shorter = df.query('a < b < c and (not bools) or bools > 2')

   # equivalent in pure Python
   longer = df[(df.a < df.b) & (df.b < df.c) & (~df.bools) | (df.bools > 2)]

   shorter
   longer

   shorter == longer

.. ipython:: python
   :suppress:

   try:
       d = old_d
       del old_d
   except NameError:
       pass


Performance of :meth:`~pandas.DataFrame.query`
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

``DataFrame.query()`` using ``numexpr`` is slightly faster than Python for
large frames

.. image:: _static/query-perf.png

.. note::

   You will only see the performance benefits of using the ``numexpr`` engine
   with ``DataFrame.query()`` if your frame has more than approximately 200,000
   rows

      .. image:: _static/query-perf-small.png

This plot was created using a ``DataFrame`` with 3 columns each containing
floating point values generated using ``numpy.random.randn()``.

.. ipython:: python
   :suppress:

   df = DataFrame(randn(8, 4), index=dates, columns=['A', 'B', 'C', 'D'])
   df2 = df.copy()


Duplicate Data
--------------

.. _indexing.duplicate:

If you want to identify and remove duplicate rows in a DataFrame,  there are
two methods that will help: ``duplicated`` and ``drop_duplicates``. Each
takes as an argument the columns to use to identify duplicated rows.

- ``duplicated`` returns a boolean vector whose length is the number of rows, and which indicates whether a row is duplicated.
- ``drop_duplicates`` removes duplicate rows.

By default, the first observed row of a duplicate set is considered unique, but
each method has a ``take_last`` parameter that indicates the last observed row
should be taken instead.

.. ipython:: python

   df2 = DataFrame({'a' : ['one', 'one', 'two', 'three', 'two', 'one', 'six'],
                    'b' : ['x', 'y', 'y', 'x', 'y', 'x', 'x'],
                    'c' : np.random.randn(7)})
   df2.duplicated(['a','b'])
   df2.drop_duplicates(['a','b'])
   df2.drop_duplicates(['a','b'], take_last=True)

.. _indexing.dictionarylike:

Dictionary-like :meth:`~pandas.DataFrame.get` method
----------------------------------------------------

Each of Series, DataFrame, and Panel have a ``get`` method which can return a
default value.

.. ipython:: python

   s = Series([1,2,3], index=['a','b','c'])
   s.get('a')               # equivalent to s['a']
   s.get('x', default=-1)

The :meth:`~pandas.DataFrame.select` Method
-------------------------------------------

Another way to extract slices from an object is with the ``select`` method of
Series, DataFrame, and Panel. This method should be used only when there is no
more direct way.  ``select`` takes a function which operates on labels along
``axis`` and returns a boolean.  For instance:

.. ipython:: python

   df.select(lambda x: x == 'A', axis=1)

The :meth:`~pandas.DataFrame.lookup` Method
-------------------------------------------

Sometimes you want to extract a set of values given a sequence of row labels
and column labels, and the ``lookup`` method allows for this and returns a
numpy array.  For instance,

.. ipython:: python

  dflookup = DataFrame(np.random.rand(20,4), columns = ['A','B','C','D'])
  dflookup.lookup(list(range(0,10,2)), ['B','C','A','B','D'])

.. _indexing.class:

Index objects
-------------

The pandas :class:`~pandas.Index` class and its subclasses can be viewed as
implementing an *ordered multiset*. Duplicates are allowed. However, if you try
to convert an :class:`~pandas.Index` object with duplicate entries into a
``set``, an exception will be raised.

:class:`~pandas.Index` also provides the infrastructure necessary for
lookups, data alignment, and reindexing. The easiest way to create an
:class:`~pandas.Index` directly is to pass a ``list`` or other sequence to
:class:`~pandas.Index`:

.. ipython:: python

   index = Index(['e', 'd', 'a', 'b'])
   index
   'd' in index

You can also pass a ``name`` to be stored in the index:


.. ipython:: python

   index = Index(['e', 'd', 'a', 'b'], name='something')
   index.name

The name, if set, will be shown in the console display:

.. ipython:: python

   index = Index(list(range(5)), name='rows')
   columns = Index(['A', 'B', 'C'], name='cols')
   df = DataFrame(np.random.randn(5, 3), index=index, columns=columns)
   df
   df['A']

Setting metadata
~~~~~~~~~~~~~~~~

.. versionadded:: 0.13.0

.. _indexing.set_metadata:

Indexes are "mostly immutable", but it is possible to set and change their
metadata, like the index ``name`` (or, for ``MultiIndex``, ``levels`` and
``labels``).

You can use the ``rename``, ``set_names``, ``set_levels``, and ``set_labels``
to set these attributes directly. They default to returning a copy; however,
you can specify ``inplace=True`` to have the data change in place.

See :ref:`Advanced Indexing <advanced>` for usage of MultiIndexes.

.. ipython:: python

  ind = Index([1, 2, 3])
  ind.rename("apple")
  ind
  ind.set_names(["apple"], inplace=True)
  ind.name = "bob"
  ind

.. versionadded:: 0.15.0

``set_names``, ``set_levels``, and ``set_labels`` also take an optional
`level`` argument

.. ipython:: python


  index = MultiIndex.from_product([range(3), ['one', 'two']], names=['first', 'second'])
  index
  index.levels[1]
  index.set_levels(["a", "b"], level=1)

Set operations on Index objects
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

.. _indexing.set_ops:

.. warning::

   In 0.15.0. the set operations ``+`` and ``-`` were deprecated in order to provide these for numeric type operations on certain
   index types. ``+`` can be replace by ``.union()`` or ``|``, and ``-`` by ``.difference()``.

The two main operations are ``union (|)``, ``intersection (&)``
These can be directly called as instance methods or used via overloaded
operators. Difference is provided via the ``.difference()`` method.

.. ipython:: python

   a = Index(['c', 'b', 'a'])
   b = Index(['c', 'e', 'd'])
   a | b
   a & b
   a.difference(b)

Also available is the ``sym_diff (^)`` operation, which returns elements
that appear in either ``idx1`` or ``idx2`` but not both. This is
equivalent to the Index created by ``idx1.difference(idx2).union(idx2.difference(idx1))``,
with duplicates dropped.

.. ipython:: python

   idx1 = Index([1, 2, 3, 4])
   idx2 = Index([2, 3, 4, 5])
   idx1.sym_diff(idx2)
   idx1 ^ idx2

Set / Reset Index
-----------------

Occasionally you will load or create a data set into a DataFrame and want to
add an index after you've already done so. There are a couple of different
ways.

Set an index
~~~~~~~~~~~~

.. _indexing.set_index:

DataFrame has a ``set_index`` method which takes a column name (for a regular
``Index``) or a list of column names (for a ``MultiIndex``), to create a new,
indexed DataFrame:

.. ipython:: python
   :suppress:

   data = DataFrame({'a' : ['bar', 'bar', 'foo', 'foo'],
                     'b' : ['one', 'two', 'one', 'two'],
                     'c' : ['z', 'y', 'x', 'w'],
                     'd' : [1., 2., 3, 4]})

.. ipython:: python

   data
   indexed1 = data.set_index('c')
   indexed1
   indexed2 = data.set_index(['a', 'b'])
   indexed2

The ``append`` keyword option allow you to keep the existing index and append
the given columns to a MultiIndex:

.. ipython:: python

   frame = data.set_index('c', drop=False)
   frame = frame.set_index(['a', 'b'], append=True)
   frame

Other options in ``set_index`` allow you not drop the index columns or to add
the index in-place (without creating a new object):

.. ipython:: python

   data.set_index('c', drop=False)
   data.set_index(['a', 'b'], inplace=True)
   data

Reset the index
~~~~~~~~~~~~~~~

As a convenience, there is a new function on DataFrame called ``reset_index``
which transfers the index values into the DataFrame's columns and sets a simple
integer index. This is the inverse operation to ``set_index``

.. ipython:: python

   data
   data.reset_index()

The output is more similar to a SQL table or a record array. The names for the
columns derived from the index are the ones stored in the ``names`` attribute.

You can use the ``level`` keyword to remove only a portion of the index:

.. ipython:: python

   frame
   frame.reset_index(level=1)


``reset_index`` takes an optional parameter ``drop`` which if true simply
discards the index, instead of putting index values in the DataFrame's columns.

.. note::

   The ``reset_index`` method used to be called ``delevel`` which is now
   deprecated.

Adding an ad hoc index
~~~~~~~~~~~~~~~~~~~~~~

If you create an index yourself, you can just assign it to the ``index`` field:

.. code-block:: python

   data.index = index

.. _indexing.view_versus_copy:

Returning a view versus a copy
------------------------------

When setting values in a pandas object, care must be taken to avoid what is called
``chained indexing``. Here is an example.

.. ipython:: python

   dfmi = DataFrame([list('abcd'),
                     list('efgh'),
                     list('ijkl'),
                     list('mnop')],
                    columns=MultiIndex.from_product([['one','two'],
                                                     ['first','second']]))
   dfmi

Compare these two access methods:

.. ipython:: python

   dfmi['one']['second']

.. ipython:: python

   dfmi.loc[:,('one','second')]

These both yield the same results, so which should you use? It is instructive to understand the order
of operations on these and why method 2 (``.loc``) is much preferred over method 1 (chained ``[]``)

``dfmi['one']`` selects the first level of the columns and returns a data frame that is singly-indexed.
Then another python operation ``dfmi_with_one['second']`` selects the series indexed by ``'second'`` happens.
This is indicated by the variable ``dfmi_with_one`` because pandas sees these operations as separate events.
e.g. separate calls to ``__getitem__``, so it has to treat them as linear operations, they happen one after another.

Contrast this to ``df.loc[:,('one','second')]`` which passes a nested tuple of ``(slice(None),('one','second'))`` to a single call to
``__getitem__``. This allows pandas to deal with this as a single entity. Furthermore this order of operations *can* be significantly
faster, and allows one to index *both* axes if so desired.

Why does the assignment when using chained indexing fail!
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

So, why does this show the ``SettingWithCopy`` warning / and possibly not work when you do chained indexing and assignment:

.. code-block:: python

   dfmi['one']['second'] = value

Since the chained indexing is 2 calls, it is possible that either call may return a **copy** of the data because of the way it is sliced.
Thus when setting, you are actually setting a **copy**, and not the original frame data. It is impossible for pandas to figure this out because their are 2 separate python operations that are not connected.

The ``SettingWithCopy`` warning is a 'heuristic' to detect this (meaning it tends to catch most cases but is simply a lightweight check). Figuring this out for real is way complicated.

The ``.loc`` operation is a single python operation, and thus can select a slice (which still may be a copy), but allows pandas to assign that slice back into the frame after it is modified, thus setting the values as you would think.

The reason for having the ``SettingWithCopy`` warning is this. Sometimes when you slice an array you will simply get a view back, which means you can set it no problem. However, even a single dtyped array can generate a copy if it is sliced in a particular way. A multi-dtyped DataFrame (meaning it has say ``float`` and ``object`` data), will almost always yield a copy. Whether a view is created is dependent on the memory layout of the array.

Evaluation order matters
~~~~~~~~~~~~~~~~~~~~~~~~

Furthermore, in chained expressions, the order may determine whether a copy is returned or not.
If an expression will set values on a copy of a slice, then a ``SettingWithCopy``
exception will be raised (this raise/warn behavior is new starting in 0.13.0)

You can control the action of a chained assignment via the option ``mode.chained_assignment``,
which can take the values ``['raise','warn',None]``, where showing a warning is the default.

.. ipython:: python
   :okwarning:

   dfb = DataFrame({'a' : ['one', 'one', 'two',
                           'three', 'two', 'one', 'six'],
                    'c' : np.arange(7)})

   # This will show the SettingWithCopyWarning
   # but the frame values will be set
   dfb['c'][dfb.a.str.startswith('o')] = 42

This however is operating on a copy and will not work.

::

   >>> pd.set_option('mode.chained_assignment','warn')
   >>> dfb[dfb.a.str.startswith('o')]['c'] = 42
   Traceback (most recent call last)
        ...
   SettingWithCopyWarning:
        A value is trying to be set on a copy of a slice from a DataFrame.
        Try using .loc[row_index,col_indexer] = value instead

A chained assignment can also crop up in setting in a mixed dtype frame.

.. note::

   These setting rules apply to all of ``.loc/.iloc/.ix``

This is the correct access method

.. ipython:: python

   dfc = DataFrame({'A':['aaa','bbb','ccc'],'B':[1,2,3]})
   dfc.loc[0,'A'] = 11
   dfc

This *can* work at times, but is not guaranteed, and so should be avoided

.. ipython:: python

   dfc = dfc.copy()
   dfc['A'][0] = 111
   dfc

This will **not** work at all, and so should be avoided

::

   >>> pd.set_option('mode.chained_assignment','raise')
   >>> dfc.loc[0]['A'] = 1111
   Traceback (most recent call last)
        ...
   SettingWithCopyException:
        A value is trying to be set on a copy of a slice from a DataFrame.
        Try using .loc[row_index,col_indexer] = value instead

.. warning::

   The chained assignment warnings / exceptions are aiming to inform the user of a possibly invalid
   assignment. There may be false positives; situations where a chained assignment is inadvertantly
   reported.


