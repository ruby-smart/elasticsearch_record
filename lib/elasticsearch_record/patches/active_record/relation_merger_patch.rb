# frozen_string_literal: true

require 'active_record/relation/merger'

module ElasticsearchRecord
  module Patches
    module ActiveRecord
      module RelationMergerPatch
        def self.included(base)
          base.send(:prepend, PrependMethods)
        end

        module PrependMethods
          def merge
            if other.respond_to?(:kind_value) && !relation.respond_to?(:kind_value)
              assign_elasticsearch_relation!
            end

            super
          end


          private

          def merge_single_values
            super

            relation.kind_value ||= other.kind_value if other.kind_value
          end

          def merge_multi_values
            super

            relation.configure_value = relation.configure_value.merge(other.configure_value) if other.configure_value.present?
          end

          def merge_clauses
            super

            query_clause = relation.query_clause.merge(other.query_clause)
            relation.query_clause = query_clause unless query_clause.empty?

            aggs_clause = relation.aggs_clause.merge(other.aggs_clause)
            relation.aggs_clause = aggs_clause unless aggs_clause.empty?
          end

          def assign_elasticsearch_relation!
            # sucks, but there is no other solution yet to NOT mess with
            # ActiveRecord::Delegation::DelegateCache#initialize_relation_delegate_cache
            relation.extend ElasticsearchRecord::Extensions::Relation
          end
        end
      end
    end
  end
end

# include once only!
::ActiveRecord::Relation::Merger.include(ElasticsearchRecord::Patches::ActiveRecord::RelationMergerPatch) unless ::ActiveRecord::Relation::Merger.included_modules.include?(ElasticsearchRecord::Patches::ActiveRecord::RelationMergerPatch)