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
            # check for relation mismatch - prevent mash up different relations
            if elasticsearch_relation? && !other_elasticsearch_relation?
              message = "#{relation.class_name}(##{relation.klass.object_id}) expected, "\
                "got #{other.inspect} which is an instance of #{other.class}(##{other.class.object_id})"
              raise ActiveRecord::AssociationTypeMismatch, message
            end

            # enable & assign elasticsearch merger
            if other_elasticsearch_relation? && !elasticsearch_relation?
              assign_elasticsearch_relation!
            end

            super
          end

          private

          # return true if this is a elasticsearch enabled relation
          def elasticsearch_relation?
            @elasticsearch_relation ||= relation.respond_to?(:kind_value)
          end

          # return true if the other relation is a elasticsearch enabled relation
          def other_elasticsearch_relation?
            @other_elasticsearch_relation ||= other.respond_to?(:kind_value)
          end

          def merge_single_values
            super

            # only for enabled elasticsearch relation
            if elasticsearch_relation?
              relation.kind_value ||= other.kind_value if other.kind_value.present?
            end
          end

          def merge_multi_values
            super

            # only for enabled elasticsearch relation
            if elasticsearch_relation?
              relation.configure_value = relation.configure_value.merge(other.configure_value) if other.configure_value.present?
            end
          end

          def merge_clauses
            super

            # only for enabled elasticsearch relation
            if elasticsearch_relation?
              query_clause          = relation.query_clause.merge(other.query_clause)
              relation.query_clause = query_clause unless query_clause.empty?

              aggs_clause          = relation.aggs_clause.merge(other.aggs_clause)
              relation.aggs_clause = aggs_clause unless aggs_clause.empty?
            end
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