module ElasticsearchRecord
  module Core
    extend ActiveSupport::Concern

    included do
      class_attribute :relay_id_attribute, instance_writer: false, default: false
    end

    # overwrite to provide a Elasticsearch version of returning a 'primary_key' attribute.
    # Elasticsearch uses the static +_id+ column as primary_key, but also supports an additional +id+ column.
    # To provide functionality of returning the +id+ attribute, this method must also support it.
    # @return [Object]
    def id
      # check, if the model has a +id+ attribute
      return _read_attribute('id') if relay_id_attribute? && has_attribute?('id')

      super
    end

    # overwrite to provide a Elasticsearch version of setting a 'primary_key' attribute.
    # Elasticsearch uses the static +_id+ column as primary_key, but also supports an additional +id+ column.
    # To provide functionality of setting the +id+ attribute, this method must also support it.
    # @param [Object] value
    def id=(value)
      # check, if the model has a +id+ attribute
      return _write_attribute('id', value) if relay_id_attribute? && has_attribute?('id')

      # auxiliary update the +_id+ virtual column if we have a different primary_key
      _write_attribute('_id', value) if @primary_key != '_id'

      super
    end

    # overwrite to provide a Elasticsearch version of returning a 'primary_key' was attribute.
    # Elasticsearch uses the static +_id+ column as primary_key, but also supports an additional +id+ column.
    # To provide functionality of returning the +id_Was+ attribute, this method must also support it.
    def id_was
      relay_id_attribute? && has_attribute?('id') ? attribute_was('id') : attribute_was(@primary_key)
    end

    # overwrite the write_attribute method to write 'id', if present
    # see @ ActiveRecord::AttributeMethods::Write#write_attribute
    def write_attribute(attr_name, value)
      return _write_attribute('id', value) if attr_name.to_s == 'id' && relay_id_attribute? && has_attribute?('id')

      super
    end

    # overwrite read_attribute method to read 'id', if present
    # see @ ActiveRecord::AttributeMethods::Read#read_attribute
    def read_attribute(attr_name, &block)
      return _read_attribute('id', &block) if attr_name.to_s == 'id' && relay_id_attribute? && has_attribute?('id')

      super
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




