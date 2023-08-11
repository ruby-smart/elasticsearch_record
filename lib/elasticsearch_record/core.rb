module ElasticsearchRecord
  module Core
    extend ActiveSupport::Concern

    included do
      # Rails resolves the primary_key's value by accessing the +#id+ method.
      # Since Elasticsearch also supports an additional, independent +id+ attribute, it would only be able to access
      # this through +_read_attribute(:id)+.
      # To also have the ability of accessing this attribute through the default, this flag can be enabled.
      # @attribute! Boolean
      class_attribute :delegate_id_attribute, default: false

      # Elasticsearch's default value for queries without a +size+ is forced to +10+.
      # To provide a similar behaviour as SQL, this can be automatically set to the +max_result_window+ value.
      # @attribute! Boolean
      class_attribute :delegate_query_nil_limit, instance_writer: false, default: false
    end

    # overwrite to provide a Elasticsearch version of returning a 'primary_key' attribute.
    # Elasticsearch uses the static +_id+ column as primary_key, but also supports an additional +id+ column.
    # To provide functionality of returning the +id+ attribute, this method must also support it
    # with enabled +delegate_id_attribute+.
    # @return [Object]
    def id
      # check, if the model has a +id+ attribute
      return _read_attribute('id') if delegate_id_attribute? && has_attribute?('id')

      super
    end

    # overwrite to provide a Elasticsearch version of setting a 'primary_key' attribute.
    # Elasticsearch uses the static +_id+ column as primary_key, but also supports an additional +id+ column.
    # To provide functionality of setting the +id+ attribute, this method must also support it
    # with enabled +delegate_id_attribute+.
    # @param [Object] value
    def id=(value)
      # check, if the model has a +id+ attribute
      return _write_attribute('id', value) if delegate_id_attribute? && has_attribute?('id')

      # auxiliary update the +_id+ virtual column if we have a different primary_key
      _write_attribute('_id', value) if @primary_key != '_id'

      super
    end

    # overwrite to provide a Elasticsearch version of returning a 'primary_key' was attribute.
    # Elasticsearch uses the static +_id+ column as primary_key, but also supports an additional +id+ column.
    # To provide functionality of returning the +id_was+ attribute, this method must also support it
    # with enabled +delegate_id_attribute+.
    def id_was
      delegate_id_attribute? && has_attribute?('id') ? attribute_was('id') : super
    end

    # overwrite the write_attribute method to always write to the 'id'-attribute, if present.
    # This methods does not check for +delegate_id_attribute+ flag!
    # see @ ActiveRecord::AttributeMethods::Write#write_attribute
    def write_attribute(attr_name, value)
      return _write_attribute('id', value) if attr_name.to_s == 'id' && has_attribute?('id')

      super
    end

    # overwrite read_attribute method to read from the 'id'-attribute, if present.
    # This methods does not check for +delegate_id_attribute+ flag!
    # see @ ActiveRecord::AttributeMethods::Read#read_attribute
    def read_attribute(attr_name, &block)
      return _read_attribute('id', &block) if attr_name.to_s == 'id' && has_attribute?('id')

      super
    end

    # resets a possible active +delegate_id_attribute?+ to false during block execution.
    # Unfortunately this is required, since a lot of rails-code forces 'accessors' on the primary_key-field through the
    # +id+-getter & setter methods. This will then fail to set the doc-_id and instead set the +id+-attribute ...
    def undelegate_id_attribute_with(&block)
      return block.call unless self.delegate_id_attribute?

      self.delegate_id_attribute = false
      result = block.call
      self.delegate_id_attribute = true

      result
    end

    module PrependClassMethods
      # returns the table_name.
      # Has to be prepended to provide automated compatibility to other gems.
      def index_name
        table_name
      end
    end

    module ClassMethods
      prepend ElasticsearchRecord::Core::PrependClassMethods

      # used to create a cacheable statement.
      # This is a 1:1 copy, except that we use our own class +ElasticsearchRecord::StatementCache+
      # see @ ActiveRecord::Core::ClassMethods#cached_find_by_statement
      def cached_find_by_statement(key, &block)
        cache = @find_by_statement_cache[connection.prepared_statements]
        cache.compute_if_absent(key) { ElasticsearchRecord::StatementCache.create(connection, &block) }
      end

      # used to provide fast access to the connection API without explicit providing table-related parameters.
      # @return [anonymous Struct]
      def api
        ElasticsearchRecord::ModelApi.new(self)
      end

      private

      # creates a new relation object and extends it with our own Relation.
      # @see ActiveRecord::Core::ClassMethods#relation
      def relation
        relation = super
        # sucks, but there is no other solution yet to NOT mess with
        # ActiveRecord::Delegation::DelegateCache#initialize_relation_delegate_cache
        relation.extend ElasticsearchRecord::Extensions::Relation
        relation
      end
    end
  end
end




