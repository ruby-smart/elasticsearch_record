# frozen_string_literal: true

require 'arel/collectors/elasticsearch_query'

module Arel # :nodoc: all
  module Visitors
    class Elasticsearch < Arel::Visitors::Visitor
      class UnsupportedVisitError < StandardError
        def initialize(dispatch_method)
          super "Unsupported dispatch method: #{dispatch_method}. Construct an Arel node instead."
        end
      end

      attr_accessor :collector

      def initialize(connection)
        super()
        @connection = connection

        # required for nested assignment.
        # see +#assign+ method
        @nested      = false
        @nested_args = []
      end

      def compile(node, collector = Arel::Collectors::ElasticsearchQuery.new)
        # we don't need to forward the collector each time - we just set it and always access it, when we need.
        self.collector = collector

        # so we just visit the first node without any additionally provided collector ...
        accept(node)

        # ... and return the final result
        self.collector.value
      end

      private

      # auto prevent visits on missing nodes
      def method_missing(method, *args, &block)
        raise(UnsupportedVisitError, method.to_s) if method.to_s[0..4] == 'visit'

        super
      end

      # collects and returns provided object 'visit' result.
      # returns an array of results if a array was provided.
      # does not validate if the object is present...
      # @param [Object] obj
      # @param [Symbol] method (default: :visit)
      # @return [Object,nil]
      def collect(obj, method = :visit)
        if obj.is_a?(Array)
          obj.map { |o| self.__send__(method, o) }
        elsif obj.present?
          self.__send__(method, obj)
        else
          nil
        end
      end

      # resolves the provided object 'visit' result.
      # check if the object is present.
      # does not return any values
      # @param [Object] obj
      # @param [Symbol] method (default: :visit)
      # @return [nil]
      def resolve(obj, method = :visit)
        return unless obj.present?

        objects = obj.is_a?(Array) ? obj : [obj]
        objects.each do |obj|
          self.__send__(method, obj)
        end

        nil
      end

      # assign provided args on the collector.
      # The TOP-Level assignment must be a (key, value) while sub-assignments will be collected by provided block.
      # Sub-assignments will never claim on the query but 'merged' to the TOP-assignment.
      #
      #   assign(:query, {}) do
      #    #... do some stuff ...
      #    assign(:bool, {}) do
      #     assign(:x,99)
      #     assign({y: 45})
      #    end
      #   end
      #   #> query: {bool: {x: 99, y: 45}}
      def assign(*args)
        # resolve possible TOP-LEVEL assignment
        key, value = args

        # if a block was provided we want to collect the nested assignments
        if block_given?
          raise ArgumentError, "Unsupported assignment value for provided block (#{key}). Provide any Object as value!" if value.nil?

          # set nested state to tell all nested assignments to not claim it's values
          old_nested, @nested = @nested, true
          old_nested_args, @nested_args = @nested_args, []

          # call block, but don't interact with its return.
          # nested args are separately stored
          yield

          # restore nested state
          @nested = old_nested

          # assign nested args
          @nested_args.each do |nested_args|
            # ARRAY assignment
            case value
            when Array
              if nested_args[0].is_a?(Array)
                value += nested_args[0]
              else
                value << nested_args[0]
              end
            when Hash
              if nested_args[0].is_a?(Hash)
                value.merge!(nested_args[0])
              elsif value[nested_args[0]].is_a?(Hash) && nested_args[1].is_a?(Hash)
                value[nested_args[0]] = value[nested_args[0]].merge(nested_args[1])
              elsif value[nested_args[0]].is_a?(Array) && nested_args[1].is_a?(Array)
                value[nested_args[0]] += nested_args[1]
              elsif nested_args[1].nil?
                value.delete(nested_args[0])
              else
                value[nested_args[0]] = nested_args[1]
              end
            when String
              if nested_args[0].is_a?(Array)
                value = value + nested_args[0].map(&:to_s).join
              else
                value = value + nested_args[0].to_s
              end
            else
              value = nested_args[0] unless nested_args.blank?
            end
          end

          # clear nested args
          @nested_args = old_nested_args
        end

        # for nested assignments we only want the assignable args - no +claim+ on the query!
        if @nested
          @nested_args << args
          return
        end

        raise ArgumentError, "Unsupported assign key: '#{key}' for provided block. Provide a Symbol as key!" unless key.is_a?(Symbol)

        claim(:assign, key, value)
      end

      # creates and sends a new claim to the collector.
      # @param [Symbol] action - claim action (:index, :type, :status, :argument, :body, :assign)
      # @param [Array] args - either <key>,<value> or <Hash{<key> => <value>, ...}> or <Array>
      def claim(action, *args)
        self.collector << [action, args]
      end

      ######################
      # CORE VISITS (CRUD) #
      ######################

      # SELECT // SEARCH
      def visit_Arel_Nodes_SelectStatement(o)
        # prepare query
        claim(:type, ::ElasticsearchRecord::Query::TYPE_SEARCH)

        resolve(o.cores) # visit_Arel_Nodes_SelectCore

        resolve(o.orders) # visit_Sort
        resolve(o.limit) # visit_Arel_Nodes_Limit
        resolve(o.offset) # visit_Arel_Nodes_Offset

        # configure is able to overwrite everything in the query
        resolve(o.configure)
      end

      # UPDATE
      def visit_Arel_Nodes_UpdateStatement(o)
        # switch between updating a single Record or multiple by query
        if o.relation.is_a?(::Arel::Table)
          raise NotImplementedError, "if you've made it this far, something went wrong ..."
        end

        # prepare query
        claim(:type, ::ElasticsearchRecord::Query::TYPE_UPDATE_BY_QUERY)

        # sets the index
        resolve(o.relation)

        # updating multiple entries need a script
        assign(:script, {}) do
          assign(:inline, "") do
            updates = collect(o.values)
            assign(updates.join('; ')) if updates
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

      # DELETE
      def visit_Arel_Nodes_DeleteStatement(o)
        # switch between updating a single Record or multiple by query
        if o.relation.is_a?(::Arel::Table)
          raise NotImplementedError, "if you've made it this far, something went wrong ..."
        end

        # prepare query
        claim(:type, ::ElasticsearchRecord::Query::TYPE_DELETE_BY_QUERY)

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

      # INSERT
      def visit_Arel_Nodes_InsertStatement(o)
        # switch between updating a single Record or multiple by query
        if o.relation.is_a?(::Arel::Table)
          raise NotImplementedError, "if you've made it this far, something went wrong ..."
        end

        raise NotImplementedError
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
        claim(:columns, o.source.left.instance_variable_get(:@klass).source_column_names)

        # sets the query
        resolve(o, :visit_Query) if o.queries.present? || o.wheres.present?

        # sets the aggs
        resolve(o, :visit_Aggs) if o.aggs.present?

        # sets the selects
        resolve(o, :visit_Selects) if o.projections.present?
      end

      # CUSTOM node by elasticsearch_record
      def visit_Query(o)
        # in some cases we don't have a kind, but where conditions.
        # in this case we force the kind as +:bool+.
        kind = :bool if o.wheres.present? && o.kind.blank?

        # resolve kind, if not already set
        kind ||= o.kind.present? ? visit(o.kind.expr) : nil

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

          # we support a special key: _rand to create a simple random method ...
          if key == '_rand'
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

        return failed! if unboundable?(right)

        key = visit(o.left)

        if right.nil?
          # transforms nil to exists
          assign(:must_not, [{ exists: { field:  key } }])
        else
          assign(:filter, [{ term: { key => right } }])
        end
      end

      # DIRECT ASSIGNMENT
      def visit_Arel_Nodes_NotEqual(o)
        right = visit(o.right)

        return failed! if unboundable?(right)

        key = visit(o.left)

        if right.nil?
          # transforms nil to exists
          assign(:filter, [{ exists: { field:  key } }])
        else
          assign(:must_not, [{ term: { key => right } }])
        end
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

      def visit_Arel_Nodes_And(o)
        collect(o.children)
      end

      def visit_Arel_Nodes_JoinSource(o)
        sources = []
        sources << visit(o.left) if o.left
        sources += collect(o.right) if o.right

        claim(:index, sources.join(', '))
      end

      def visit_Arel_Table(o)
        raise ActiveRecord::StatementInvalid, "table alias are not supported (#{o.table_alias})" if o.table_alias

        o.name
      end

      def visit_Struct_Raw(o)
        o
      end

      alias :visit_Symbol :visit_Struct_Raw
      alias :visit_Hash :visit_Struct_Raw
      alias :visit_NilClass :visit_Struct_Raw
      alias :visit_String :visit_Struct_Raw
      alias :visit_Arel_Nodes_SqlLiteral :visit_Struct_Raw

      def visit_Struct_Value(o)
        o.value
      end

      alias :visit_Integer :visit_Struct_Value
      alias :visit_ActiveModel_Attribute_WithCastValue :visit_Struct_Value

      def visit_Struct_Attribute(o)
        o.name
      end

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


      alias :visit_ActiveModel_Attribute :visit_Struct_BindValue
      alias :visit_ActiveRecord_Relation_QueryAttribute :visit_Struct_BindValue

      ##############
      # DATA TYPES #
      ##############

      def visit_Array(o)
        collect(o)
      end

      alias :visit_Set :visit_Array

      ###########
      # HELPERS #
      ###########

      def unboundable?(value)
        value.respond_to?(:unboundable?) && value.unboundable?
      end

      def quote(value)
        return value if Arel::Nodes::SqlLiteral === value
        @connection.quote value
      end

      # assigns a failed status to the current query
      def failed!
        assign(:status, ElasticsearchRecord::Query::STATUS_FAILED)

        nil
      end
    end
  end
end
