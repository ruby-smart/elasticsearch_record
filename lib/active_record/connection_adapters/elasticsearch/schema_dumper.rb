# frozen_string_literal: true

require 'active_record/connection_adapters/abstract/schema_dumper'

module ActiveRecord
  module ConnectionAdapters
    module Elasticsearch
      class SchemaDumper < ActiveRecord::ConnectionAdapters::SchemaDumper # :nodoc:
        private

        def table(table, stream, nested_blocks: false, **)
          begin
            self.table_name = table

            schema     = @connection.table_schema(table)
            definition = @connection.create_table_definition(table, **schema)

            # resolve string printer
            tbl = StringIO.new

            tbl.print "  create_table #{remove_prefix_and_suffix(table).inspect}"
            tbl.print ", force: true do |t|"

            # ALIASES
            if (aliases = definition.aliases).present?
              tbl.puts

              aliases.each do |tbl_alias|
                tbl.puts "    t.alias #{tbl_alias.name.inspect}, #{format_attribute(tbl_alias.attributes)}"
              end
            end

            # MAPPINGS
            if (mappings = definition.mappings).present?
              tbl.puts

              mappings.each do |mapping|
                tbl.print "    t.mapping #{mapping.name.inspect}, :#{mapping.type}"

                if mapping.attributes.present?
                  if nested_blocks && mapping.attributes.count > 1
                    tbl.print " do |m|"
                    tbl.puts
                    mapping.attributes.each do |key, value|
                      tbl.print "      m.#{key} = #{format_attribute(value, true)}"
                      tbl.puts
                    end
                    tbl.print "    end"
                  else
                    tbl.print ", #{format_attribute(mapping.attributes)}"
                  end
                end
                tbl.puts
              end
            end

            # SETTINGS
            if (settings = definition.settings).present?
              tbl.puts

              settings.each do |setting|
                tbl.print "    t.setting #{setting.name.inspect}"

                if nested_blocks && setting.value.is_a?(Hash) && setting.value.count > 1
                  tbl.print " do |s|"
                  tbl.puts
                  setting.value.each do |key, value|
                    tbl.print "      s.#{key} = #{format_attribute(value, true)}"
                    tbl.puts
                  end
                  tbl.print "    end"
                else
                  tbl.print ", #{format_attribute(setting.value)}"
                end
                tbl.puts
              end
            end

            tbl.puts "  end"
            tbl.puts

            tbl.rewind
            stream.print tbl.read
          rescue => e
            stream.puts "# Could not dump table #{table.inspect} because of following #{e.class}"
            stream.puts "#   #{e.message}"
            stream.puts
          ensure
            self.table_name = nil
          end
        end

        def format_attribute(attribute, nested = false)
          case attribute
          when Array
            "[#{attribute.map { |value| format_attribute(value) }.join(', ')}]"
          when Hash
            if nested
              "{ #{format_attribute(attribute)} }"
            else
              attribute.map { |key, value| "#{key}: #{format_attribute(value, true)}" }.join(', ')
            end
          else
            attribute.inspect
          end
        end
      end
    end
  end
end
