# frozen_string_literal: true

module Arel # :nodoc: all
  module Visitors
    module ElasticsearchSchema
      extend ActiveSupport::Concern

      included do
        delegate :quote_column_name, :quote_table_name, :quote_default_expression,
                 to: :connection, private: true
      end

      private

      #################
      # SCHEMA VISITS #
      #################

      def visit_TableDefinition(o)
        # prepare query
        claim(:type, ::ElasticsearchRecord::Query::TYPE_INDEX_CREATE)

        # set the name of the index
        claim(:index, visit(o.name))

        # sets settings
        resolve(o, :visit_TableSettings) if o.settings.present?

        # sets mappings
        resolve(o, :visit_TableMappings) if o.mappings.present?

        # sets aliases
        resolve(o, :visit_TableAliases) if o.aliases.present?
      end

      def visit_TableSettings(o)
        assign(:settings, {}) do
          resolve(o.settings, :visit_TableSettingDefinition)
        end
      end

      def visit_TableMappings(o)
        assign(:mappings, {}) do
          assign(:properties, {}) do
            resolve(o.mappings, :visit_TableMappingDefinition)
          end
        end
      end

      def visit_TableAliases(o)
        assign(:aliases, {}) do
          resolve(o.aliases, :visit_TableAliasDefinition)
        end
      end

      def visit_TableSettingDefinition(o)
        assign(o.name, o.value)
      end

      def visit_TableMappingDefinition(o)
        assign(o.name, o.attributes.merge({type: o.type}))
      end

      def visit_TableAliasDefinition(o)
        assign(o.name, o.attributes)
      end
    end
  end
end
