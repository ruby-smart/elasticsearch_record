# frozen_string_literal: true

require_relative 'elasticsearch_record/version'
require_relative "elasticsearch_record/errors"

require 'active_record'

# new arel
require 'arel/collectors/elasticsearch_query'
require 'arel/nodes/select_agg'
require 'arel/nodes/select_configure'
require 'arel/nodes/select_kind'
require 'arel/nodes/select_query'
require 'arel/visitors/elasticsearch'

# new adapter
require 'active_record/connection_adapters/elasticsearch_adapter'

module ElasticsearchRecord
  extend ActiveSupport::Autoload

  eager_autoload do
    autoload :Base
    autoload :Core
    autoload :ModelSchema
    autoload :Persistence
    autoload :Querying
    autoload :Query
    autoload :Result
    autoload :StatementCache
  end

  module Extensions
    extend ActiveSupport::Autoload

    autoload :Relation
  end

  module Relation
    extend ActiveSupport::Autoload

    autoload :CalculationMethods
    autoload :CoreMethods
    autoload :QueryClause
    autoload :QueryClauseTree
    autoload :QueryMethods
    autoload :ResultMethods
    autoload :ValueMethods
  end

  module Tasks
    extend ActiveSupport::Autoload

    autoload :ElasticsearchDatabaseTasks, 'elasticsearch_record/tasks/elasticsearch_database_tasks'
  end
end

ActiveSupport.on_load(:active_record) do
  # load patches
  require 'elasticsearch_record/patches/active_record/relation_merger_patch'
  require 'elasticsearch_record/patches/active_record/database_configurations_hash_config_patch'

  require 'elasticsearch_record/patches/arel/select_core_patch'
  require 'elasticsearch_record/patches/arel/select_manager_patch'
  require 'elasticsearch_record/patches/arel/select_statement_patch'
  require 'elasticsearch_record/patches/arel/update_manager_patch'
  require 'elasticsearch_record/patches/arel/update_statement_patch'

  ActiveRecord::Tasks::DatabaseTasks.register_task(/elasticsearch/, "ElasticsearchRecord::Tasks::ElasticsearchDatabaseTasks")
end