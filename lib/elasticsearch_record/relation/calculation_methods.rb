module ElasticsearchRecord
  module Relation
    module CalculationMethods
      def count(column_name = nil)
        if block_given?
          unless column_name.nil?
            raise ArgumentError, "Column name argument is not supported when a block is passed."
          end

          super()
        elsif column_name.present?
          where(:filter, { exists: { field: column_name } }).total
        else
          total
        end
      end

      # Calculates the percentiles on a given column. Returns a hash with empty values (but keys still exists) if there is no row.
      #
      #   Person.percentiles(:year)
      #   > {
      #      "1.0" => 2016.0,
      #      "5.0" => 2016.0,
      #     "25.0" => 2016.0,
      #     "50.0" => 2017.0,
      #     "75.0" => 2017.0,
      #     "95.0" => 2021.0,
      #     "99.0" => 2022.0
      #     }
      def percentiles(column_name)
        calculate(:percentiles, column_name, :values)
      end

      # Calculates the cardinality on a given column. Returns +0+ if there's no row.
      #
      #   Person.cardinality(:age)
      #   > 12
      def cardinality(column_name)
        calculate(:cardinality, column_name)
      end

      # Calculates the average value on a given column. Returns +nil+ if there's no row. See #calculate for examples with options.
      #
      #   Person.average(:age) # => 35.8
      def average(column_name)
        calculate(:avg, column_name)
      end

      # Calculates the minimum value on a given column. The value is returned
      # with the same data type of the column, or +nil+ if there's no row.
      #
      #   Person.minimum(:age)
      #   > 7
      def minimum(column_name)
        calculate(:min, column_name)
      end

      # Calculates the maximum value on a given column. The value is returned
      # with the same data type of the column, or +nil+ if there's no row. See
      # #calculate for examples with options.
      #
      #   Person.maximum(:age) # => 93
      def maximum(column_name)
        calculate(:max, column_name)
      end

      # Calculates the sum of values on a given column. The value is returned
      # with the same data type of the column, +0+ if there's no row. See
      # #calculate for examples with options.
      #
      #   Person.sum(:age) # => 4562
      def sum(column_name = nil)
        calculate(:sum, column_name)
      end

      def calculate(metric, column, node = :value)
        metric_key = "#{column}_#{metric}"

        # spawn a new aggregation and return the aggs
        response = aggregate(metric_key, { metric => { field: column } }).aggregations

        response[metric_key][node]
      end
    end
  end
end