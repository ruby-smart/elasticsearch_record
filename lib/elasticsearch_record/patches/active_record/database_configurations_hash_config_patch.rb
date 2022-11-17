# frozen_string_literal: true

require 'active_record/database_configurations/hash_config'

module ElasticsearchRecord
  module Patches
    module ActiveRecord
      module DatabaseConfigurationsHashConfigPatch
        def self.included(base)
          base.send(:prepend, PrependMethods)
        end

        module PrependMethods
          def database_tasks?
            # fix, that configurations cannot be used if no database is available ...
            super && !!database
          end
        end
      end
    end
  end
end

# include once only!
::ActiveRecord::DatabaseConfigurations::HashConfig.include(ElasticsearchRecord::Patches::ActiveRecord::DatabaseConfigurationsHashConfigPatch) unless ::ActiveRecord::DatabaseConfigurations::HashConfig.included_modules.include?(ElasticsearchRecord::Patches::ActiveRecord::DatabaseConfigurationsHashConfigPatch)