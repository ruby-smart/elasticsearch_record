# frozen_string_literal: true

require 'active_model/validations'

module ActiveRecord
  module ConnectionAdapters
    module Elasticsearch
      class TableSettingDefinition
        include AttributeMethods
        include ActiveModel::Validations

        # exclude settings, that are provided through the API but are not part of the index-settings API
        IGNORE_NAMES = ['provided_name', 'creation_date', 'uuid', 'version', 'routing.allocation.initial_recovery', 'resize'].freeze

        # available setting names
        # - see @ https://www.elastic.co/guide/en/elasticsearch/reference/current/index-modules.html#index-modules-settings

        # final names can only be set during index creation
        FINAL_NAMES = ['number_of_shards', 'routing_partition_size', 'soft_deletes.enabled'].freeze

        # static names can only be set during index creation or closed
        STATIC_NAMES = ['number_of_routing_shards', 'codec', 'mode',
                        'soft_deletes.retention_lease.period',
                        'load_fixed_bitset_filters_eagerly', 'shard.check_on_startup',
                        # index sorting & the query cache can only be chosen at creation time
                        'sort', 'queries',
                        # the '_source' mode (synthetic vs. stored) is fixed at creation time
                        'mapping.source.mode',
                        # time series data streams (TSDS)
                        'time_series',

                        # modules
                        'analysis', 'routing', 'unassigned', 'merge', 'similarity', 'search', 'store', 'indexing_pressure'].freeze

        # dynamic names can always be changed
        DYNAMIC_NAMES = ['number_of_replicas', 'auto_expand_replicas', "search.idle.after", 'refresh_interval',
                         'max_result_window', 'max_inner_result_window', 'max_rescore_window',
                         'max_docvalue_fields_search', 'max_script_fields', 'max_ngram_diff', 'max_shingle_diff',
                         'max_refresh_listeners', 'analyze.max_token_count', 'highlight.max_analyzed_offset',
                         'max_terms_count', 'max_regex_length', 'query.default_field', 'routing.allocation.enable',
                         'routing.rebalance.enable', 'gc_deletes', 'default_pipeline', 'final_pipeline',
                         'hidden', 'blocks', 'priority', 'max_slices_per_scroll',
                         # the 'end_time' is the one TSDS setting that can be rolled forward
                         'time_series.end_time',

                         # modules
                         'translog', 'mapping', 'lifecycle', 'write', 'search.slowlog', 'indexing.slowlog'].freeze

        VALID_NAMES = (FINAL_NAMES + STATIC_NAMES + DYNAMIC_NAMES).freeze

        # attributes
        attr_accessor :name
        attr_accessor :value

        # validations
        validates_presence_of :name

        # disable validation for name - maybe future updates of Elasticsearch have other names.
        # To not be hooked on those possible changes we disable the validation
        validate :_validate_name
        validate :_validate_final_name
        validate :_validate_static_name

        def self.match_ignore_names?(name)
          IGNORE_NAMES.any? { |invalid| name.match?(invalid) }
        end

        def self.match_valid_names?(name)
          !!_best_match(VALID_NAMES, name)
        end

        def self.match_final_names?(name)
          _resolve_scope(name) == :final
        end

        def self.match_dynamic_names?(name)
          _resolve_scope(name) == :dynamic
        end

        def self.match_static_names?(name)
          _resolve_scope(name) == :static
        end

        # returns the longest entry from +names+ that either IS the provided +name+ or is one of its
        # dot-separated parents (its 'module') - or +nil+ if none applies.
        #
        # PLEASE NOTE: this used to be a +String#match?+ (substring) check, which matched far too
        # much - 'research' matched the 'search' module and every +index.mapping.*+ name was
        # rejected outright since no entry was a substring of it.
        #
        # PLEASE NOTE: a leading 'index.' is stripped first - the API returns (and a migration may
        # provide) every setting under that namespace, but the name lists are stored without it.
        #
        # @param [Array<String>] names
        # @param [String] name
        # @return [String, nil]
        def self._best_match(names, name)
          name = name.delete_prefix('index.')

          names.select { |valid| name == valid || name.start_with?("#{valid}.") }.max_by(&:length)
        end

        # resolves the scope (+:final+, +:static+ or +:dynamic+) a setting name belongs to.
        #
        # IMPORTANT: the MOST SPECIFIC entry wins - a name may match a module in one list and an
        # explicit entry in another. 'search.idle.after' matches the static 'search' module, but is
        # itself listed as dynamic - so it must resolve as dynamic (otherwise it could never be
        # changed on an open index).
        #
        # @param [String] name
        # @return [Symbol, nil]
        def self._resolve_scope(name)
          { final: FINAL_NAMES, static: STATIC_NAMES, dynamic: DYNAMIC_NAMES }.
            filter_map { |scope, names| (match = _best_match(names, name)) && [scope, match.length] }.
            max_by(&:last)&.first
        end

        def initialize(name, value)
          @name  = name.to_s
          @value = value
        end

        def final?
          @final = flat_names.all? { |flat_name| self.class.match_final_names?(flat_name) } if @final.nil?
          @final
        end

        def static?
          @static = flat_names.all? { |flat_name| self.class.match_static_names?(flat_name) } if @static.nil?
          @static
        end

        def dynamic?
          @dynamic = flat_names.all? { |flat_name| self.class.match_dynamic_names?(flat_name) } if @dynamic.nil?
          @dynamic
        end

        # returns a array of flat names
        def flat_names
          @flat_names ||= _generate_flat_names.uniq
        end

        private

        def _validate_name
          invalid_name = flat_names.detect { |flat_name| !self.class.match_valid_names?(flat_name) }

          invalid!("is invalid!", :name) if invalid_name.present?
        end

        def _validate_static_name
          return true unless static?
          return true if ['missing', 'close'].include?(_table_status)

          invalid!("is static - this setting can only be changed on a closed index!", :name)
        end

        def _validate_final_name
          return true unless final?
          return true if _table_status == 'missing'

          invalid!("is final - this setting can only be set at index creation time!", :name)
        end

        def _generate_flat_names(parent = name, current = value)
          ret = []
          if current.is_a?(Hash)
            current.each do |k, v|
              ret += _generate_flat_names("#{parent}.#{k}", v)
            end
          else
            ret << parent.to_s
          end

          ret
        end

        def _table_status
          return 'missing' unless state?
          state[:status]
        end
      end
    end
  end
end
