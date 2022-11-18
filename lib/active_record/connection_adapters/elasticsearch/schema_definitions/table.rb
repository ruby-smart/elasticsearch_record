# frozen_string_literal: true

require 'active_record/connection_adapters/elasticsearch/unsupported_implementation'
require 'active_record/connection_adapters/elasticsearch/schema_definitions/column_methods'
require 'active_record/connection_adapters/abstract/schema_definitions'

module ActiveRecord
  module ConnectionAdapters
    module Elasticsearch
      class Table < ActiveRecord::ConnectionAdapters::Table
        include ColumnMethods
        include UnsupportedImplementation

        define_unsupported_methods :primary_key,
                                   :index, :index_exists?, :rename_index,
                                   :references, :remove_references,
                                   :change_null,
                                   :foreign_key, :remove_foreign_key, :foreign_key_exists?,
                                   :check_constraint, :remove_check_constraint
      end
    end
  end
end
