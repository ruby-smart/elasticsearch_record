# frozen_string_literal: true

module Arel # :nodoc: all
  module Visitors
    module ElasticsearchSchema
      extend ActiveSupport::Concern

      included do
        delegate :type_to_sql,
                 to: :connection, private: true
      end

      private

      #################
      # SCHEMA VISITS #
      #################

      def visit_CreateTableDefinition(o)
        # prepare query
        claim(:type, ::ElasticsearchRecord::Query::TYPE_INDEX_CREATE)

        # set the name of the index
        claim(:index, visit(o.name))

        if o.metas.present? || o.mappings.present?
          assign(:mappings, {}) do
            # sets metas
            resolve(o, :visit_TableMetas) if o.metas.present?

            # sets mappings
            resolve(o, :visit_TableMappings) if o.mappings.present?
          end
        end

        # sets settings
        resolve(o, :visit_TableSettings) if o.settings.present?

        # sets aliases
        resolve(o, :visit_TableAliases) if o.aliases.present?
      end

      def visit_CloneTableDefinition(o)
        # prepare query
        claim(:type, ::ElasticsearchRecord::Query::TYPE_INDEX_CLONE)

        # set the name of the index
        claim(:index, visit(o.name))

        # set the name of the target
        claim(:argument, :target, visit(o.target))

        # sets settings
        resolve(o, :visit_TableSettings) if o.settings.present?

        # sets aliases
        resolve(o, :visit_TableAliases) if o.aliases.present?
      end

      def visit_InterlacedUpdateTableDefinition(o)
        # set the name of the index
        claim(:index, visit(o.name))

        # prepare definition
        visit(o.definition)
      end

      def visit_ChangeMetaDefinition(o)
        # prepare query
        claim(:type, ::ElasticsearchRecord::Query::TYPE_INDEX_UPDATE_MAPPING)

        assign(:_meta, {}) do
          resolve(o.items, :visit_TableMetaDefinition)
        end
      end

      def visit_ChangeMappingDefinition(o)
        # prepare query
        claim(:type, ::ElasticsearchRecord::Query::TYPE_INDEX_UPDATE_MAPPING)

        assign(:properties, {}) do
          resolve(o.items, :visit_TableMappingDefinition)
        end
      end

      alias :visit_AddMappingDefinition :visit_ChangeMappingDefinition

      def visit_ChangeSettingDefinition(o)
        # prepare query
        claim(:type, ::ElasticsearchRecord::Query::TYPE_INDEX_UPDATE_SETTING)

        # special overcomplicated blocks to assign a hash of settings directly to the body
        assign(:__claim__, {}) do
          assign(:body, {}) do
            resolve(o.items, :visit_TableSettingDefinition)
          end
        end
      end

      alias :visit_AddSettingDefinition :visit_ChangeSettingDefinition
      alias :visit_DeleteSettingDefinition :visit_ChangeSettingDefinition

      def visit_ChangeAliasDefinition(o)
        # prepare query
        claim(:type, ::ElasticsearchRecord::Query::TYPE_INDEX_UPDATE_ALIAS)

        claim(:argument, :name, o.item.name)
        claim(:body, o.item.attributes)
      end

      alias :visit_AddAliasDefinition :visit_ChangeAliasDefinition

      def visit_DeleteAliasDefinition(o)
        # prepare query
        claim(:type, ::ElasticsearchRecord::Query::TYPE_INDEX_DELETE_ALIAS)

        claim(:argument, :name, o.items.map(&:name).join(','))
      end

      ##############
      # SUB VISITS #
      ##############

      def visit_TableSettings(o)
        assign(:settings, {}) do
          resolve(o.settings, :visit_TableSettingDefinition)
        end
      end

      def visit_TableMappings(o)
        assign(:properties, {}) do
          resolve(o.mappings, :visit_TableMappingDefinition)
        end
      end

      def visit_TableMetas(o)
        assign(:_meta, {}) do
          resolve(o.metas, :visit_TableMetaDefinition)
        end
      end

      def visit_TableAliases(o)
        assign(:aliases, {}) do
          resolve(o.aliases, :visit_TableAliasDefinition)
        end
      end

      def visit_TableSettingDefinition(o)
        assign(o.name, o.value, :__force__)
      end

      def visit_TableMetaDefinition(o)
        assign(o.name, o.value)
      end

      def visit_TableMappingDefinition(o)
        assign(o.name, o.attributes.merge({ type: type_to_sql(o.type) }))
      end

      def visit_TableAliasDefinition(o)
        assign(o.name, o.attributes)
      end
    end
  end
end
