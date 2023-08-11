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

        # resolve & update a auto_increment value, if configured
        _insert_with_auto_increment(values) do |arguments|
          # build new query
          query = ElasticsearchRecord::Query.new(
            index:     table_name,
            type:      ElasticsearchRecord::Query::TYPE_CREATE,
            # IMPORTANT: always exclude possible provided +_id+ field
            body:      values.except('_id'),
            arguments: arguments,
            refresh:   true)

          # execute query and return inserted id
          connection.insert(query, "#{self} Create")
        end
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

      private

      # Resolves the +auto_increment+ status from the tables +_meta+ attributes.
      def _insert_with_auto_increment(values)
        # check, if the primary_key's value is provided.
        # so, no need to resolve a +auto_increment+ value, but provide the id directly
        if (id = values[self.primary_key]).present?
          yield({id: id})
        elsif auto_increment?
          # future increments: uuid (+uuidv6 ?), hex, radix(2-36), integer
          # allocated through: primary_key_type

          ids = [
            # try to resolve the current-auto-increment value from the tables meta
            connection.table_metas(self.table_name).dig('auto_increment').to_i + 1,
            # for secure reasons: also resolve the current maximum value for the primary key
            self.unscoped.all.maximum(self.primary_key).to_i + 1
          ]

          id = yield({ id: ids.max })

          if id.present?
            connection.change_meta(self.table_name, :auto_increment, id)
          end

          # return inserted id
          id
        else
          yield({})
        end
      end
    end

    # overwrite to provide a Elasticsearch version:
    # Creates a record with values matching those of the instance attributes
    # and returns its id.
    def _create_record(*args)
      undelegate_id_attribute_with do
        super
      end
    end
  end
end