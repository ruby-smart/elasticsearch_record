# frozen_string_literal: true

module Arel # :nodoc: all
  module Visitors
    module ElasticsearchQuery
      extend ActiveSupport::Concern

      # maps a +bool+ occurrence to its opposite - used to invert a nested +Not+ node.
      # see @ #visit_Arel_Nodes_Not
      INVERTED_ASSIGN_KEYS = {
        filter:   :must_not,
        must:     :must_not,
        must_not: :filter
      }.freeze

      # the two halves a +range+ can be build from - two bounds of the SAME half must never be merged.
      # see @ #_mergeable_range?
      RANGE_LOWER_BOUNDS = %i[gt gte].freeze
      RANGE_UPPER_BOUNDS = %i[lt lte].freeze

      private

      ######################
      # CORE VISITS (CRUD) #
      ######################

      # SELECT // SEARCH
      def visit_Arel_Nodes_SelectStatement(o)
        # prepare query type
        claim(:type, ::ElasticsearchRecord::Query::TYPE_SEARCH)

        resolve(o.cores) # visit_Arel_Nodes_SelectCore

        resolve(o.orders) # visit_Sort
        resolve(o.limit) # visit_Arel_Nodes_Limit
        resolve(o.offset) # visit_Arel_Nodes_Offset

        # configure is able to overwrite everything in the query
        resolve(o.configure)
      end

      # UPDATE (by query - not a single record...)
      def visit_Arel_Nodes_UpdateStatement(o)
        # switch between updating a single Record or multiple by query
        if o.relation.is_a?(::Arel::Table)
          raise NotImplementedError, "if you've made it this far, something went wrong ..."
        end

        # prepare query type
        claim(:type, ::ElasticsearchRecord::Query::TYPE_UPDATE_BY_QUERY)

        # force refresh after update - but it can be unset again through the 'configure' ...
        claim(:refresh, true)

        # sets the index
        resolve(o.relation)

        # updating multiple entries needs a script
        assign(:script, {}) do
          assign(:inline, "") do
            updates = collect(o.values)
            assign(updates.join('; ')) if updates.present?
          end
        end

        # sets the search query
        resolve(o, :visit_Query)

        resolve(o.orders) # visit_Sort

        assign(:max_docs, collect(o.limit.expr)) if o.limit.present?
        resolve(o.offset)

        # configure is able to overwrite everything
        resolve(o.configure)
      end

      # DELETE (by query - not a single record...)
      def visit_Arel_Nodes_DeleteStatement(o)
        # switch between updating a single Record or multiple by query
        if o.relation.is_a?(::Arel::Table)
          raise NotImplementedError, "if you've made it this far, something went wrong ..."
        end

        # prepare query type
        claim(:type, ::ElasticsearchRecord::Query::TYPE_DELETE_BY_QUERY)

        # force refresh after delete - but it can be unset again through the 'configure' ...
        claim(:refresh, true)

        # sets the index
        resolve(o.relation)

        # sets the search query
        resolve(o, :visit_Query)

        resolve(o.orders) # visit_Sort

        assign(:max_docs, collect(o.limit.expr)) if o.limit.present?
        resolve(o.offset)

        # configure is able to overwrite everything
        resolve(o.configure)
      end

      # INSERT (by query - not a single record...)
      # this is also used by 'meta' or 'schema_migrations' tables ...
      def visit_Arel_Nodes_InsertStatement(o)
        # switch between updating a single Record or multiple by query
        if o.relation.is_a?(::Arel::Table)
          # prepare query type
          claim(:type, ::ElasticsearchRecord::Query::TYPE_CREATE)

          # force refresh after insert
          claim(:refresh, true)

          # sets the index
          resolve(o.relation)

          # sets create arguments
          resolve(o, :visit_Create)
        else
          raise NotImplementedError
        end
      end

      ##############################
      # SUBSTRUCTURE VISITS (CRUD) #
      ##############################

      def visit_Arel_Nodes_SelectCore(o)
        # sets the index
        resolve(o.source)

        # IMPORTANT: Since Elasticsearch does not store nil-values in the +_source+ / +doc+ it will NOT return
        # empty / nil columns - instead the nil columns do not exist!!!
        # This is a big mess, because those missing columns are +not+ editable or savable in any way after we initialize the record...
        # To prevent NOT-accessible attributes, we need to provide the "full-column-definition" to the query as +default+.
        # This may be overwritten by the 'visit_Selects'
        resource_klass = o.source.left.instance_variable_get(:@klass)
        claim(:columns, resource_klass.source_column_names) if resource_klass.respond_to?(:source_column_names)

        # sets the query
        resolve(o, :visit_Query) if o.queries.present? || o.wheres.present?

        # sets the aggs
        resolve(o, :visit_Aggs) if o.aggs.present?

        # sets the selects
        resolve(o, :visit_Selects) if o.projections.present?
      end

      # CUSTOM node by elasticsearch_record
      def visit_Query(o)
        # resolves the query kind.
        # PLEASE NOTE: in some cases there is no kind, but an existing +where+ conditions.
        # This will then be treat as +:bool+.
        kind = o.kind.present? ? visit(o.kind.expr).presence : nil
        kind ||= :bool if o.wheres.present?

        # check for existing kind - we cannot create a node if we don't have any kind
        return unless kind

        assign(:query, {}) do
          # this creates a kind node and creates nested queries
          # e.g. :bool => { ... }
          assign(kind, {}) do
            # each query has a type (e.g.: :filter) and one or multiple statements.
            # this is handled within the +visit_Arel_Nodes_SelectQuery+ method
            o.queries.each do |query|
              resolve(query) # visit_Arel_Nodes_SelectQuery

              # assign additional opts on the type level
              assign(query.opts) if query.opts.present?
            end

            # collect the where from predicate builds
            # should call:
            # - visit_Arel_Nodes_Equality
            # - visit_Arel_Nodes_NotEqual
            # - visit_Arel_Nodes_HomogeneousIn'
            resolve(o.wheres) if o.wheres.present?

            # annotations
            resolve(o.comment) if o.respond_to?(:comment)
          end
        end
      end

      # CUSTOM node by elasticsearch_record
      def visit_Aggs(o)
        assign(:aggs, {}) do
          o.aggs.each do |agg|
            resolve(agg)

            # we assign the opts on the top agg level
            assign(agg.opts) if agg.opts.present?
          end
        end
      end

      # CUSTOM node by elasticsearch_record
      def visit_Selects(o)
        fields = collect(o.projections)

        case fields[0]
        when '*'
          # force return all fields
          # assign(:_source, true)
        when ::ElasticsearchRecord::Query::COLUMNS_NONE
          # force return NO fields - metadata fields ('_id', '_score', ...) are not part of the
          # +_source+ and are always returned on the document level, so they stay accessible.
          assign(:_source, false)

          # clears the columns claimed by +visit_Arel_Nodes_SelectCore+ - a projection is the only
          # place that runs late enough to undo them.
          # HINT: an empty array equals the +Query+ default, so +Result#_results_from_hits+ takes its
          # "no columns" branch and returns the raw document. Together with the +_source: false+ above
          # this leaves exactly the metadata fields.
          claim(:columns, [])
        when ::ActiveRecord::FinderMethods::ONE_AS_ONE
          # force return NO fields
          assign(:_source, false)

          # also clear the columns in the query (which will be forwarded to +ElasticsearchRecord::Result+)
          # HINT: If future changes rely on the first column value (in this case '1' -> SELECT 1 AS one) this must be fixed within the +ElasticsearchRecord::Result+.
          # Maybe check on the columns[0] value within the #rows method ...
          claim(:columns, %w[one])
        else
          # IMPORTANT: metadata fields (like '_id' or '_score') are NOT part of the +_source+ node - they
          # are always returned on the document level. Providing them to the +_source+-filter would create
          # a filter that never matches, so they must be removed here.
          source_fields = fields - ActiveRecord::ConnectionAdapters::ElasticsearchAdapter.metadata_keys

          # if ONLY metadata fields were provided we must not resolve any +_source+ at all.
          assign(:_source, source_fields.presence || false)

          # also overwrite the columns in the query (which will be forwarded to +ElasticsearchRecord::Result+)
          # HINT: metadata fields must stay within the columns - they are resolved from the document level.
          claim(:columns, fields)
        end
      end

      # CUSTOM node by elasticsearch_record
      def visit_Create(o)
        # detect, if *columns* where provided.
        # This happens through the +::Arel::InsertManager#insert+ by splitting up the columns & values.
        values = if o.columns.present?
                   # IMPORTANT: we do not "visit" the columns & rows here but directly build a final hash.
                   # o.values.rows.*first* (first) is correct here, since +::Arel::InsertManager#create_values+ will provide all values in a nested Array
                   collect(Hash[o.columns.map(&:name).zip(o.values.rows.first)])
                 elsif o.values.present?
                   collect(o.values)
                 end

        if values.present?
          claim(:body, values)
        else
          failed!
        end
      end

      # CUSTOM node by elasticsearch_record
      def visit_Arel_Nodes_SelectKind(o)
        visit(o.expr)
      end

      # CUSTOM node by elasticsearch_record
      def visit_Arel_Nodes_SelectConfigure(o)
        attrs = visit(o.expr)

        # we need to assign each key - value independently since +nil+ values will be treated as +delete+
        attrs.each do |key, value|
          assign(key, value)
        end if attrs.present?
      end

      # CUSTOM node by elasticsearch_record
      def visit_Arel_Nodes_SelectQuery(o)
        # this creates a query select node (includes key, value(s) and additional opts)
        # e.g.
        #   :filter  => [ ... ]
        #   :must =>  [ ... ]

        # the query value must always be a array, since it might be extended by where clause.
        #   assign(:filter, []) ...
        assign(visit(o.left), []) do
          # assign(terms: ...)
          _within_query_clause { assign(visit(o.right)) }
        end
      end

      # CUSTOM node by elasticsearch_record
      # a +QueryClause+ only reaches the visitor through a grouped +Or+ - anywhere else it is already
      # unwrapped into a +SelectQuery+ node by +QueryClauseTree#ast+.
      # see @ ElasticsearchRecord::Relation::QueryClause#ast
      # see @ Arel::Visitors::ElasticsearchQuery#visit_Arel_Nodes_Or
      def visit_ElasticsearchRecord_Relation_QueryClause(o)
        key, predicates, _opts = o.ast

        assign(visit(key), []) do
          assign(visit(predicates))
        end
      end

      # CUSTOM node by elasticsearch_record
      def visit_Arel_Nodes_SelectAgg(o)
        assign(visit(o.left) => visit(o.right))
      end

      # used to write new data to columns
      def visit_Arel_Nodes_Assignment(o)
        value = visit(o.right)

        value_assign = if o.right.value_before_type_cast.is_a?(Symbol)
                         "ctx._source.#{value}"
                       else
                         quote(value)
                       end

        "ctx._source.#{visit(o.left)} = #{value_assign}"
      end

      def visit_Arel_Nodes_Comment(o)
        assign(:_name, o.values.join(' - '))
      end

      # directly assigns the offset to the current scope
      def visit_Arel_Nodes_Offset(o)
        assign(:from, visit(o.expr))
      end

      # directly assigns the size to the current scope
      def visit_Arel_Nodes_Limit(o)
        assign(:size, visit(o.expr))
      end

      def visit_Sort(o)
        assign(:sort, {}) do
          key = visit(o.expr)
          dir = visit(o.direction)

          # we support a special key: __rand__ to create a simple random method ...
          if key == '__rand__'
            assign({
                     "_script" => {
                       "script" => "Math.random()",
                       "type"   => "number",
                       "order"  => dir
                     }
                   })
          else
            assign(key => dir)
          end
        end
      end

      alias :visit_Arel_Nodes_Ascending :visit_Sort
      alias :visit_Arel_Nodes_Descending :visit_Sort

      # DIRECT ASSIGNMENT
      def visit_Arel_Nodes_Equality(o)
        right = visit(o.right)

        return failed! if unboundable?(right) || invalid?(right)

        key = visit(o.left)

        if right.nil?
          # transforms nil to exists
          assign(:must_not, [{ exists: { field: key } }])
        else
          assign(:filter, [{ term: { key => right } }])
        end
      end

      # DIRECT ASSIGNMENT
      def visit_Arel_Nodes_NotEqual(o)
        right = visit(o.right)

        return failed! if unboundable?(right) || invalid?(right)

        key = visit(o.left)

        if right.nil?
          # transforms nil to exists
          assign(:filter, [{ exists: { field: key } }])
        else
          assign(:must_not, [{ term: { key => right } }])
        end
      end

      # DIRECT ASSIGNMENT
      # transforms an inclusive range _(+year: 2020..2021+)_ into a +range+ query.
      # ActiveRecord provides this as a +Between+ node, which nests both bounds within a +And+ node.
      # see @ ActiveRecord::PredicateBuilder::RangeHandler
      def visit_Arel_Nodes_Between(o)
        left, right = o.right.children.map { |child| visit(child) }

        return failed! if _unusable_range_bound?(left) || _unusable_range_bound?(right)

        assign(:filter, [{ range: { visit(o.left) => { gte: left, lte: right } } }])
      end

      # DIRECT ASSIGNMENT
      #
      # IMPORTANT: only the modern +gt+, +gte+, +lt+ & +lte+ keys are generated here.
      # Elasticsearch deprecated the legacy +from+, +to+, +include_lower+ & +include_upper+ keys
      # with 8.16 _(they still resolve correctly, but emit a deprecation warning)_.
      # This also keeps the write-direction symmetric to the read-direction
      # (see @ ActiveRecord::ConnectionAdapters::Elasticsearch::Type::Range).
      def visit_Arel_Nodes_GreaterThan(o)
        _assign_range(o, :gt)
      end

      # DIRECT ASSIGNMENT
      def visit_Arel_Nodes_GreaterThanOrEqual(o)
        _assign_range(o, :gte)
      end

      # DIRECT ASSIGNMENT
      def visit_Arel_Nodes_LessThan(o)
        _assign_range(o, :lt)
      end

      # DIRECT ASSIGNMENT
      def visit_Arel_Nodes_LessThanOrEqual(o)
        _assign_range(o, :lte)
      end

      # DIRECT ASSIGNMENT
      # inverts all assignments of the nested node - a +where.not+ on anything but a simple
      # value _(e.g. +where.not(year: 2020..2021)+)_ arrives as a +Not+ node.
      # PLEASE NOTE: a simple +where.not(year: 2020)+ does +not+ create a +Not+ node,
      # but a +NotEqual+ node.
      def visit_Arel_Nodes_Not(o)
        args = _merge_range_assignments(_capture_assignments { visit(o.expr) })

        return if args.blank?

        # IMPORTANT: a nested node may resolve to SEVERAL clauses, and those are AND-ed.
        # Inverting each of them individually would produce 'NOT a AND NOT b' - but negating a
        # conjunction must produce 'NOT (a AND b)' _(De Morgan)_. So anything that is not a
        # single clause gets wrapped into one nested +bool+ clause before being negated.
        if args.length == 1 && args[0][1].is_a?(Array) && args[0][1].length == 1
          key, value = args[0]
          assign(INVERTED_ASSIGN_KEYS.fetch(key, key), value)
        else
          assign(:must_not, [{ bool: args.to_h }])
        end

        nil
      end

      # DIRECT ASSIGNMENT
      def visit_Arel_Nodes_NotIn(o)
        self.collector.preparable = false

        attr, values = o.left, o.right

        if Array === values
          values.delete_if { |value| unboundable?(value) } unless values.empty?

          # a 'NOT IN ()' does not restrict anything - opposite to a 'IN ()', which never matches.
          # This is provided by a totally unbounded range (+year: nil..nil+).
          return if values.empty?
        end

        assign(:must_not, [{ terms: { visit(attr) => visit(values) } }])
      end

      # DIRECT ASSIGNMENT
      # a +Grouping+ only ever wraps a +Or+ here - ActiveRecord builds it in
      # +ActiveRecord::Relation::WhereClause#or+.
      # Every other grouped expression is NOT supported and will force to fail the query.
      def visit_Arel_Nodes_Grouping(o)
        return visit(o.expr) if o.expr.is_a?(::Arel::Nodes::Or)

        failed!
      end

      # DIRECT ASSIGNMENT
      def visit_Arel_Nodes_HomogeneousIn(o)
        self.collector.preparable = false

        values = o.casted_values

        # IMPORTANT: For SQL defaults (see @ Arel::Collectors::SubstituteBinds) a value
        # will +not+ directly assigned (see @ Arel::Visitors::ToSql#visit_Arel_Nodes_HomogeneousIn).
        # instead it will be send as bind and then re-delegated to the SQL collector.
        #
        # This only works for linear SQL-queries and not nested Hashes
        # (otherwise we have to collect those binds, and replace them afterwards).
        #
        # Here, we'll directly assign the "real" _(casted)_ values but also provide a additional bind.
        # This will be ignored by the ElasticsearchQuery collector, but supports statement caches on the other side
        # (see @ ActiveRecord::StatementCache::PartialQueryCollector)
        self.collector.add_binds(values, o.proc_for_binds)

        if o.type == :in
          assign(:filter, [{ terms: { visit(o.left) => o.casted_values } }])
        else
          assign(:must_not, [{ terms: { visit(o.left) => o.casted_values } }])
        end
      end

      # DIRECT ASSIGNMENT
      def visit_Arel_Nodes_In(o)
        self.collector.preparable = false

        attr, values = o.left, o.right

        if Array === values
          unless values.empty?
            values.delete_if { |value| unboundable?(value) }
          end

          return failed! if values.empty?
        end

        assign(:filter, [{ terms: { visit(attr) => visit(values) } }])
      end

      def visit_Arel_Nodes_And(o)
        # An exclusive range (+year: 2020...2021+) does not arrive as a +Between+ node, but as
        # +And[GreaterThanOrEqual, LessThan]+. Visiting the children individually would emit one
        # +range+ clause per bound - which is a valid _(and correctly AND-ed)_ query, but reads as
        # '{range: {year: {gte: 2020}}}, {range: {year: {lt: 2021}}}'.
        # We therefore capture the children's assignments and merge +range+ clauses that address
        # the same field into a single clause.
        _merge_range_assignments(_capture_assignments { collect(o.children) })
          .each { |key, value| assign(key, value) }

        nil
      end

      # DIRECT ASSIGNMENT
      # resolves each side of the OR into an own, nested +bool+ and assigns them as +should+.
      #
      # IMPORTANT: +minimum_should_match+ MUST be provided explicitly. Elasticsearch only defaults it
      # to 1 if the +bool+ carries no +must+ or +filter+ clause - as soon as a +where+ is chained
      # alongside the +or+, the default becomes 0 and every +should+ turns into a pure scoring hint
      # that does not restrict anything.
      # see @ ActiveRecord::Relation::WhereClause#or
      def visit_Arel_Nodes_Or(o)
        clause = {
          bool: {
            should:               _flatten_or(o).map { |node|
              { bool: _merge_range_assignments(_capture_assignments { visit(node) }).to_h }
            },
            minimum_should_match: 1
          }
        }

        # a +query_clause+ OR is visited from within an already opened +assign(key, [])+ block
        # (see @ #visit_Arel_Nodes_SelectQuery), which appends whatever the visit RETURNS.
        # A +where_clause+ OR on the other hand is resolved directly below the +bool+ node, where
        # nothing picks up a return value - so it has to assign itself.
        return clause if @within_query_clause

        assign(:filter, [clause])
      end

      def visit_Arel_Nodes_JoinSource(o)
        visit(o.left) if o.left
        raise ActiveRecord::StatementInvalid, "table joins are not supported (#{o.right})" if o.right.any?
      end

      def visit_Arel_Table(o)
        raise ActiveRecord::StatementInvalid, "table alias are not supported (#{o.table_alias})" if o.table_alias

        # set's the index name to be queried
        claim(:index, o.name)
      end

      # RAW RETURN
      def visit_Struct_Raw(o)
        o
      end

      # alias for RAW returns
      alias :visit_Integer :visit_Struct_Raw
      alias :visit_Symbol :visit_Struct_Raw
      alias :visit_Hash :visit_Struct_Raw
      alias :visit_NilClass :visit_Struct_Raw
      alias :visit_String :visit_Struct_Raw
      alias :visit_Arel_Nodes_SqlLiteral :visit_Struct_Raw

      # used by insert / update statements.
      # does not claim / assign any values!
      # returns a Hash of key => value pairs
      def visit_Arel_Nodes_ValuesList(o)
        o.rows.reduce({}) do |m, row|
          row.each do |attr|
            m[visit(attr.name)] = visit(attr.value)
          end
          m
        end
      end

      def visit_Struct_Value(o)
        o.value
      end

      alias :visit_ActiveModel_Attribute_WithCastValue :visit_Struct_Value

      def visit_Struct_Attribute(o)
        o.name
      end

      # alias for ATTRIBUTE returns
      alias :visit_Arel_Attributes_Attribute :visit_Struct_Attribute
      alias :visit_Arel_Attribute :visit_Struct_Attribute
      alias :visit_Arel_Nodes_UnqualifiedColumn :visit_Struct_Attribute
      alias :visit_ActiveModel_Attribute_FromUser :visit_Struct_Attribute

      def visit_Struct_BindValue(o)
        # IMPORTANT: For SQL defaults (see @ Arel::Collectors::SubstituteBinds) a value
        # will +not+ directly assigned (see @ Arel::Visitors::ToSql#visit_Arel_Nodes_HomogeneousIn).
        # instead it will be send as bind and then re-delegated to the SQL collector.
        #
        # This only works for linear SQL-queries and not nested Hashes
        # (otherwise we have to collect those binds, and replace them afterwards).
        #
        # Here, we'll directly assign the "real" _(casted)_ values but also provide a additional bind.
        # This will be ignored by the ElasticsearchQuery collector, but supports statement caches on the other side
        # (see @ ActiveRecord::StatementCache::PartialQueryCollector)
        self.collector.add_bind(o)

        o.value
      end

      # alias for BIND returns
      alias :visit_ActiveModel_Attribute :visit_Struct_BindValue
      alias :visit_ActiveRecord_Relation_QueryAttribute :visit_Struct_BindValue

      ##############
      # DATA TYPES #
      ##############

      def visit_Array(o)
        collect(o)
      end

      # alias for ARRAY returns
      alias :visit_Set :visit_Array

      def visit_Arel_Nodes_True(o)
        true
      end

      def visit_Arel_Nodes_False(o)
        false
      end

      ###########
      # HELPERS #
      ###########

      # assigns a single-bounded +range+ query for the provided comparison node.
      # @param [Arel::Nodes::Binary] o
      # @param [Symbol] operator - one of +:gt+, +:gte+, +:lt+, +:lte+
      def _assign_range(o, operator)
        right = visit(o.right)

        return failed! if _unusable_range_bound?(right)

        assign(:filter, [{ range: { visit(o.left) => { operator => right } } }])
      end

      # returns true if the provided range bound can never resolve a valid query.
      # @param [Object] value
      # @return [Boolean]
      def _unusable_range_bound?(value)
        unboundable?(value) || invalid?(value)
      end

      # collects all assignments the provided block would have claimed - without claiming them.
      # This reuses the +@nested+ mechanic of +#assign+, so nested assignments are gathered
      # within +@nested_args+ instead of being sent to the collector.
      # @return [Array] - array of +[key, value]+ assignment args
      def _capture_assignments
        old_nested, @nested           = @nested, true
        old_nested_args, @nested_args = @nested_args, []

        yield

        captured    = @nested_args
        @nested     = old_nested
        @nested_args = old_nested_args

        captured
      end

      # merges assignments of the same key and, within those, +range+ clauses of the same field.
      # Sibling nodes each claim their own assignment, so a exclusive range arrives as two
      # separate +[:filter, [...]]+ args that have to be joined before they can be merged.
      # @param [Array] args - array of +[key, value]+ assignment args
      # @return [Array]
      def _merge_range_assignments(args)
        joined = args.each_with_object([]) do |(key, value), result|
          existing = value.is_a?(Array) && result.find { |item| item[0] == key && item[1].is_a?(Array) }

          if existing
            existing[1] += value
          else
            result << [key, value]
          end
        end

        joined.map do |key, value|
          next [key, value] unless value.is_a?(Array)

          [key, _merge_range_clauses(value)]
        end
      end

      # merges +range+ clauses of the same field within a single clause list.
      #
      # IMPORTANT: this is DELIBERATELY strict - only a LOWER bound may be merged with an UPPER
      # bound. Two bounds of the same half must stay separate, since merging them would keep just
      # one and silently WIDEN the query:
      #   +where(year: 2022..).where(year: 2020..)+ must stay 'gte 2022 AND gte 2020'
      #   - merging it down to 'gte 2020' would resolve way too many records.
      # @param [Array] clauses
      # @return [Array]
      def _merge_range_clauses(clauses)
        clauses.each_with_object([]) do |clause, result|
          field = _sole_range_field(clause)
          other = field && result.find { |item| _mergeable_range?(item, clause, field) }

          if other
            other[:range][field] = other[:range][field].merge(clause[:range][field])
          else
            result << clause
          end
        end
      end

      # returns true if both clauses address the provided field with opposite - and non-overlapping -
      # range bounds, so they can be merged into a single clause.
      # @param [Object] clause
      # @param [Object] other
      # @param [String, Symbol] field
      # @return [Boolean]
      def _mergeable_range?(clause, other, field)
        return false unless _sole_range_field(clause) == field

        bounds       = clause[:range][field].keys
        other_bounds = other[:range][field].keys

        return false if bounds.intersect?(other_bounds)

        (bounds + other_bounds).intersect?(RANGE_LOWER_BOUNDS) &&
          (bounds + other_bounds).intersect?(RANGE_UPPER_BOUNDS)
      end

      # marks the provided block as running within a +query_clause+ assignment, where a visit
      # RETURNS its clause instead of assigning it.
      # see @ #visit_Arel_Nodes_SelectQuery / #visit_Arel_Nodes_Or
      def _within_query_clause
        old, @within_query_clause = @within_query_clause, true

        yield
      ensure
        @within_query_clause = old
      end

      # flattens nested OR nodes into a single list of operands, so a chained
      # +a.or(b).or(c)+ resolves into three sibling +should+ clauses instead of nested ones.
      # @param [Object] node
      # @return [Array]
      def _flatten_or(node)
        return [node] unless node.is_a?(::Arel::Nodes::Or)

        _flatten_or(node.left) + _flatten_or(node.right)
      end

      # returns the field name, if the provided clause is a +range+ clause of exactly one field.
      # @param [Object] clause
      # @return [String, Symbol, nil]
      def _sole_range_field(clause)
        return nil unless clause.is_a?(Hash) && clause.keys == [:range]
        return nil unless clause[:range].is_a?(Hash) && clause[:range].size == 1

        clause[:range].keys.first
      end
    end
  end
end
