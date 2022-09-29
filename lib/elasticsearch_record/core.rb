module ElasticsearchRecord
  module Core
    extend ActiveSupport::Concern

    # in default, this reads the primary key column's value (+_id+).
    # But since elasticsearch supports also additional "id" columns, we need to check against that.
    def id
      has_attribute?('id') ? _read_attribute('id') : super
    end

    # in default, this sets the primary key column's value (+_id+).
    # But since elasticsearch supports also additional "id" columns, we need to check against that.
    def id=(value)
      has_attribute?('id') ? _write_attribute('id', value) : super
    end

    # overwrite the write_attribute method to write 'id', if present?
    # see @ ActiveRecord::AttributeMethods::Write#write_attribute
    def write_attribute(attr_name, value)
      return _write_attribute('id', value) if attr_name.to_s == 'id' && has_attribute?('id')

      super
    end

    # overwrite read_attribute method to read 'id', if present?
    # see @ ActiveRecord::AttributeMethods::Read#read_attribute
    def read_attribute(attr_name, &block)
      return _read_attribute('id', &block) if attr_name.to_s == 'id' && has_attribute?('id')

      super
    end

    module ClassMethods
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




