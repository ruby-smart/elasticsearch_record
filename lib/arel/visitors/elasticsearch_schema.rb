# frozen_string_literal: true

module Arel # :nodoc: all
  module Visitors
    module ElasticsearchSchema
      extend ActiveSupport::Concern

      included do
        delegate :quote_column_name, :quote_table_name, :quote_default_expression, :type_to_sql,
                 :options_include_default?, :supports_indexes_in_create?, :supports_foreign_keys?, :foreign_key_options,
                 :quoted_columns_for_index, :supports_partial_index?, :supports_check_constraints?, :check_constraint_options,
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

        # sets the columns / mappings
        resolve(o, :visit_TableMappings) if o.columns.present?

      end

      def visit_TableMappings(o)
        assign(:mappings, {}) do
          assign(:properties, {}) do
            o.columns.each do |column|
              resolve(column) # visit_ColumnDefinition
            end
          end
        end
      end

      def visit_ColumnDefinition(o)
        assign(o.name, o.options.merge(type: o.type))
      end
    end
  end
end
