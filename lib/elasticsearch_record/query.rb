module ElasticsearchRecord
  class Query
    # STATUS CONSTANTS
    STATUS_VALID  = :valid
    STATUS_FAILED = :failed

    # -- UNDEFINED TYPE ------------------------------------------------------------------------------------------------
    TYPE_UNDEFINED = :undefined

    # -- QUERY TYPES ---------------------------------------------------------------------------------------------------
    TYPE_COUNT   = :count
    TYPE_SEARCH  = :search
    TYPE_MSEARCH = :msearch
    TYPE_SQL     = :sql

    # -- DOCUMENT TYPES ------------------------------------------------------------------------------------------------
    TYPE_CREATE          = :create
    TYPE_UPDATE          = :update
    TYPE_UPDATE_BY_QUERY = :update_by_query
    TYPE_DELETE          = :delete
    TYPE_DELETE_BY_QUERY = :delete_by_query

    # -- INDEX TYPES ---------------------------------------------------------------------------------------------------
    TYPE_INDEX_CREATE = :index_create
    TYPE_INDEX_CLONE  = :index_clone
    # INDEX update is not implemented by Elasticsearch
    # - this is handled through individual updates of +mappings+, +settings+ & +aliases+.
    # INDEX delete is handled directly as API-call
    TYPE_INDEX_UPDATE_MAPPING = :index_update_mapping
    TYPE_INDEX_UPDATE_SETTING = :index_update_setting
    TYPE_INDEX_UPDATE_ALIAS   = :index_update_alias
    TYPE_INDEX_DELETE_ALIAS   = :index_delete_alias

    # includes valid types only
    TYPES = [
      # -- QUERY TYPES
      TYPE_COUNT, TYPE_SEARCH, TYPE_MSEARCH, TYPE_SQL,
      # -- DOCUMENT TYPES
      TYPE_CREATE, TYPE_UPDATE, TYPE_UPDATE_BY_QUERY, TYPE_DELETE, TYPE_DELETE_BY_QUERY,

      # -- INDEX TYPES
      TYPE_INDEX_CREATE, TYPE_INDEX_CLONE,
      TYPE_INDEX_UPDATE_MAPPING, TYPE_INDEX_UPDATE_SETTING, TYPE_INDEX_UPDATE_ALIAS,
      TYPE_INDEX_DELETE_ALIAS
    ].freeze

    # includes reading types only
    READ_TYPES = [
      TYPE_COUNT, TYPE_SEARCH, TYPE_MSEARCH, TYPE_SQL
    ].freeze

    # defines a body to be executed if the query fails - +(none)+
    # acts like the SQL-query "where('1=0')"
    FAILED_BODIES = {
      TYPE_SEARCH => { size: 0, query: { bool: { filter: [{ term: { _id: '_' } }] } } },
      TYPE_COUNT  => { query: { bool: { filter: [{ term: { _id: '_' } }] } } }
    }.freeze

    # defines special api gates to be used per type.
    # if no special type is defined, it simply uses +[:core,self.type]+
    GATES = {
      TYPE_SQL                  => [:sql, :query],
      TYPE_INDEX_CREATE         => [:indices, :create],
      TYPE_INDEX_CLONE          => [:indices, :clone],
      TYPE_INDEX_UPDATE_MAPPING => [:indices, :put_mapping],
      TYPE_INDEX_UPDATE_SETTING => [:indices, :put_settings],
      TYPE_INDEX_UPDATE_ALIAS   => [:indices, :put_alias],
      TYPE_INDEX_DELETE_ALIAS   => [:indices, :delete_alias],
    }.freeze

    # defines the index the query should be executed on
    # @!attribute String
    attr_reader :index

    # defines the query type.
    # @see TYPES
    # @!attribute Symbol
    attr_reader :type

    # defines the query status.
    # @see STATUSES
    # @!attribute Symbol
    attr_reader :status

    # defines if the affected shards gets refreshed to make this operation visible to search
    # @!attribute Boolean
    attr_reader :refresh

    # defines the query timeout
    # @!attribute Integer|String
    attr_reader :timeout

    # defines the query arguments to be passed to the API
    # @!attribute Hash
    attr_reader :arguments

    # defines the columns to assign from the query
    # @!attribute Array
    attr_reader :columns

    def initialize(index: nil, type: TYPE_UNDEFINED, status: STATUS_VALID, body: nil, refresh: nil, timeout: nil, arguments: {}, columns: [])
      @index     = index
      @type      = type
      @status    = status
      @refresh   = refresh
      @timeout   = timeout
      @body      = body
      @arguments = arguments
      @columns   = columns
    end

    # sets the failed status for this query.
    # returns self
    # @return [ElasticsearchRecord::Query]
    def failed!
      @status = STATUS_FAILED

      self
    end

    # returns true, if the query is valid (e.g. index & type defined)
    # @return [Boolean]
    def valid?
      # type mus be valid + index must be present (not required for SQL)
      TYPES.include?(self.type) #&& (index.present? || self.type == TYPE_SQL)
    end

    # returns the API gate to be called to execute the query.
    # each query type needs a different endpoint.
    # @see Elasticsearch::API
    # @return [Array<Symbol, Symbol>] - API gate [<namespace>,<action>]
    def gate
      GATES[self.type].presence || [:core, self.type]
    end

    # returns true if this is a write query
    # @return [Boolean]
    def write?
      !READ_TYPES.include?(self.type)
    end

    # returns the query body - depends on the +status+!
    # failed queried will return the related +FAILED_BODIES+ or +{}+ as fallback
    # @return [Hash, nil]
    def body
      return (FAILED_BODIES[self.type].presence || {}) if self.status == STATUS_FAILED

      @body
    end

    # builds the final query arguments.
    # Depends on the query status, index, body & refresh attributes.
    # Also used possible PRE-defined arguments to be merged with those mentioned attributes.
    # @return [Hash]
    def query_arguments
      args           = @arguments.deep_dup

      # set index, if present
      args[:index]   = self.index if self.index.present?

      # set body, if present
      args[:body]    = self.body if self.body.present?

      # set refresh, if defined (also includes false value)
      args[:refresh] = self.refresh unless self.refresh.nil?

      # set timeout, if present
      args[:timeout] = self.timeout if self.timeout.present?

      args
    end

    alias :to_query :query_arguments
  end
end
