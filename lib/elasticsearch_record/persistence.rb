module ElasticsearchRecord
  module Persistence
    extend ActiveSupport::Concern

    module ClassMethods

      # insert a new record into the Elasticsearch index
      # NOTICE: We don't want to mess up with the Arel-builder - so we send new data directly to the API
      def _insert_record(values)
        # values is not a "key=>values"-Hash, but a +ActiveModel::Attribute+ - so we need to resolve the casted values here
        values = values.transform_values(&:value)

        # if a primary_key (e.g. +_id+) was provided, we need to extract this and allocate this to the arguments
        arguments = if self.primary_key == '_id' && (id = values.delete(self.primary_key)).present?
                      { id: id }
                    elsif (id = values[self.primary_key]).present?
                      { id: id }
                    else
                      {}
                    end

        # build new query
        query = ElasticsearchRecord::Query.new(
          index:     table_name,
          type:      ElasticsearchRecord::Query::TYPE_CREATE,
          body:      values,
          arguments: arguments,
          refresh:   true)

        # execute query and return inserted id
        connection.insert(query, "#{self} Create")
      end

      # updates a persistent entry in the Elasticsearch index
      # NOTICE: We don't want to mess up with the Arel-builder - so we send new data directly to the API
      def _update_record(values, constraints)
        # values is not a "key=>values"-Hash, but a +ActiveModel::Attribute+ - so we need to resolve the casted values here
        values = values.transform_values(&:value)

        # build new query
        query = ElasticsearchRecord::Query.new(
          index:     table_name,
          type:      ElasticsearchRecord::Query::TYPE_UPDATE,
          body:      { doc: values },
          arguments: { id: constraints[self.primary_key] },
          refresh:   true)

        # execute query and return total updates
        connection.update(query, "#{self} Update")
      end

      # removes a persistent entry from the Elasticsearch index
      # NOTICE: We don't want to mess up with the Arel-builder - so we send new data directly to the API
      def _delete_record(constraints)
        # build new query
        query = ElasticsearchRecord::Query.new(
          index:     table_name,
          type:      ElasticsearchRecord::Query::TYPE_DELETE,
          arguments: { id: constraints[self.primary_key] },
          refresh:   true)

        # execute query and return total deletes
        connection.delete(query, "#{self} Delete")
      end
    end
  end
end