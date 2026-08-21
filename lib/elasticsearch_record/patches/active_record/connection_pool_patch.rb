# frozen_string_literal: true

require 'active_record/connection_adapters/abstract/connection_pool'

module ElasticsearchRecord
  module Patches
    module ActiveRecord
      # Since rails 7.2 the migration plumbing is resolved through the connection POOL
      # (+ConnectionPool#migration_context+ builds from +#migrations_paths+, +#schema_migration+ &
      # +#internal_metadata+) instead of the connection - so the adapters own implementations are
      # no longer consulted. Without this patch a Elasticsearch pool would migrate with the generic
      # +ActiveRecord::SchemaMigration+ (which resolves the index name through +ActiveRecord::Base+
      # and only ever sees the first ten migrations - Elasticsearch default search size), enable the
      # internal metadata index (the adapter cannot serve it) and fall back to the default
      # 'db/migrate' path.
      #
      # The patch simply routes those factories back to the adapter class, which keeps the
      # Elasticsearch-specific implementations in one place.
      module ConnectionPoolPatch
        def self.included(base)
          base.send(:prepend, PrependMethods)
        end

        module PrependMethods
          def migrations_paths
            return super unless elasticsearch_pool?

            db_config.migrations_paths || ['db/migrate_elasticsearch']
          end

          def schema_migration
            return super unless elasticsearch_pool?

            ElasticsearchRecord::SchemaMigration.new(self)
          end

          def internal_metadata
            return super unless elasticsearch_pool?

            ElasticsearchRecord::InternalMetadata.new(self)
          end

          private

          # returns true, if the pools config resolves to the Elasticsearch adapter
          # @return [Boolean]
          def elasticsearch_pool?
            db_config.adapter_class <= ::ActiveRecord::ConnectionAdapters::ElasticsearchAdapter
          end
        end
      end
    end
  end
end

# include once only!
::ActiveRecord::ConnectionAdapters::ConnectionPool.include(ElasticsearchRecord::Patches::ActiveRecord::ConnectionPoolPatch) unless ::ActiveRecord::ConnectionAdapters::ConnectionPool.included_modules.include?(ElasticsearchRecord::Patches::ActiveRecord::ConnectionPoolPatch)
