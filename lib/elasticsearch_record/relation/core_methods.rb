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
      # WARNING: if the current relation is a +NullRelation+ (**#none** was assigned), the method directly returns nil!
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
      # @example
      #   # msearch with none (NullRelation)
      #   scope = spawn.none
      #   scope.msearch([2020, 2019, 2018]).each{ |query, year| ... }
      #   # > nil
      #
      # @param [nil, Array] items - items to be yielded and used to provide individual queries (yields: |spawn, value| )
      # @param [Hash] opts - additional options to refine the results
      # @option opts[Symbol] :resolve - optionally resolve specific results from each result (:took, :total , :hits , :aggregations , :length , :results, :each)
      # @option opts[Boolean] :transpose - transposes the provided values & results as Hash (default: false)
      # @option opts[Boolean] :keep_null_relation - by provided true-value, a NullRelation will not be ignored - so items will be yielded & query will be executed (default: false)
      # @return [Array, Hash, nil]
      def msearch(items = nil, opts = {})
        # prevent query on +NullRelation+!
        return nil if null_relation? && !opts[:keep_null_relation]

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

      # overwrite original methods to provide a elasticsearch version:
      # checks against the +#access_id_fielddata?+ to ensure the Elasticsearch Cluster allows access on the +_id+ field.
      def ordered_relation
        # order values already exist
        return self unless order_values.empty?

        # resolve valid primary_key
        # - either it is NOT the '_id' column
        # OR
        # - it is the '_id'-column, but +access_id_fielddata?+ is also enabled!
        valid_primary_key = if primary_key != '_id' || klass.connection.access_id_fielddata?
                              primary_key
                            else
                              nil
                            end

        # slightly changed original methods content
        if implicit_order_column || valid_primary_key
          # order by +implicit_order_column+ AND +primary_key+
          if implicit_order_column && valid_primary_key && implicit_order_column != valid_primary_key
            order(table[implicit_order_column].asc, table[valid_primary_key].asc)
          else
            order(table[implicit_order_column || valid_primary_key].asc)
          end
        else
          # order is not possible due restricted settings
          self
        end
      end
    end
  end
end




