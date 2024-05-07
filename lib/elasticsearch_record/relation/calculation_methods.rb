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
      # @see https://www.elastic.co/guide/en/elasticsearch/reference/current/search-aggregations-metrics-boxplot-aggregation.html
      #
      # @note returns *nil* on a *NullRelation*
      #
      # @param [Symbol, String] column_name
      # @return [Hash,nil]
      def boxplot(column_name)
        calculate_aggregation(:boxplot, column_name)
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
      # @see https://www.elastic.co/guide/en/elasticsearch/reference/current/search-aggregations-metrics-stats-aggregation.html
      #
      # @note returns *nil* on a *NullRelation*
      #
      # @param [Symbol, String] column_name
      # @return [Hash,nil]
      def stats(column_name)
        calculate_aggregation(:stats, column_name)
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
      # @see https://www.elastic.co/guide/en/elasticsearch/reference/current/search-aggregations-metrics-string-stats-aggregation.html
      #
      # @note returns *nil* on a *NullRelation*
      #
      # @param [Symbol, String] column_name
      # @return [Hash,nil]
      def string_stats(column_name)
        calculate_aggregation(:string_stats, column_name)
      end

      # The matrix_stats aggregation is a numeric aggregation that computes the following statistics over a set of document fields:
      # *count*        Number of per field samples included in the calculation.
      # *mean*        The average value for each field.
      # *variance*    Per field Measurement for how spread out the samples are from the mean.
      # *skewness*    Per field measurement quantifying the asymmetric distribution around the mean.
      # *kurtosis*    Per field measurement quantifying the shape of the distribution.
      # *covariance*  A matrix that quantitatively describes how changes in one field are associated with another.
      # *correlation* The covariance matrix scaled to a range of -1 to 1, inclusive. Describes the relationship between field distributions.
      #
      # @see https://www.elastic.co/guide/en/elasticsearch/reference/current/search-aggregations-matrix-stats-aggregation.html
      #
      # @note returns *nil* on a *NullRelation*
      #
      # @param [Array<Symbol|String>] column_names
      # @return [Hash,nil]
      def matrix_stats(*column_names)
        calculate_aggregation(:matrix_stats, *column_names)
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
      #
      # @see https://www.elastic.co/guide/en/elasticsearch/reference/current/search-aggregations-metrics-percentile-aggregation.html
      #
      # @note returns *nil* on a *NullRelation*
      #
      # @param [Symbol, String] column_name
      # @return [Hash,nil]
      def percentiles(column_name)
        calculate_aggregation(:percentiles, column_name, node: :values)
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
      #
      # @see https://www.elastic.co/guide/en/elasticsearch/reference/current/search-aggregations-metrics-percentile-rank-aggregation.html
      #
      # @note returns *nil* on a *NullRelation*
      #
      # @param [Symbol, String] column_name
      # @param [Array] values
      # @return [Hash,nil]
      def percentile_ranks(column_name, values)
        calculate_aggregation(:percentile_ranks, column_name, opts: { values: values }, node: :values)
      end

      # Calculates the cardinality on a given column. Returns +0+ if there's no row.
      #
      #   Person.all.cardinality(:age)
      #   > 12
      #
      # @see https://www.elastic.co/guide/en/elasticsearch/reference/current/search-aggregations-metrics-cardinality-aggregation.html
      #
      # @note returns *nil* on a *NullRelation*
      #
      # @param [Symbol, String] column_name
      # @return [Integer,nil]
      def cardinality(column_name)
        calculate_aggregation(:cardinality, column_name, node: :value)
      end

      # Calculates the average value on a given column. Returns +nil+ if there's no row. See #calculate for examples with options.
      #
      #   Person.all.average(:age) # => 35.8
      #
      # @see https://www.elastic.co/guide/en/elasticsearch/reference/current/search-aggregations-metrics-avg-aggregation.html
      #
      # @note returns *nil* on a *NullRelation*
      #
      # @param [Symbol, String] column_name
      # @return [Float,nil]
      def average(column_name)
        calculate_aggregation(:avg, column_name, node: :value)
      end

      # Calculates the minimum value on a given column. The value is returned
      # with the same data type of the column, or +nil+ if there's no row.
      #
      #   Person.all.minimum(:age)
      #   > 7
      #
      # @see https://www.elastic.co/guide/en/elasticsearch/reference/current/search-aggregations-metrics-min-aggregation.html
      #
      # @note returns *nil* on a *NullRelation*
      #
      # @param [Symbol, String] column_name
      # @return [Float,nil]
      def minimum(column_name)
        calculate_aggregation(:min, column_name, node: :value)
      end

      # Calculates the maximum value on a given column. The value is returned
      # with the same data type of the column, or +nil+ if there's no row. See
      # #calculate for examples with options.
      #
      #   Person.all.maximum(:age) # => 93
      #
      # @see https://www.elastic.co/guide/en/elasticsearch/reference/current/search-aggregations-metrics-max-aggregation.html
      #
      # @note returns *nil* on a *NullRelation*
      #
      # @param [Symbol, String] column_name
      # @return [Float,nil]
      def maximum(column_name)
        calculate_aggregation(:max, column_name, node: :value)
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
      # @see https://www.elastic.co/guide/en/elasticsearch/reference/current/search-aggregations-metrics-median-absolute-deviation-aggregation.html
      #
      # @note returns *nil* on a *NullRelation*
      #
      # @param [Symbol, String] column_name
      # @return [Float,nil]
      def median_absolute_deviation(column_name)
        calculate_aggregation(:median_absolute_deviation, column_name)
      end

      # Calculates the sum of values on a given column. The value is returned
      # with the same data type of the column, +0+ if there's no row. See
      # #calculate for examples with options.
      #
      #   Person.all.sum(:age) # => 4562
      #
      # @see https://www.elastic.co/guide/en/elasticsearch/reference/current/search-aggregations-metrics-sum-aggregation.html
      #
      # @note returns *nil* on a *NullRelation*
      #
      # @param [Symbol, String] column_name (optional)
      # @return [Float,nil]
      def sum(column_name)
        calculate_aggregation(:sum, column_name, node: :value)
      end

      # creates a aggregation with the provided metric (e.g. :sum) and columns.
      # returns the metric node (default: :value) from the aggregations result.
      #
      # @note returns *nil* on a *NullRelation*
      #
      # @param [Symbol, String] metric
      # @param [Array<Symbol|String>] columns
      # @param [Hash] opts - additional arguments that get merged with the metric definition
      # @param [Symbol] node (default: nil)
      def calculate_aggregation(metric, *columns, opts: {}, node: nil)
        # prevent execution on a *NullRelation*
        return if null_relation?

        metric_key = "calculate_#{metric}"

        # spawn a new aggregation and return the aggs
        response = if columns.size == 1
                     aggregate(metric_key, { metric => { field: columns[0] }.merge(opts) }).aggregations
                   else
                     aggregate(metric_key, { metric => { fields: columns }.merge(opts) }).aggregations
                   end

        if node.present?
          response[metric_key][node]
        else
          response[metric_key]
        end
      end

      alias_method :calculate, :calculate_aggregation
    end
  end
end