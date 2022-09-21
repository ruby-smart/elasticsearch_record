module ElasticsearchRecord
  module Relation
    module ResultMethods
      # aggregate pluck provided columns.
      # returns a hash of values for each provided column
      # .
      # Person.agg_pluck(:name)
      # => {"name" => ['David', 'Jeremy', 'Jose']}
      #
      # Person.agg_pluck(:id, :name)
      # => {"id" => ['11', '2', '5'], "name" => ['David', 'Jeremy', 'Jose']}
      #
      # @param [Array] column_names
      # @return [Hash]
      def agg_pluck(*column_names)
        scope = self.spawn

        column_names.each do |column_name|
          scope.aggregate!(column_name, { terms: { field: column_name, size: limit_value } })
        end

        scope.aggregations.reduce({}) { |m, (k, v)|
          m[k.to_s] = v[:buckets].map { |bucket| bucket[:key] }
          m
        }
      end

      # returns the RAW aggregations for the current query
      # @return [Array]
      def aggregations
        spawn.aggs_only!.resolve.aggregations
      end

      # returns the RAW hits for the current query
      # @return [Array]
      def hits
        spawn.hits_only!.resolve.hits
      end

      # returns the results for the current query
      # @return [Array]
      def results
        spawn.hits_only!.resolve.each
      end

      # returns the total value
      def total
        loaded? ? @total : spawn.total_only!.resolve.total
      end

      # sets query as "hits"-only query (drops the aggs from the query)
      def hits_only!
        configure!({ aggs: nil })

        self
      end

      # sets query as "aggs"-only query (drops the size & sort options - so no hits will return)
      def aggs_only!
        configure!({ size: 0, from: nil, sort: nil })

        self
      end

      # sets query as "total"-only query (drops the size, sort & aggs options - so no hits & aggs will be returned)
      def total_only!
        configure!({ size: 0, from: nil, aggs: nil, sort: nil })

        self
      end
    end
  end
end