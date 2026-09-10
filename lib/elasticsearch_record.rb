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
    autoload :InternalMetadata
    autoload :ModelSchema
    autoload :ModelApi
    autoload :Persistence
    autoload :Querying
    autoload :Query
    autoload :Result
    autoload :SchemaMigration
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

  ##
  # :singleton-method:
  # Specifies if a exception should be raised while using transactions.
  # Since ActiveRecord does not have any configuration option to support transactions and
  # Elasticsearch does **NOT** support transactions, it may be risky to ignore them.
  # As default, transactional are 'silently swallowed' to not break any existing applications...
  # However enabling this flag will surely fail transactional tests ...
  singleton_class.attr_accessor :error_on_transaction
  self.error_on_transaction = false

  ##
  # :singleton-method:
  # Specifies if the table (index) statements resolve their provided table name(s) with the
  # +table_name_prefix+ & +table_name_suffix+ of the connection config.
  # As default every statement decorates, so a migration only ever names the *base* table (index).
  # Disabling this flag restores the former, opt-in behaviour, where the decoration had to be
  # applied by hand through +#_env_table_name+.
  #
  # HINT: this only provides the DEFAULT for a statement that was not given an explicit
  # +decorate:+ argument - a single call can always opt in or out on its own.
  #
  # see @ ActiveRecord::ConnectionAdapters::Elasticsearch::TableStatements
  singleton_class.attr_accessor :decorate_table_names
  self.decorate_table_names = true

  ##
  # :singleton-method:
  # Specifies if a exception should be raised when a response was flagged as PARTIAL.
  # Since Elasticsearch 8.19 an ES|QL query defaults to +allow_partial_results+ and no longer fails
  # on (e.g.) an unavailable shard - it succeeds with whatever it could collect and only sets the
  # +is_partial+ flag.
  #
  # This defaults to +true+: silently handing an INCOMPLETE result-set to an application that asked
  # for a complete one is a correctness problem, not a convenience - a missed +is_partial+ shows up
  # as missing records, never as an error. Since ActiveRecord has no way to express "these rows are
  # only some of the rows", the query has to fail instead.
  #
  # Disable it to accept partial results (they stay readable through
  # +ElasticsearchRecord::Result#partial?+ either way). Alternatively the cluster can be told to
  # fail the query itself, per request (+allow_partial_results: false+) or globally
  # (+esql.query.allow_partial_results+).
  #
  # see @ ElasticsearchRecord::PartialResultsError
  singleton_class.attr_accessor :error_on_partial_results
  self.error_on_partial_results = true
end

ActiveSupport.on_load(:active_record) do
  # load patches
  require 'elasticsearch_record/patches/active_record/connection_pool_patch'
  require 'elasticsearch_record/patches/active_record/relation_merger_patch'
  require 'elasticsearch_record/patches/arel/select_core_patch'
  require 'elasticsearch_record/patches/arel/select_manager_patch'
  require 'elasticsearch_record/patches/arel/select_statement_patch'
  require 'elasticsearch_record/patches/arel/update_manager_patch'
  require 'elasticsearch_record/patches/arel/update_statement_patch'

  ActiveRecord::Tasks::DatabaseTasks.register_task(/elasticsearch/, "ElasticsearchRecord::Tasks::ElasticsearchDatabaseTasks")
end