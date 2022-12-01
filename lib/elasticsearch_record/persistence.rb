module ElasticsearchRecord
  module Persistence
    extend ActiveSupport::Concern

    module ClassMethods

      # insert a new record into the Elasticsearch index
      # NOTICE: We don't want to mess up with the Arel-builder - so we send new data directly to the API
      # @param [ActiveModel::Attribute] values
      # @return [Object] id
      def _insert_record(values)
        # values is not a "key=>values"-Hash, but a +ActiveModel::Attribute+ - so the casted values gets resolved here
        values = values.transform_values(&:value)

        update_auto_increment = false

        # resolve possible provided primary_key value from values
        arguments = if (id = values[self.primary_key]).present?
                      {id: id}
                    elsif self.columns_hash[self.primary_key]&.meta['auto_increment'] # BETA: should not be used on mass imports to the Elasticsearch-index
                      update_auto_increment = true
                      ids = [
                        connection.table_mappings(self.table_name).dig('properties', self.primary_key, 'meta', 'auto_increment').to_i + 1,
                        self.unscoped.all.maximum(self.primary_key).to_i + 1
                      ]
                      {id: ids.max}
                    else
                      {}
                    end

        # IMPORTANT: Always drop possible provided 'primary_key' column +_id+.
        values.delete(self.primary_key)

        # build new query
        query = ElasticsearchRecord::Query.new(
          index:     table_name,
          type:      ElasticsearchRecord::Query::TYPE_CREATE,
          body:      values,
          arguments: arguments,
          refresh:   true)

        # execute query and return inserted id
        id = connection.insert(query, "#{self} Create")

        if id.present? && update_auto_increment
          connection.change_mapping_meta(table_name, self.primary_key, auto_increment: id)
        end

        id
      end

      # updates a persistent entry in the Elasticsearch index
      # NOTICE: We don't want to mess up with the Arel-builder - so data is directly send to the API
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
      # NOTICE: We don't want to mess up with the Arel-builder - so data is directly send to the API
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