module ElasticsearchRecord
  module Relation
    module CoreMethods
      def instantiate_records(rows, &block)
        # slurp the total value from the rows (rows = ElasticsearchRecord::Result)
        @total = rows.total
        super
      end

      # transforms the current relation into arel and executes the query.
      # returns the result object
      # @return [ElasticsearchRecord::Result]
      def resolve
        klass._query_by_sql(arel)
      end

      # returns the query hash for the current relation
      # @return [Hash]
      def to_query
        to_sql.arguments
      end

      # executes the elasticsearch msearch on the related klass
      #
      # @example
      #   msearch([2020, 2019, 2018]).each{ |q, year| q.where(year: year) }
      #
      # @param [Array] values - values to be yielded
      # @param [nil, Symbol] response_type - optional type of search response (took, total , hits , aggregations , length , each)
      def msearch(values = nil, response_type = nil)
        if values.nil?
          arels = [arel]
        else
          arels = values.map { |value|
            # spawn a new relation and return the query-object
            yield(spawn, value).arel
          }
        end

        # returns a response object with multiple single responses
        responses = klass._query_by_msearch(arels)

        if response_type
          responses.map(&response_type.to_sym)
        else
          responses
        end
      end
    end
  end
end




