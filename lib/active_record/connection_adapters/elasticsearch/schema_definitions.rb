# frozen_string_literal: true

module ActiveRecord
  module ConnectionAdapters
    module Elasticsearch
      # interlaced / nested definition to handle multiple grouped definitions
      InterlacedUpdateTableDefinition = Struct.new(:name, :definition)

      # mapping definitions
      AddMappingDefinition    = Struct.new(:items) # composite
      ChangeMappingDefinition = Struct.new(:items) # composite
      ChangeMetaDefinition    = Struct.new(:items) # composite

      # setting definitions
      AddSettingDefinition    = Struct.new(:items) # composite
      ChangeSettingDefinition = Struct.new(:items) # composite
      RemoveSettingDefinition = Struct.new(:items) # composite

      # alias definitions
      AddAliasDefinition    = Struct.new(:item) # single
      ChangeAliasDefinition = Struct.new(:item) # single
      RemoveAliasDefinition = Struct.new(:items) # composite
    end
  end
end

# WARNING: the loading order is mandatory and must not be changed
# ALSO: the requirements have to be below the upper definitions
require 'active_record/connection_adapters/elasticsearch/schema_definitions/attribute_methods'
require 'active_record/connection_adapters/elasticsearch/schema_definitions/column_methods'

require 'active_record/connection_adapters/elasticsearch/schema_definitions/table_alias_definition'
require 'active_record/connection_adapters/elasticsearch/schema_definitions/table_mapping_definition'
require 'active_record/connection_adapters/elasticsearch/schema_definitions/table_meta_definition'
require 'active_record/connection_adapters/elasticsearch/schema_definitions/table_setting_definition'

require 'active_record/connection_adapters/elasticsearch/schema_definitions/table_definition'
require 'active_record/connection_adapters/elasticsearch/schema_definitions/create_table_definition'
require 'active_record/connection_adapters/elasticsearch/schema_definitions/update_table_definition'
require 'active_record/connection_adapters/elasticsearch/schema_definitions/clone_table_definition'
