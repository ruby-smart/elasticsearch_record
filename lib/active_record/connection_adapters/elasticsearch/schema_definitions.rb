# frozen_string_literal: true

require 'active_record/connection_adapters/elasticsearch/schema_definitions/attribute_methods'
require 'active_record/connection_adapters/elasticsearch/schema_definitions/column_methods'
require 'active_record/connection_adapters/elasticsearch/schema_definitions/create_table_definition'
require 'active_record/connection_adapters/elasticsearch/schema_definitions/table_alias_definition'
require 'active_record/connection_adapters/elasticsearch/schema_definitions/table_definition'
require 'active_record/connection_adapters/elasticsearch/schema_definitions/table_mapping_definition'
require 'active_record/connection_adapters/elasticsearch/schema_definitions/table_setting_definition'
require 'active_record/connection_adapters/elasticsearch/schema_definitions/update_table_definition'

module ActiveRecord
  module ConnectionAdapters
    module Elasticsearch
      # simple definitions
      CompositeUpdateTableDefinition = Struct.new(:name, :definition)
      AddMappingDefinition = Struct.new(:mappings)
      AddSettingDefinition = Struct.new(:settings)
    end
  end
end
