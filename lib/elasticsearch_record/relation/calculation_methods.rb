module ElasticsearchRecord
  module Relation
    module CalculationMethods
      # Count the records.
      #
      #   Person.all.count
      #   => the total count of all people
      #
      #   Person.all.count(:age)
      #   => returns the total count of all people whose age is present in database
      def count(column_name = nil)
        # fallback to default
        return super() if block_given?

        # check for already failed query
        return 0 if null_relation?

        # reset column_name, if +:all+ was provided ...
        column_name = nil if column_name == :all

        # check for combined cases
        if self.distinct_value && column_name
          self.cardinality(column_name)
        elsif column_name
          where(:filter, { exists: { field: column_name } }).count
        elsif self.group_values.any?
          self.composite(*self.group_values)
        elsif self.select_values.any?
          self.composite(*self.select_values)
        elsif limit_value == 0 # Shortcut when limit is zero.
          return 0
        elsif limit_value
          # since total will be limited to 10000 results, we need to resolve the real values by a custom query.
          # This query is called through +#select_count+.
          #
          # HINT: +:__query__+ directly interacts with the query-object and sets the 'terminate_after' argument
          # see @ ElasticsearchRecord::Query#arguments & Arel::Collectors::ElasticsearchQuery#assign
          arel = spawn.unscope!(:offset, :limit, :order, :configure, :aggs).configure!(:__query__, argument: { terminate_after: limit_value }).arel
          klass.connection.select_count(arel, "#{klass.name} Count")
        else
          # since total will be limited to 10000 results, we need to resolve the real values by a custom query.
          # This query is called through +#select_count+.
          arel = spawn.unscope!(:offset, :limit, :order, :configure, :aggs)
          klass.connection.select_count(arel, "#{klass.name} Count")
        end
      end

      # A boxplot metrics aggregation that computes boxplot of numeric values extracted from the aggregated documents.
      # These values can be generated from specific numeric or histogram fields in the documents.
      #
      # The boxplot aggregation returns essential information for making a box plot:
      # *minimum*, *maximum*, *median*, *first quartile* (25th percentile) and *third quartile* (75th percentile) values.
      #
      #   Person.all.boxplot(:age)
      #   > {
      #       "min": 0.0,
      #       "max": 990.0,
      #       "q1": 167.5,
      #       "q2": 445.0,
      #       "q3": 722.5,
      #       "lower": 0.0,
      #       "upper": 990.0
      #     }
      #
      # @param [Symbol, String] column_name
      def boxplot(column_name)
        calculate(:boxplot, column_name)
      end

      # A multi-value metrics aggregation that computes stats over numeric values extracted from the aggregated documents.      #
      # The stats that are returned consist of: *min*, *max*, *sum*, *count* and *avg*.
      #
      #   Person.all.stats(:age)
      #   > {
      #       "count": 10,
      #       "min": 0.0,
      #       "max": 990.0,
      #       "sum": 16859,
      #       "avg": 75.5
      #     }
      #
      # @param [Symbol, String] column_name
      def stats(column_name)
        calculate(:stats, column_name)
      end

      # A multi-value metrics aggregation that computes statistics over string values extracted from the aggregated documents.
      # These values can be retrieved either from specific keyword fields.
      #
      #   Person.all.string_stats(:name)
      #   > {
      #       "count": 5,
      #       "min_length": 24,
      #       "max_length": 30,
      #       "avg_length": 28.8,
      #       "entropy": 3.94617750050791
      #     }
      #
      # @param [Symbol, String] column_name
      def string_stats(column_name)
        calculate(:string_stats, column_name)
      end

      # The matrix_stats aggregation is a numeric aggregation that computes the following statistics over a set of document fields.
      def matrix_stats(*column_names)
        calculate(:matrix_stats, *column_names)
      end

      # A multi-value metrics aggregation that calculates one or more
      # percentiles over numeric values extracted from the aggregated documents.
      # Returns a hash with empty values (but keys still exists) if there is no row.
      #
      #   Person.all.percentiles(:year)
      #   > {
      #      "1.0" => 2016.0,
      #      "5.0" => 2016.0,
      #     "25.0" => 2016.0,
      #     "50.0" => 2017.0,
      #     "75.0" => 2017.0,
      #     "95.0" => 2021.0,
      #     "99.0" => 2022.0
      #     }
      # @param [Symbol, String] column_name
      def percentiles(column_name)
        calculate(:percentiles, column_name, node: :values)
      end

      # A multi-value metrics aggregation that calculates one or more
      # percentile ranks over numeric values extracted from the aggregated documents.
      #
      # Percentile rank show the percentage of observed values which are below certain value.
      # For example, if a value is greater than or equal to 95% of the observed values it is
      # said to be at the 95th percentile rank.
      #
      #   Person.all.percentile_ranks(:year, [500,600])
      #   > {
      #      "1.0" => 2016.0,
      #      "5.0" => 2016.0,
      #     "25.0" => 2016.0,
      #     "50.0" => 2017.0,
      #     "75.0" => 2017.0,
      #     "95.0" => 2021.0,
      #     "99.0" => 2022.0
      #     }
      # @param [Symbol, String] column_name
      # @param [Array] values
      def percentile_ranks(column_name, values)
        calculate(:percentiles, column_name, opts: { values: values }, node: :values)
      end

      # Calculates the cardinality on a given column. Returns +0+ if there's no row.
      #
      #   Person.all.cardinality(:age)
      #   > 12
      #
      # @param [Symbol, String] column_name
      def cardinality(column_name)
        calculate(:cardinality, column_name)
      end

      # Calculates the average value on a given column. Returns +nil+ if there's no row. See #calculate for examples with options.
      #
      #   Person.all.average(:age) # => 35.8
      #
      # @param [Symbol, String] column_name
      def average(column_name)
        calculate(:avg, column_name)
      end

      # Calculates the minimum value on a given column. The value is returned
      # with the same data type of the column, or +nil+ if there's no row.
      #
      #   Person.all.minimum(:age)
      #   > 7
      #
      # @param [Symbol, String] column_name
      def minimum(column_name)
        calculate(:min, column_name)
      end

      # Calculates the maximum value on a given column. The value is returned
      # with the same data type of the column, or +nil+ if there's no row. See
      # #calculate for examples with options.
      #
      #   Person.all.maximum(:age) # => 93
      #
      # @param [Symbol, String] column_name
      def maximum(column_name)
        calculate(:max, column_name)
      end

      # This single-value aggregation approximates the median absolute deviation of its search results.
      # Median absolute deviation is a measure of variability. It is a robust statistic,
      # meaning that it is useful for describing data that may have outliers, or may not be normally distributed.
      # For such data it can be more descriptive than standard deviation.
      #
      # It is calculated as the median of each data point’s deviation from the median of the entire sample.
      # That is, for a random variable X, the median absolute deviation is median(|median(X) - Xi|).
      #
      #   Person.all.median_absolute_deviation(:age) # => 91
      #
      # @param [Symbol, String] column_name
      def median_absolute_deviation(column_name)
        calculate(:median_absolute_deviation, column_name)
      end

      # Calculates the sum of values on a given column. The value is returned
      # with the same data type of the column, +0+ if there's no row. See
      # #calculate for examples with options.
      #
      #   Person.all.sum(:age) # => 4562
      #
      # @param [Symbol, String] column_name (optional)
      def sum(column_name)
        calculate(:sum, column_name)
      end

      # creates a aggregation with the provided metric (e.g. :sum) and columns.
      # returns the metric node (default: :value) from the aggregations result.
      # @param [Symbol, String] metric
      # @param [Array<Symbol|String>] columns
      # @param [Hash] opts - additional arguments that get merged with the metric definition
      # @param [Symbol] node (default :value)
      def calculate(metric, *columns, opts: {}, node: :value)
        metric_key = "calculate_#{metric}"

        # spawn a new aggregation and return the aggs
        response = if columns.size == 1
                     aggregate(metric_key, { metric => { field: columns[0] }.merge(opts) }).aggregations
                   else
                     aggregate(metric_key, { metric => { fields: columns }.merge(opts) }).aggregations
                   end

        response[metric_key][node]
      end
    end
  end
end