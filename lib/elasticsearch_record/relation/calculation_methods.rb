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
          # HINT: :__claim__ directly interacts with the query-object and sets a 'terminate_after' argument
          # (see @ Arel::Collectors::ElasticsearchQuery#assign)
          arel = spawn.unscope!(:offset, :limit, :order, :configure, :aggs).configure!(:__claim__, argument: { terminate_after: limit_value }).arel
          klass.connection.select_count(arel, "#{klass.name} Count")
        else
          # since total will be limited to 10000 results, we need to resolve the real values by a custom query.
          # This query is called through +#select_count+.
          arel = spawn.unscope!(:offset, :limit, :order, :configure, :aggs)
          klass.connection.select_count(arel, "#{klass.name} Count")
        end
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

      # creates a aggregation with the provided metric (e.g. :sum) and column.
      # returns the metric node (default: :value) from the aggregations result.
      # @param [Symbol, String] metric
      # @param [Symbol, String] column
      # @param [Hash] opts - additional arguments that get merged with the metric definition
      # @param [Symbol] node (default :value)
      def calculate(metric, column, opts: {}, node: :value)
        metric_key = "#{column}_#{metric}"

        # spawn a new aggregation and return the aggs
        response = aggregate(metric_key, { metric => { field: column }.merge(opts) }).aggregations

        response[metric_key][node]
      end
    end
  end
end