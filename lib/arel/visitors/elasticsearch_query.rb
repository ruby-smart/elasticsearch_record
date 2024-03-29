# frozen_string_literal: true

module Arel # :nodoc: all
  module Visitors
    module ElasticsearchQuery
      extend ActiveSupport::Concern

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
        # To prevent NOT-accessible attributes, we need to provide the "full-column-definition" to the query.
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
        when ::ActiveRecord::FinderMethods::ONE_AS_ONE
          # force return NO fields
          assign(:_source, false)
        else
          assign(:_source, fields)
          # also overwrite the columns in the query
          claim(:columns, fields)
        end
      end

      # CUSTOM node by elasticsearch_record
      def visit_Create(o)
        # sets values
        if o.values
          values = collect(o.values) # visit_Arel_Nodes_ValuesList
          claim(:body, values) if values.present?
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
          assign(visit(o.right))
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

      # DIRECT FAIL
      def visit_Arel_Nodes_Grouping(o)
        # grouping is NOT supported and will force to fail the query
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
          assign(:filter, [{ terms: { o.column_name => o.casted_values } }])
        else
          assign(:must_not, [{ terms: { o.column_name => o.casted_values } }])
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
        collect(o.children)
      end

      # # toDo: doesn't work properly - maybe restructure OR-assignments
      # def visit_Arel_Nodes_Or(o)
      #   # If the bool query includes at least one should clause and no must or filter clauses, the default value is 1.
      #   # Otherwise, the default value is 0.
      #   assign(:should, []) do
      #     assign(nil, {}) do
      #
      #     stack = [o.right, o.left]
      #
      #     while o = stack.pop
      #       if o.is_a?(Arel::Nodes::Or)
      #         stack.push o.right, o.left
      #       elsif o.is_a?(ElasticsearchRecord::Relation::QueryClause)
      #         assign(visit(o.ast[1]))
      #       else
      #         visit o
      #       end
      #     end
      #   end
      #   end
      # end

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
    end
  end
end
