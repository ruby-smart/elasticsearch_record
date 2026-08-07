module ElasticsearchRecord
  module Relation
    module QueryMethods

      # unsupported method
      def joins(*)
        raise ActiveRecord::StatementInvalid, 'Unsupported method "joins"'
      end

      # unsupported method
      # def includes(*)
      #   raise ActiveRecord::StatementInvalid, 'Unsupported method "includes"'
      # end

      # sets or overwrites the query kind (e.g. compound queries -> :bool, :boosting, :constant_score, ...).
      # Also other query kinds like :intervals, :match, ... are allowed.
      # Alternatively the +#query+-method can also be used to provide a kind with arguments.
      # @param [String, Symbol] value - the kind
      def kind(value)
        spawn.kind!(value)
      end

      # same like +#kind+, but on the same relation (no spawn)
      def kind!(value)
        # :nodoc:
        self.kind_value = value
        self
      end

      # sets or overwrites additional arguments for the whole query (not the current 'query-node' - the whole query).
      # Previously defined arguments (like +size+ or +from+) can also be overwritten.
      # Providing a +nil+ value will remove the key  - this is useful to force remove of keys.
      #
      # Providing the special key +:__query__+ will directly access the query object, to alter query-related values
      # (like 'refresh, arguments, columns, ...' - see @ Arel::Collectors::ElasticsearchQuery
      #
      # @example
      #   # adds {refresh true} to the query
      #   configure(:refresh, true)
      #
      #   # overwrites or sets {from: 50} but removes the :sort key
      #   configure({from: 50, sort: nil})
      #
      #   # sets the query's 'refresh' to true
      #   configure(:__query__, refresh: true)
      #
      # @param [Array] args
      def configure(*args)
        spawn.configure!(*args)
      end

      # same like +#configure!+, but on the same relation (no spawn)
      # @return [self]
      def configure!(*args)
        check_if_method_has_arguments!(__callee__, args)

        if args.length == 1 && args.first.is_a?(Hash)
          self.configure_value = self.configure_value.merge(args[0])
        elsif args.length == 2 && args[0] == :__query__
          tmp = self.configure_value[:__query__] || []
          tmp << args[1]
          self.configure_value = self.configure_value.merge(:__query__ => tmp)
        elsif args.length == 2
          self.configure_value = self.configure_value.merge(args[0] => args[1])
        end

        self
      end

      # create or add an aggregation to the query.
      # @example
      #   aggregate(:total, { sum: {field: :amount})
      def aggregate(*args)
        check_if_method_has_arguments!(__callee__, args)
        spawn.aggregate!(*args)
      end

      alias_method :aggs, :aggregate

      def aggregate!(opts, *rest)
        # :nodoc:
        case opts
        when Symbol, String
          self.aggs_clause += build_query_clause(opts, rest)
        when Hash
          opts.each do |key, value|
            self.aggs_clause += build_query_clause(key, value)
          end
        else
          raise ArgumentError, "Unsupported argument type for aggregate: #{opts}"
        end

        self
      end

      # sets the query's +refresh+ value.
      # @param [Boolean] value (default: true)
      def refresh(value = true)
        spawn.refresh!(value)
      end

      def refresh!(value = true)
        configure!(:__query__, refresh: value)
      end

      # sets the query's +timeout+ value - the period each shard may spend on the search before
      # returning whatever it gathered so far.
      #
      # The value must be an elasticsearch time value, e.g. +'30s'+, +'1m'+ or +'500ms'+.
      # Two values behave special:
      # * +0+  aborts immediately
      # * +-1+ waits indefinitely _(since Elasticsearch 8.15 - it used to mean "abort immediately")_
      #
      # Providing +nil+ or +false+ removes a previously set timeout.
      #
      # PLEASE NOTE: a timed out search is NOT an error - elasticsearch answers with partial results
      # and a +timed_out+ flag, which the adapter raises as +ActiveRecord::StatementTimeout+.
      #
      # @example
      #   timeout('30s')
      #
      # @param [String, Integer, nil, false] value
      def timeout(value)
        spawn.timeout!(value)
      end

      def timeout!(value)
        configure!(:__query__, timeout: _validated_timeout(value))
      end

      # sets the query's +knn+ node - an approximate nearest neighbour search on a +dense_vector+
      # field. Since Elasticsearch 8.12 this is a regular part of the search body, so it combines
      # with the +query+ / +filter+ chain instead of replacing it.
      #
      # PLEASE NOTE: the provided structure is forwarded UNVALIDATED - the adapter does not try to
      # keep up with the vector-search options of every release.
      #
      # @example
      #   knn(field: :embedding, query_vector: [0.1, 0.2], k: 10, num_candidates: 100)
      #
      # @example several vector searches at once
      #   knn([{field: :title_vector, ...}, {field: :body_vector, ...}])
      #
      # @param [Hash, Array<Hash>] value
      def knn(value)
        spawn.knn!(value)
      end

      def knn!(value)
        configure!(knn: value)
      end

      # restricts the +_source+ fields that are transferred back for each hit.
      #
      # This is the counterpart of +select+: +select+ names the fields to KEEP _(and builds a
      # projection ActiveRecord knows about)_, while +restrict+ addresses the raw +_source+ filter
      # directly - which is the only way to EXCLUDE something.
      #
      # +exclude_vectors+ (Elasticsearch 8.19+) drops every +dense_vector+ / +sparse_vector+ field
      # without having to name them. Vectors dominate the transferred payload of a hit, so this is
      # usually the single most effective option on a vector-carrying index.
      #
      # @example
      #   restrict(excludes: [:embedding])
      #   restrict(includes: [:name, :count])
      #   restrict(exclude_vectors: true)
      #
      # @param [Array, String, Symbol, nil] includes
      # @param [Array, String, Symbol, nil] excludes
      # @param [Boolean, nil] exclude_vectors
      def restrict(includes: nil, excludes: nil, exclude_vectors: nil)
        spawn.restrict!(includes: includes, excludes: excludes, exclude_vectors: exclude_vectors)
      end

      def restrict!(includes: nil, excludes: nil, exclude_vectors: nil)
        source = {}
        source[:includes]        = Array.wrap(includes) unless includes.nil?
        source[:excludes]        = Array.wrap(excludes) unless excludes.nil?
        source[:exclude_vectors] = exclude_vectors unless exclude_vectors.nil?

        raise ArgumentError, 'Provide at least one of includes:, excludes: or exclude_vectors:' if source.empty?

        configure!(_source: source)
      end

      # add a whole query 'node' to the query.
      # @example
      #   query(:bool, {filter: ...})
      def query(*args)
        check_if_method_has_arguments!(__callee__, args)
        spawn.query!(*args)
      end

      def query!(kind, opts, *rest)
        # :nodoc:
        kind!(kind)
        self.query_clause += build_query_clause(opts.keys[0], opts.values[0], rest)
        self
      end

      # adds a +filter+ clause.
      # @example
      #   filter({terms: ...})
      def filter(*args)
        check_if_method_has_arguments!(__callee__, args)
        spawn.filter!(*args)
      end

      def filter!(opts, *rest)
        # :nodoc:
        set_default_kind!
        self.query_clause += build_query_clause(:filter, opts, rest)
        self
      end

      # adds a +must_not+ clause.
      # @example
      #   filter({terms: ...})
      def must_not(*args)
        check_if_method_has_arguments!(__callee__, args)
        spawn.must_not!(*args)
      end

      def must_not!(opts, *rest)
        # :nodoc:
        set_default_kind!
        self.query_clause += build_query_clause(:must_not, opts, rest)
        self
      end

      # adds a +must+ clause.
      # @example
      #   must({terms: ...})
      def must(*args)
        check_if_method_has_arguments!(__callee__, args)
        spawn.must!(*args)
      end

      def must!(opts, *rest)
        # :nodoc:
        set_default_kind!
        self.query_clause += build_query_clause(:must, opts, rest)
        self
      end

      # adds a +should+ clause.
      # @example
      #   should({terms: ...})
      def should(*args)
        check_if_method_has_arguments!(__callee__, args)
        spawn.should!(*args)
      end

      def should!(opts, *rest)
        # :nodoc:
        set_default_kind!
        self.query_clause += build_query_clause(:should, opts, rest)
        self
      end

      def none! # :nodoc:
        @none = true
        # tell the query it 'failed'
        configure!(:__query__, status: :failed)
      end

      # creates a condition on the relation.
      # There are several possibilities to call this method.
      #
      # @example
      #   # create a simple 'term' condition on the query[:filter] param
      #   where({name: 'hans'})
      #   #> query[:filter] << { term: { name: 'hans' } }
      #
      #   # create a simple 'terms' condition on the query[:filter] param
      #   where({name: ['hans','peter']})
      #   #> query[:filter] << { terms: { name: ['hans','peter'] } }
      #
      #   where(:must_not, term: {name: 'horst'})
      #   where(:query_string, "(new york OR dublin)", fields: ['name','description'])
      #
      #   # nested array
      #   where([ [:filter, {...}], [:must_not, {...}]])
      #
      #   # invalidate query
      #   where(:none)
      #
      def where!(opts, *rest)
        # :nodoc:
        case opts
        when Symbol
          case opts
          when :none
            none!
          when :filter, :must, :must_not, :should
            # check the first provided parameter +opts+ and validate, if this is an alias for "must, must_not, should or filter".
            # if true, we expect the rest[0] to be a hash.
            # For this correlation we forward this as RAW-data without check & manipulation
            send("#{opts}!", *rest)
          else
            raise ArgumentError, "Unsupported prefix type '#{opts}'. Allowed types are: :filter, :must, :must_not, :should"
          end
        when Array
          # check if this is a nested array of multiple [<kind>,<data>]
          if opts[0].is_a?(Array)
            opts.each { |item| where!(*item) }
          else
            where!(*opts, *rest)
          end
        else
          self.where_clause += build_where_clause(opts, rest)
        end

        self
      end

      def or!(other)
        self.query_clause = self.query_clause.or(other.query_clause)

        super(other)
      end

      def unscope!(*args)
        # :nodoc:
        self.unscope_values += args

        args.each do |scope|
          case scope
          when Symbol
            unless _valid_unscoping_values.include?(scope)
              raise ArgumentError, "Called unscope() with invalid unscoping argument ':#{scope}'. Valid arguments are :#{_valid_unscoping_values.to_a.join(", :")}."
            end
            assert_mutability!
            @values.delete(scope)
          when Hash
            scope.each do |key, target_value|
              target_query_clause = build_query_clause(key, target_value)
              self.query_clause   -= target_query_clause
            end
          else
            raise ArgumentError, "Unrecognized scoping: #{args.inspect}. Use .unscope(where: :attribute_name) or .unscope(:order), for example."
          end
        end

        self
      end

      # overwrite to prevent metadata fields within the projection.
      # Metadata fields (like '_id' or '_score') are NOT part of the +_source+ node, so they cannot be
      # resolved through the +_source+-filter this method builds - providing them would silently create
      # a filter that never matches.
      # HINT: This is different to the +pluck+-method which allows to resolve meta keys directly.
      # see @ Arel::Visitors::ElasticsearchQuery#visit_Selects
      # @param [Array] fields
      def select(*fields)
        # IMPORTANT: +select+ can also be called with a block (and without any fields) - in this case
        # ActiveRecord directly forwards to +super()+, so we must not interfere here.
        if fields.any? && (invalid = _invalid_projection_fields(fields)).present?
          raise(ActiveRecord::UnknownAttributeReference,
                "Unable to select metadata attributes: #{invalid.map(&:inspect).join(", ")}. " \
                "Metadata fields are not part of the '_source' node but are always returned and accessible within the record. " \
                "(e.g. #{klass.name}.first.#{invalid.first})."
          )
        end

        super
      end

      private

      # elasticsearch time value: a number with an optional unit.
      # see @ https://www.elastic.co/guide/en/elasticsearch/reference/8.19/api-conventions.html#time-units
      TIMEOUT_PATTERN = /\A-?\d+(d|h|m|s|ms|micros|nanos)?\z/

      # validates the provided +timeout+ value and returns it unchanged.
      #
      # This guard exists because elasticsearch rejects anything it cannot parse as a time value with
      # a +400 illegal_argument_exception+ - which used to happen for EVERY call of the former
      # 'timeout(value = true)' default, since 'timeout=true' is not a time value.
      # @param [Object] value
      # @return [String, Integer, nil, false]
      def _validated_timeout(value)
        # explicitly removes the timeout again
        return value if value.nil? || value == false

        return value if value.to_s.match?(TIMEOUT_PATTERN)

        raise ArgumentError,
              "Unsupported timeout value #{value.inspect}. Provide an elasticsearch time value " \
              "(e.g. '30s', '1m', '500ms'), or nil to remove it."
      end

      def build_where_clause(opts, _rest = [])
        case opts
        when Symbol, Array, String
          raise ArgumentError, "Unsupported or unresolved argument class '#{opts.class}' for build_where_clause: #{opts}"
        else
          # hash -> {name: 'hans'}
          # protects against forwarding params directly to where ...
          # User.where(params) <- will never work
          # User.where(params.permit(:user)) <- ok
          opts = sanitize_forbidden_attributes(opts)

          # resolve possible aliases
          opts = opts.transform_keys do |key|
            key = key.to_s
            klass.attribute_aliases[key] || key
          end

          # check if we have keys without Elasticsearch fields
          if (invalid = (opts.keys - klass.searchable_column_names)).present?
            raise(ActiveRecord::UnknownAttributeReference,
                  "Unable to build query with unknown searchable attributes: #{invalid.map(&:inspect).join(", ")}. " \
                "If you want to build a custom query you should use one of those methods: 'filter, must, must_not, should'. " \
                "#{klass.name}.filter('#{invalid[0]}' => '...')"
            )
          end

          # force set default kind, if not previously set
          set_default_kind!

          # builds predicates from opts (transforms this in a more unreadable way but is required for nested assignment & binds ...)
          parts = opts.map do |key, value|
            # builds and returns a new Arel Node from provided key/value pair
            predicate_builder[key, value]
          end

          ::ActiveRecord::Relation::WhereClause.new(parts)
        end
      end

      def build_query_clause(kind, data, rest = [])
        # prevent empty data clauses
        # e.g. [nil] - which will cause possible query-exceptions
        if data.blank? || (data.is_a?(Array) && data.all?(&:blank?))
          raise ArgumentError, "Unable to build query clause for '#{kind}' without any data @ #{klass.name}!"
        end

        ElasticsearchRecord::Relation::QueryClause.new(kind, Array.wrap(data), rest.extract_options!)
      end

      # sets the default kind if no kind value was defined.
      # this is called by all conditional methods (where, not, filter, must, must_not & should)
      def set_default_kind!
        self.kind_value ||= :bool
      end

      # overwrite default method to add additional values for kind, query, aggs, ...
      def build_arel(*args)
        arel = super(*args)

        arel.kind(kind_value) if kind_value
        arel.query(query_clause.ast) unless query_clause.empty?
        arel.aggs(aggs_clause.ast) unless aggs_clause.empty?
        arel.configure(configure_value) if configure_value.present?

        arel
      end

      # returns any provided field that is a metadata field and therefore not resolvable
      # through a projection.
      # @param [Array] fields
      # @return [Array<String>]
      def _invalid_projection_fields(fields)
        ActiveRecord::ConnectionAdapters::ElasticsearchAdapter.metadata_keys & fields.flatten.select{|fld| fld.is_a?(String) || fld.is_a?(Symbol)}.map(&:to_s)
      end
    end
  end
end