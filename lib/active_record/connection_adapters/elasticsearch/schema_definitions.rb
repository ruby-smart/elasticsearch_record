# frozen_string_literal: true

require 'active_record/connection_adapters/elasticsearch/unsupported_implementation'
require 'active_record/connection_adapters/abstract/schema_definitions'

module ActiveRecord
  module ConnectionAdapters
    module Elasticsearch
      module ColumnMethods
        extend ActiveSupport::Concern

        included do

          # toDo :define!
          # define_column_methods :blob, :tinyblob, :mediumblob, :longblob,
          #   :tinytext, :mediumtext, :longtext, :unsigned_integer, :unsigned_bigint,
          #   :unsigned_float, :unsigned_decimal
        end
      end

      ColumnDefinition = Struct.new(:name, :type, :options) do
        # :nodoc:

        def default=(value)
          options[:null_value] = value
        end

        def to_h
          options.merge(name: name, type: type)
        end

        [:enabled, :fielddata, :fields, :properties, :index, :meta, :null_value, :dynamic].each do |option_name|
          module_eval <<-CODE, __FILE__, __LINE__ + 1
          def #{option_name}
            options[:#{option_name}]
          end

          def #{option_name}=(value)
            options[:#{option_name}] = value
          end
          CODE
        end
      end

      class TableDefinition < ActiveRecord::ConnectionAdapters::TableDefinition
        include ColumnMethods
        include UnsupportedImplementation

        define_unsupported_methods :temporary, :options, :as, :comment, :indexes, :foreign_keys, :check_constraints

        attr_reader :settings, :mappings, :aliases

        def initialize(conn, name, settings: {}, mappings: {}, aliases: {}, **)
          super

          @settings = settings.with_indifferent_access
          @aliases  = aliases.with_indifferent_access

          transform_mappings!(mappings.with_indifferent_access)
        end

        def new_column_definition(name, type, **options)
          create_column_definition(name, type, options)
        end

        def setting(name, value, **options)
          return if @settings.key?(name) && !options[:force]
          @settings[name] = value
        end

        def remove_setting(name)
          @settings.delete name
        end

        def alias(name, value, **options)
          return if @aliases.key?(name) && !options[:force]
          @aliases[name] = value
        end

        def remove_alias(name)
          @aliases.delete name
        end

        private

        def create_column_definition(name, type, options)
          ColumnDefinition.new(name, type, options)
        end

        def transform_mappings!(mappings)
          return unless mappings[:properties].present?

          mappings[:properties].each do |name, options|
            column(name, options[:type], **options)
          end
        end

      end

      class Table < ActiveRecord::ConnectionAdapters::Table
        include ColumnMethods
        include UnsupportedImplementation

        define_unsupported_methods :primary_key, :rename_index, :references, :remove_references,
                                   :foreign_key, :remove_foreign_key, :foreign_key_exists?, :check_constraint,
                                   :remove_check_constraint
      end
    end
  end
end
