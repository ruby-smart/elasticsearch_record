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
      # As an alternative you can also call the #query(<kind>,{argument}) method.
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

      # sets or overwrites additional arguments for the query (not the :query-node, the whole query).
      # You can also force a overwrite of previously defined arguments, like +size+ or +from+.
      # This is useful to force remove of keys.
      #
      # @example
      #   # adds {refresh true} to the query
      #   configure(:refresh, true)
      #
      #   # overwrites or sets {from: 50} but removes the :sort key
      #   configure({from: 50, sort: nil})
      # @param [Array] args
      def configure(*args)
        spawn.configure!(*args)
      end

      # same like +#configure!+, but on the same relation (no spawn)
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

      def aggregate(*args)
        check_if_method_has_arguments!(__callee__, args)
        spawn.aggregate!(*args)
      end

      alias_method :aggs, :aggregate

      def aggregate!(opts, *rest)
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

      def query(*args)
        check_if_method_has_arguments!(__callee__, args)
        spawn.query!(*args)
      end

      def query!(kind, opts, *rest)
        kind!(kind)
        self.query_clause += build_query_clause(opts.keys[0], opts.values[0], rest)
        self
      end

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

      # creates a condition on the relation.
      # There are several possibilities to call this method.
      #
      #   # create a simple 'term' condition on the query[:filter] param
      #     where({name: 'hans'})
      #     > query[:filter] << { term: { name: 'hans' } }
      #
      #   # create a simple 'terms' condition on the query[:filter] param
      #     where({name: ['hans','peter']})
      #     > query[:filter] << { terms: { name: ['hans','peter'] } }
      #
      #     where(:must_not, term: {name: 'horst'})
      #     where(:query_string, "(new york OR dublin)", fields: ['name','description'])
      #
      #   # nested array
      #   where([ [:filter, {...}], [:must_not, {...}]])
      def where(*args)
        if args.empty?
          spawn
        elsif args.first.blank? # == nil ...
          self
        elsif args.first == :none
          none
        else
          spawn.where!(*args)
        end
      end

      def where!(opts, *rest)
        case opts
          # check the first provided parameter +opts+ and validate, if this is an alias for "must, must_not, should or filter"
          # if true, we expect the rest[0] to be a hash.
          # For this correlation we forward this as RAW-data without check & manipulation
        when Symbol
          case opts
          when :filter, :must, :must_not, :should
            send("#{opts}!", *rest)
          else
            raise ArgumentError, "Unsupported argument type for where: #{opts}"
          end
        when Array
          # check if this is a nested array of multiple [<kind>,<data>]
          if opts[0].is_a?(Array)
            opts.each { |item|
              where!(*item)
            }
          else
            where!(*opts, *rest)
          end
        when String
          # fallback to ActiveRecords +#where_clause+
          # currently NOT supported
          super(opts, rest)
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

          opts.each { |k, v|
            if v.is_a?(Array)
              filter!({ terms: { k => v } }, rest)
            elsif v.nil? # transforms nil to exists
              must_not!({ exists: { field: k } }, rest)
            else
              filter!({ term: { k => v } }, rest)
            end
          }
        end

        self
      end

      def not(*args)
        spawn.not!(*args)
      end

      def not!(opts, *rest)
        # hash -> {name: 'hans'}
        opts = sanitize_forbidden_attributes(opts)

        opts.each { |k, v|
          data = if v.is_a?(Array)
                   { terms: { k => v } }
                 else
                   { term: { k => v } }
                 end

          must_not!(data, rest)
        }

        self
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

      private

      def build_query_clause(kind, data, rest = [])
        ElasticsearchRecord::Relation::QueryClause.new(kind, Array.wrap(data), rest.extract_options!)
      end

      # sets the default kind if no kind value was defined.
      # this is called by all conditional methods (where, not, filter, must, must_not & should)
      def set_default_kind!
        self.kind_value ||= :bool
      end

      def build_arel(*args)
        arel = super(*args)

        arel.kind(kind_value) if kind_value
        arel.query(query_clause.ast) unless query_clause.empty?
        arel.aggs(aggs_clause.ast) unless aggs_clause.empty?
        arel.configure(configure_value) if configure_value.present?

        arel
      end
    end
  end
end