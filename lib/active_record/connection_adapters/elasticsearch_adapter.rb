# frozen_string_literal: true

require 'active_record/connection_adapters'

require 'active_record/connection_adapters/elasticsearch/unsupported_implementation'

require 'active_record/connection_adapters/elasticsearch/column'
require 'active_record/connection_adapters/elasticsearch/database_statements'
require 'active_record/connection_adapters/elasticsearch/quoting'
require 'active_record/connection_adapters/elasticsearch/schema_creation'
require 'active_record/connection_adapters/elasticsearch/schema_definitions'
require 'active_record/connection_adapters/elasticsearch/schema_dumper'
require 'active_record/connection_adapters/elasticsearch/schema_statements'
require 'active_record/connection_adapters/elasticsearch/type'
require 'active_record/connection_adapters/elasticsearch/table_statements'
require 'active_record/connection_adapters/elasticsearch/transactions'

require 'arel/visitors/elasticsearch'
require 'arel/collectors/elasticsearch_query'

gem 'elasticsearch'
require 'elasticsearch'

module ActiveRecord # :nodoc:
  module ConnectionHandling # :nodoc:
    def elasticsearch_adapter_class
      ConnectionAdapters::ElasticsearchAdapter
    end

    def elasticsearch_connection(config)
      elasticsearch_adapter_class.new(config)
    end
  end

  module ConnectionAdapters # :nodoc:
    class ElasticsearchAdapter < AbstractAdapter
      # defines the *Elasticsearch* adapter name.
      ADAPTER_NAME = "Elasticsearch"

      # defines the Elasticsearch 'base' structure, which is always included but cannot be resolved through mappings ...
      BASE_STRUCTURE = [
        { 'name' => '_id', 'type' => 'keyword', 'meta' => { 'primary_key' => 'true' } },
        { 'name' => '_index', 'type' => 'keyword', 'virtual' => true },
        { 'name' => '_score', 'type' => 'float', 'virtual' => true },
        { 'name' => '_type', 'type' => 'keyword', 'virtual' => true },
        { 'name' => '_ignored', 'type' => 'boolean', 'virtual' => true }
      ].freeze

      include Elasticsearch::UnsupportedImplementation
      include Elasticsearch::Quoting
      include Elasticsearch::DatabaseStatements
      include Elasticsearch::SchemaStatements
      include Elasticsearch::TableStatements
      include Elasticsearch::Transactions

      class << self
        def base_structure_keys
          # using a class_variable to not reinitialize for descendants
          @@base_structure_keys ||= BASE_STRUCTURE.map { |struct| struct['name'] }.freeze
        end

        def new_client(config)
          # IMPORTANT: remove +adapter+ from config - otherwise we mess up with Faraday::AdapterRegistry
          client_config          = config.except(:adapter)
          # add rails logger manually, if +:log+ is true
          client_config[:logger] = logger if client_config.delete(:log)

          # build an return new client
          ::Elasticsearch::Client.new(client_config)
        rescue ::Elastic::Transport::Transport::Errors::Unauthorized
          raise ::ActiveRecord::DatabaseConnectionError.username_error(config[:user])
        rescue ::Elastic::Transport::Transport::ServerError => error
          raise ::ActiveRecord::ConnectionNotEstablished, error.message
        end

        private

        def initialize_type_map(m)
          m.register_type 'binary', Type::Binary.new
          m.register_type 'boolean', Type::Boolean.new
          m.register_type 'keyword', Type::String.new

          m.alias_type 'constant_keyword', 'keyword'
          m.alias_type 'wildcard', 'keyword'

          # maybe use integer 8 here ...
          m.register_type 'long', Type::BigInteger.new
          m.register_type 'integer', Type::Integer.new
          m.register_type 'short', Type::Integer.new(limit: 2)
          m.register_type 'byte', Type::Integer.new(limit: 1)
          m.register_type 'double', Type::Float.new(limit: 8)
          m.register_type 'float', Type::Float.new(limit: 4)
          m.register_type 'half_float', Type::Float.new(limit: 2)
          m.register_type 'scaled_float', Type::Float.new(limit: 8, scale: 8)
          m.register_type 'unsigned_long', Type::UnsignedInteger.new

          m.register_type 'date', Type::DateTime.new

          # force a hash
          m.register_type 'object', ActiveRecord::ConnectionAdapters::Elasticsearch::Type::Object.new
          m.alias_type 'flattened', "object"

          # array of objects
          m.register_type 'nested', ActiveRecord::ConnectionAdapters::Elasticsearch::Type::Nested.new

          ip_type = ActiveRecord::ConnectionAdapters::Elasticsearch::Type::FormatString.new(format: /^((25[0-5]|(2[0-4]|1\d|[1-9]|)\d)\.?\b){4}$/)

          m.register_type 'integer_range', ActiveRecord::ConnectionAdapters::Elasticsearch::Type::Range.new(nested_type: Type::Integer.new)
          m.register_type 'float_range', ActiveRecord::ConnectionAdapters::Elasticsearch::Type::Range.new(nested_type: Type::Float.new(limit: 4))
          m.register_type 'long_range', ActiveRecord::ConnectionAdapters::Elasticsearch::Type::Range.new(nested_type: Type::Integer.new(limit: 8))
          m.register_type 'double_range', ActiveRecord::ConnectionAdapters::Elasticsearch::Type::Range.new(nested_type: Type::Float.new(limit: 8))
          m.register_type 'date_range', ActiveRecord::ConnectionAdapters::Elasticsearch::Type::Range.new(nested_type: Type::DateTime.new)
          m.register_type 'ip_range', ActiveRecord::ConnectionAdapters::Elasticsearch::Type::Range.new(nested_type: ip_type)

          m.register_type 'ip', ip_type
          m.register_type 'version', ActiveRecord::ConnectionAdapters::Elasticsearch::Type::FormatString.new(format: /^\d+\.\d+\.\d+[\-\+A-Za-z\.]*$/)
          # m.register_type 'murmur3', Murmur3.new

          m.register_type 'text', Type::Text.new

          # this special Type is required to parse a ES-value into the +nested_type+, array or hash.
          # For arrays & hashes it tries to cast the values with the provided +nested_type+
          # but falls back to provided value if cast fails.
          # This type cannot be accessed through the mapping and is only called @ #lookup_cast_type_from_column
          # @see ActiveRecord::ConnectionAdapters::Elasticsearch::SchemaStatements#lookup_cast_type_from_column
          m.register_type :multicast_value do |_type, nested_type|
            ActiveRecord::ConnectionAdapters::Elasticsearch::Type::MulticastValue.new(nested_type: nested_type)
          end
        end
      end

      # reinitialize the constant with new types
      TYPE_MAP = ActiveRecord::Type::HashLookupTypeMap.new.tap { |m| initialize_type_map(m) }

      # define native types - which will be used for schema-dumping
      NATIVE_DATABASE_TYPES = {
        primary_key: { name: 'long' }, # maybe this hae to changed to 'keyword'
        string:   { name: 'keyword' },
        blob:     { name: 'binary' },
        datetime: { name: 'date' },
        bigint:   { name: 'long' },
        json:     { name: 'object' }
      }.merge(
        TYPE_MAP.keys.map { |key| [key.to_sym, { name: key }] }.to_h
      )

      def initialize(...)
        super

        # transform provided config
        config         = @config.dup

        # move 'username' to 'user'
        config[:user]  = config.delete(:username) if config[:username]

        # append 'port' to 'host'
        config[:host]  += ":#{config.delete(:port)}" if config[:port] && config[:host]

        # move 'host' to 'hosts'
        config[:hosts] = config.delete(:host) if config[:host]

        @connection_parameters = config
      end

      def schema_migration # :nodoc:
        ElasticsearchRecord::SchemaMigration.new(self)
      end

      # provide a table_name_prefix from the configuration to create & restrict schema creation
      def table_name_prefix
        @config.fetch(:table_name_prefix, '')
      end

      # provide a table_name_suffix from the configuration to create & restrict schema creation
      def table_name_suffix
        @config.fetch(:table_name_suffix, '')
      end

      # overwrite method to provide a Elasticsearch path
      def migrations_paths
        @config[:migrations_paths] || ['db/migrate_elasticsearch']
      end

      # prepared statements are not supported by Elasticsearch.
      # documentation for mysql prepares statements @ https://dev.mysql.com/doc/refman/8.0/en/sql-prepared-statements.html
      def default_prepared_statements
        false
      end

      # Does this adapter support transactions in general?
      # HINT: This is +NOT* an official setting and only introduced to ElasticsearchRecord
      def supports_transactions?
        false
      end

      # Does this adapter support explain?
      def supports_explain?
        false
      end

      # Does this adapter support creating indexes in the same statement as
      # creating the table?
      def supports_indexes_in_create?
        false
      end

      # Does this adapter support metadata comments on database objects (tables)?
      # PLEASE NOTE: Elasticsearch does only support comments on mappings as 'meta' information.
      # This method only relies to create comments on tables (indices) and is therefore not supported.
      # see @ ActiveRecord::ConnectionAdapters::SchemaStatements#create_table
      def supports_comments?
        false
      end

      # Can comments for tables, columns, and indexes be specified in create/alter table statements?
      # see @ ActiveRecord::ConnectionAdapters::ElasticsearchAdapter#supports_comments?
      def supports_comments_in_create?
        false
      end

      # disable metadata tables
      def use_metadata_table? # :nodoc:
        false
      end

      # returns a hash of 'ActiveRecord types' -> 'Elasticsearch types' (defined @ +NATIVE_DATABASE_TYPES+)
      # @return [Hash]
      def native_database_types # :nodoc:
        NATIVE_DATABASE_TYPES
      end

      # calls the +elasticsearch-api+ endpoints by provided namespace and action.
      # if a block was provided it'll yield the response.body and returns the blocks result.
      # otherwise it will return the response itself...
      # @param [Symbol] namespace - the API namespace (e.g. indices, nodes, sql, ...)
      # @param [Symbol] action - the API action to call in tha namespace
      # @param [Hash] arguments - action arguments
      # @param [String (frozen)] name - the logging name
      # @param [Boolean] async - send async (default: false) - currently not supported
      # @param [Boolean] log - send log to instrumenter (default: true)
      # @return [Elasticsearch::API::Response, Object]
      def api(namespace, action, arguments = {}, name = 'API', async: false, log: true)
        raise ::StandardError, 'ASYNC api calls are not supported' if async

        # resolve the API target
        target = namespace == :core ? raw_connection : raw_connection.__send__(namespace)

        __send__(:log, "#{namespace}.#{action}", arguments, name, async: async, log: log) do
          response = ActiveSupport::Dependencies.interlock.permit_concurrent_loads do
            target.__send__(action, arguments)
          end

          if response.is_a?(::Elasticsearch::API::Response)
            # reverse information for the LogSubscriber - shows the 'query-time' in the logs
            # this works, since we use a referenced hash ...
            arguments[:_qt] = response['took']

            # raise timeouts
            raise(ActiveRecord::StatementTimeout, "Elasticsearch api request failed due a timeout") if response['timed_out']
          end

          response
        end
      end

      private

      def connect
        @raw_connection = self.class.new_client(@connection_parameters)
      rescue ::ActiveRecord::ConnectionNotEstablished => ex
        raise ex.set_pool(@pool)
      end

      def reconnect
        @raw_connection = nil
        connect
      end

      def active?
        !!@raw_connection&.ping
      end

      # Disconnects from the database if already connected.
      # Otherwise, this method does nothing.
      def disconnect!
        super
        @raw_connection = nil
      end

      alias :reset! :reconnect!

      def type_map
        TYPE_MAP
      end

      # catch Elasticsearch Transport-errors to be treated as +StatementInvalid+ (the original message is still readable ...)
      def translate_exception(exception, message:, sql:, binds:)
        case exception
        when ::Elastic::Transport::Transport::Errors::ClientClosedRequest
          ::ActiveRecord::QueryCanceled.new(message, sql: sql, binds: binds)
        when ::Elastic::Transport::Transport::Errors::RequestTimeout
          ::ActiveRecord::StatementTimeout.new(message, sql: sql, binds: binds)
        when ::Elastic::Transport::Transport::Errors::Conflict
          ::ActiveRecord::RecordNotUnique.new(message, sql: sql, binds: binds)
        when ::Elastic::Transport::Transport::Errors::BadRequest
          if exception.message.match?(/resource_already_exists_exception/)
            ::ActiveRecord::DatabaseAlreadyExists.new(message, sql: sql, binds: binds)
          else
            ::ActiveRecord::StatementInvalid.new(message, sql: sql, binds: binds)
          end
        when ::Elastic::Transport::Transport::Errors::Unauthorized
          ::ActiveRecord::DatabaseConnectionError.username_error(@config[:username])
          # must be last 'Elastic' error
        when ::Elastic::Transport::Transport::ServerError
          ::ActiveRecord::StatementInvalid.new(message, sql: sql, binds: binds)
        else
          # just forward the exception ...
          exception
        end
      end

      # provide a custom log instrumenter for elasticsearch subscribers
      def log(gate, arguments, name, async: false, log: true, &block)
        if log
          @instrumenter.instrument(
            "query.elasticsearch_record",
            gate:      gate,
            name:      name,
            arguments: gate == 'core.msearch' ? arguments.deep_dup : arguments,
            async:     async) do
            @lock.synchronize(&block)
          rescue => e
            raise translate_exception_class(e, arguments, [])
          end
        else
          begin
            @lock.synchronize(&block)
          rescue => e
            raise translate_exception_class(e, arguments, [])
          end
        end
      end

      # returns a new collector for the Arel visitor.
      # @return [Arel::Collectors::ElasticsearchQuery]
      def collector
        # IMPORTANT: prepared statements doesn't make sense for elasticsearch,
        # so we don't have to check for +prepared_statements+ here.
        # Also, bindings are (currently) not supported.
        # So, we just need a single, simple query collector...
        Arel::Collectors::ElasticsearchQuery.new
      end

      # returns a new visitor to compile Arel into Elasticsearch Hashes (in this case we use a query object)
      # @return [Arel::Visitors::Elasticsearch]
      def arel_visitor
        Arel::Visitors::Elasticsearch.new(self)
      end

      # Builds the result object.
      # This is an internal hook to make possible connection adapters to build
      # custom result objects with response-specific data.
      # @return [ElasticsearchRecord::Result]
      def build_result(response, columns: [], column_types: {})
        ElasticsearchRecord::Result.new(response, columns, column_types)
      end

      # register native types
      ActiveRecord::Type.register(:format_string, ActiveRecord::ConnectionAdapters::Elasticsearch::Type::FormatString, adapter: :elasticsearch)
      ActiveRecord::Type.register(:multicast_value, ActiveRecord::ConnectionAdapters::Elasticsearch::Type::MulticastValue, adapter: :elasticsearch)
      ActiveRecord::Type.register(:object, ActiveRecord::ConnectionAdapters::Elasticsearch::Type::Object, adapter: :elasticsearch, override: false)
      ActiveRecord::Type.register(:range, ActiveRecord::ConnectionAdapters::Elasticsearch::Type::Range, adapter: :elasticsearch)
    end
  end
end