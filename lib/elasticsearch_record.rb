# frozen_string_literal: true

require_relative "elasticsearch_record/version"

require "active_record"

require 'arel/collectors/elasticsearch_query'
require 'arel/nodes/select_agg'
require 'arel/nodes/select_configure'
require 'arel/nodes/select_kind'
require 'arel/nodes/select_query'
require 'arel/visitors/elasticsearch'

module ElasticsearchRecord
  extend ActiveSupport::Autoload

  eager_autoload do
    autoload :Base
    autoload :Core
    autoload :ModelSchema
    autoload :Persistence
    autoload :Querying
    autoload :Query
    # autoload :Relation
    autoload :Result
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
end

ActiveSupport.on_load(:active_record) do
  # load patches
  require 'elasticsearch_record/patches/arel/select_core_patch'
  require 'elasticsearch_record/patches/arel/select_manager_patch'
  require 'elasticsearch_record/patches/arel/select_statement_patch'
  require 'elasticsearch_record/patches/arel/update_manager_patch'
  require 'elasticsearch_record/patches/arel/update_statement_patch'
end