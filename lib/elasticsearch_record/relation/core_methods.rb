module ElasticsearchRecord
  module Relation
    module CoreMethods
      def instantiate_records(rows, &block)
        # slurp the total value from the rows (rows = ElasticsearchRecord::Result)
        @total = rows.is_a?(::ElasticsearchRecord::Result) ? rows.total : rows.length
        super
      end

      # transforms the current relation into arel, compiles it to query and executes the query.
      # returns the result object.
      #
      # PLEASE NOTE: This makes the query +immutable+ and raises a +ActiveRecord::ImmutableRelation+
      # if you try to change it's values.
      #
      # PLEASE NOTE: resolving records _(instantiate)_ is never possible after calling this method!
      #
      # @return [ElasticsearchRecord::Result]
      # @param [String] name - custom instrumentation name (default: 'Load')
      def resolve(name = 'Load')
        # this acts the same like +#_query_by_sql+ but we can customize the instrumentation name and
        # do not store the records.
        klass.connection.select_all(arel, "#{klass.name} #{name}")
      end

      # returns the query hash for the current relation
      # @return [Hash]
      def to_query
        to_sql.query_arguments
      end

      # Allows to execute several search operations in one request.
      # executes the elasticsearch +msearch+ on the related class-index.
      #
      # A optionally array of items will be each yielded with a spawn(of the current relation) and item.
      # Each yield-return will resolve its +arel+ which will then transform to multiple queries and send in a single request.
      #
      # Responses can be refined by providing a +resolve+ option, to resolve specific results from each +ElasticsearchRecord::Result+
      # (e.g. used to resolve 'aggregations, buckets, ...')
      #
      # As a default the method returns an array of (resolved) responses in the order of the provided +values+-array.
      # This can be transformed into a hash of keys (provided items) and values (responses) by providing the +transpose+ flag.
      #
      # @example
      #   # msearch on the current relation
      #   msearch
      #   # > [ElasticsearchRecord::Result]
      #
      # @example
      #   # msearch with provided items
      #   msearch([2020, 2019, 2018]).each{ |query, year| query.where!(year: year) }
      #   # > [ElasticsearchRecord::Result, ElasticsearchRecord::Result, ElasticsearchRecord::Result]
      #
      # @example
      #   # msearch with refining options
      #   msearch([2020, 2019, 2018], resolve: :aggregations, transpose: true).each{ |query, year| query.where!(year: year).aggregate!(:total, { sum: { field: :count }}) }
      #   # > {2020 => {...aggs...}, 2019 => {...aggs...}, 2018 => {...aggs...}}
      #
      # @param [nil, Array] items - items to be yielded and used to provide individual queries (yields: |spawn, value| )
      # @param [Hash] opts - additional options to refine the results
      # @option opts[Symbol] :resolve - optionally resolve specific results from each result (:took, :total , :hits , :aggregations , :length , :results, :each)
      # @option opts[Boolean] :transpose - transposes the provided values & results as Hash (default: false)
      # @return [Array, Hash]
      def msearch(items = nil, opts = {})
        # check if values are provided, if not we use the arel from the current relation-scope
        arels = if items.nil?
                  [arel]
                else
                  # spawn a new relation to the block and maps each arel-object
                  items.map { |value| yield(spawn, value).arel }
                end

        # check provided resolve method
        responses = if opts[:resolve]
                      klass._query_by_msearch(arels).map(&opts[:resolve].to_sym)
                    else
                      klass._query_by_msearch(arels)
                    end

        if opts[:transpose]
          [items, responses].transpose.to_h
        else
          responses
        end
      end
    end
  end
end




