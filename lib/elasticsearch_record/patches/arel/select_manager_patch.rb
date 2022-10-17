# frozen_string_literal: true

require 'arel/select_manager'
require 'arel/nodes/select_configure'
require 'arel/nodes/select_kind'
require 'arel/nodes/select_query'

module ElasticsearchRecord
  module Patches
    module Arel
      module SelectManagerPatch
        def self.included(base)
          base.send(:prepend, PrependMethods)
        end

        module PrependMethods
          def compile_update(*args)
            arel = super
            arel.kind(_kind.expr) if _kind.present?
            arel.query(_query.map(&:expr)) unless _query.empty?
            arel.configure(_configure.expr) if _configure.present?
            arel
          end

          def compile_delete(*args)
            arel = super
            arel.kind(_kind.expr) if _kind.present?
            arel.query(_query.map(&:expr)) unless _query.empty?
            arel.configure(_configure.expr) if _configure.present?
            arel
          end
        end

        def kind(value)
          if value
            @ctx.kind = ::Arel::Nodes::SelectKind.new(value)
          else
            @ctx.kind = nil
          end
        end

        def _kind
          @ctx.kind
        end

        def configure(value)
          if value
            @ast.configure = ::Arel::Nodes::SelectConfigure.new(value)
          else
            @ast.configure = nil
          end
        end

        def _configure
          @ast.configure
        end

        def query(value)
          if value.is_a?(Array)
            value.each { |val|
              @ctx.queries << ::Arel::Nodes::SelectQuery.new(val)
            }
          else
            @ctx.queries << ::Arel::Nodes::SelectQuery.new(value)
          end
        end

        def _query
          @ctx.queries
        end

        def aggs(value)
          if value.is_a?(Array)
            value.each { |val|
              @ctx.aggs << ::Arel::Nodes::SelectAgg.new(val)
            }
          else
            @ctx.aggs << ::Arel::Nodes::SelectAgg.new(value)
          end
        end

        def _aggs
          @ctx.aggs
        end
      end
    end
  end
end

# include once only!
::Arel::SelectManager.include(ElasticsearchRecord::Patches::Arel::SelectManagerPatch) unless ::Arel::SelectManager.included_modules.include?(ElasticsearchRecord::Patches::Arel::SelectManagerPatch)