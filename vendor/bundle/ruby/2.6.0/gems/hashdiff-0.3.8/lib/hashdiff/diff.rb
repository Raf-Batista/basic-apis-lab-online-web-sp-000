module HashDiff
  # Best diff two objects, which tries to generate the smallest change set using different similarity values.
  #
  # HashDiff.best_diff is useful in case of comparing two objects which include similar hashes in arrays.
  #
  # @param [Array, Hash] obj1
  # @param [Array, Hash] obj2
  # @param [Hash] options the options to use when comparing
  #   * :strict (Boolean) [true] whether numeric values will be compared on type as well as value.  Set to false to allow comparing Integer, Float, BigDecimal to each other
  #   * :delimiter (String) ['.'] the delimiter used when returning nested key references
  #   * :numeric_tolerance (Numeric) [0] should be a positive numeric value.  Value by which numeric differences must be greater than.  By default, numeric values are compared exactly; with the :tolerance option, the difference between numeric values must be greater than the given value.
  #   * :strip (Boolean) [false] whether or not to call #strip on strings before comparing
  #   * :array_path (Boolean) [false] whether to return the path references for nested values in an array, can be used for patch compatibility with non string keys.
  #   * :use_lcs (Boolean) [true] whether or not to use an implementation of the Longest common subsequence algorithm for comparing arrays, produces better diffs but is slower.
  #
  # @yield [path, value1, value2] Optional block is used to compare each value, instead of default #==. If the block returns value other than true of false, then other specified comparison options will be used to do the comparison.
  #
  # @return [Array] an array of changes.
  #   e.g. [[ '+', 'a.b', '45' ], [ '-', 'a.c', '5' ], [ '~', 'a.x', '45', '63']]
  #
  # @example
  #   a = {'x' => [{'a' => 1, 'c' => 3, 'e' => 5}, {'y' => 3}]}
  #   b = {'x' => [{'a' => 1, 'b' => 2, 'e' => 5}] }
  #   diff = HashDiff.best_diff(a, b)
  #   diff.should == [['-', 'x[0].c', 3], ['+', 'x[0].b', 2], ['-', 'x[1].y', 3], ['-', 'x[1]', {}]]
  #
  # @since 0.0.1
  def self.best_diff(obj1, obj2, options = {}, &block)
    options[:comparison] = block if block_given?

    opts = { similarity: 0.3 }.merge!(options)
    diffs1 = diff(obj1, obj2, opts)
    count1 = count_diff diffs1

    opts = { similarity: 0.5 }.merge!(options)
    diffs2 = diff(obj1, obj2, opts)
    count2 = count_diff diffs2

    opts = { similarity: 0.8 }.merge!(options)
    diffs3 = diff(obj1, obj2, opts)
    count3 = count_diff diffs3

    count, diffs = count1 < count2 ? [count1, diffs1] : [count2, diffs2]
    count < count3 ? diffs : diffs3
  end

  # Compute the diff of two hashes or arrays
  #
  # @param [Array, Hash] obj1
  # @param [Array, Hash] obj2
  # @param [Hash] options the options to use when comparing
  #   * :strict (Boolean) [true] whether numeric values will be compared on type as well as value.  Set to false to allow comparing Integer, Float, BigDecimal to each other
  #   * :similarity (Numeric) [0.8] should be between (0, 1]. Meaningful if there are similar hashes in arrays. See {best_diff}.
  #   * :delimiter (String) ['.'] the delimiter used when returning nested key references
  #   * :numeric_tolerance (Numeric) [0] should be a positive numeric value.  Value by which numeric differences must be greater than.  By default, numeric values are compared exactly; with the :tolerance option, the difference between numeric values must be greater than the given value.
  #   * :strip (Boolean) [false] whether or not to call #strip on strings before comparing
  #   * :array_path (Boolean) [false] whether to return the path references for nested values in an array, can be used for patch compatibility with non string keys.
  #   * :use_lcs (Boolean) [true] whether or not to use an implementation of the Longest common subsequence algorithm for comparing arrays, produces better diffs but is slower.
  #
  #
  # @yield [path, value1, value2] Optional block is used to compare each value, instead of default #==. If the block returns value other than true of false, then other specified comparison options will be used to do the comparison.
  #
  # @return [Array] an array of changes.
  #   e.g. [[ '+', 'a.b', '45' ], [ '-', 'a.c', '5' ], [ '~', 'a.x', '45', '63']]
  #
  # @example
  #   a = {"a" => 1, "b" => {"b1" => 1, "b2" =>2}}
  #   b = {"a" => 1, "b" => {}}
  #
  #   diff = HashDiff.diff(a, b)
  #   diff.should == [['-', 'b.b1', 1], ['-', 'b.b2', 2]]
  #
  # @since 0.0.1
  def self.diff(obj1, obj2, options = {}, &block)
    opts = {
      prefix: '',
      similarity: 0.8,
      delimiter: '.',
      strict: true,
      strip: false,
      numeric_tolerance: 0,
      array_path: false,
      use_lcs: true
    }.merge!(options)

    opts[:prefix] = [] if opts[:array_path] && opts[:prefix] == ''

    opts[:comparison] = block if block_given?

    # prefer to compare with provided block
    result = custom_compare(opts[:comparison], opts[:prefix], obj1, obj2)
    return result if result

    return [] if obj1.nil? && obj2.nil?

    return [['~', opts[:prefix], nil, obj2]] if obj1.nil?

    return [['~', opts[:prefix], obj1, nil]] if obj2.nil?

    return [['~', opts[:prefix], obj1, obj2]] unless comparable?(obj1, obj2, opts[:strict])

    result = []
    if obj1.is_a?(Array) && opts[:use_lcs]
      changeset = diff_array_lcs(obj1, obj2, opts) do |lcs|
        # use a's index for similarity
        lcs.each do |pair|
          prefix = prefix_append_array_index(opts[:prefix], pair[0], opts)
          result.concat(diff(obj1[pair[0]], obj2[pair[1]], opts.merge(prefix: prefix)))
        end
      end

      changeset.each do |change|
        change_key = prefix_append_array_index(opts[:prefix], change[1], opts)
        if change[0] == '-'
          result << ['-', change_key, change[2]]
        elsif change[0] == '+'
          result << ['+', change_key, change[2]]
        end
      end
    elsif obj1.is_a?(Array) && !opts[:use_lcs]
      result.concat(LinearCompareArray.call(obj1, obj2, opts))
    elsif obj1.is_a?(Hash)

      deleted_keys = obj1.keys - obj2.keys
      common_keys = obj1.keys & obj2.keys
      added_keys = obj2.keys - obj1.keys

      # add deleted properties
      deleted_keys.sort_by { |k, _v| k.to_s }.each do |k|
        change_key = prefix_append_key(opts[:prefix], k, opts)
        custom_result = custom_compare(opts[:comparison], change_key, obj1[k], nil)

        if custom_result
          result.concat(custom_result)
        else
          result << ['-', change_key, obj1[k]]
        end
      end

      # recursive comparison for common keys
      common_keys.sort_by { |k, _v| k.to_s }.each do |k|
        prefix = prefix_append_key(opts[:prefix], k, opts)
        result.concat(diff(obj1[k], obj2[k], opts.merge(prefix: prefix)))
      end

      # added properties
      added_keys.sort_by { |k, _v| k.to_s }.each do |k|
        change_key = prefix_append_key(opts[:prefix], k, opts)
        next if obj1.key?(k)

        custom_result = custom_compare(opts[:comparison], change_key, nil, obj2[k])

        if custom_result
          result.concat(custom_result)
        else
          result << ['+', change_key, obj2[k]]
        end
      end
    else
      return [] if compare_values(obj1, obj2, opts)

      return [['~', opts[:prefix], obj1, obj2]]
    end

    result
  end

  # @private
  #
  # diff array using LCS algorithm
  def self.diff_array_lcs(arraya, arrayb, options = {})
    opts = {
      prefix: '',
      similarity: 0.8,
      delimiter: '.'
    }.merge!(options)

    change_set = []
    return [] if arraya.empty? && arrayb.empty?

    if arraya.empty?
      arrayb.each_index do |index|
        change_set << ['+', index, arrayb[index]]
      end
      return change_set
    elsif arrayb.empty?
      arraya.each_index do |index|
        i = arraya.size - index - 1
        change_set << ['-', i, arraya[i]]
      end
      return change_set
    end

    links = lcs(arraya, arrayb, opts)

    # yield common
    yield links if block_given?

    # padding the end
    links << [arraya.size, arrayb.size]

    last_x = -1
    last_y = -1
    links.each do |pair|
      x, y = pair

      # remove from a, beginning from the end
      (x > last_x + 1) && (x - last_x - 2).downto(0).each do |i|
        change_set << ['-', last_y + i + 1, arraya[i + last_x + 1]]
      end

      # add from b, beginning from the head
      (y > last_y + 1) && 0.upto(y - last_y - 2).each do |i|
        change_set << ['+', last_y + i + 1, arrayb[i + last_y + 1]]
      end

      # update flags
      last_x = x
      last_y = y
    end

    change_set
  end
end
