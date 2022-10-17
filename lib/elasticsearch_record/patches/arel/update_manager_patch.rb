# frozen_string_literal: true

require 'arel/update_manager'
require 'arel/delete_manager'

require 'arel/nodes/select_configure'
require 'arel/nodes/select_kind'
require 'arel/nodes/select_query'

module ElasticsearchRecord
  module Patches
    module Arel
      module UpdateManagerPatch
        def kind(value)
          if value
            @ast.kind = ::Arel::Nodes::SelectKind.new(value)
          else
            @ast.kind = nil
          end
        end

        def configure(value)
          if value
            @ast.configure = ::Arel::Nodes::SelectConfigure.new(value)
          else
            @ast.configure = nil
          end
        end

        def query(value)
          if value.is_a?(Array)
            value.each { |val|
              @ast.queries << ::Arel::Nodes::SelectQuery.new(val)
            }
          else
            @ast.queries << ::Arel::Nodes::SelectQuery.new(value)
          end
        end
      end
    end
  end
end

# include once only!
::Arel::UpdateManager.include(ElasticsearchRecord::Patches::Arel::UpdateManagerPatch) unless ::Arel::UpdateManager.included_modules.include?(ElasticsearchRecord::Patches::Arel::UpdateManagerPatch)
::Arel::DeleteManager.include(ElasticsearchRecord::Patches::Arel::UpdateManagerPatch) unless ::Arel::DeleteManager.included_modules.include?(ElasticsearchRecord::Patches::Arel::UpdateManagerPatch)