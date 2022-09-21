module ElasticsearchRecord
  module Persistence
    extend ActiveSupport::Concern

    module ClassMethods

      # insert a new record into the Elasticsearch index
      # NOTICE: We don't want to mess up with the Arel-builder - so we send new data directly to the API
      def _insert_record(values)
        # values is not a "key=>values"-Hash, but a +ActiveModel::Attribute+ - so we need to resolve the casted values here
        values = values.transform_values(&:value)

        # if a primary_key (+_id+) was provided, we need to extract this and allocate this to the arguments
        arguments = if (id = values.delete(self.primary_key)).present?
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

        # execute query and build a RAW response
        response = connection.exec_query(query, "#{self} Create").response

        raise RecordNotSaved unless response['result'] == 'created'

        # return the new id
        response['_id']
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
          arguments: { id: constraints['_id'] },
          refresh:   true)

        # execute query and build a RAW response
        response = connection.exec_query(query, "#{self} Update").response

        raise RecordNotSaved unless response['result'] == 'updated'

        # return affected rows
        response['_shards']['total']
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

        # execute query and build a RAW response
        response = connection.exec_query(query, "#{self} Destroy").response

        raise RecordNotDestroyed unless response['result'] == 'deleted'

        # return affected rows
        response['_shards']['total']
      end
    end
  end
end