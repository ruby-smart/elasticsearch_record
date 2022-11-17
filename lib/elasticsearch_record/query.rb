module ElasticsearchRecord
  class Query
    # STATUS CONSTANTS
    STATUS_VALID  = :valid
    STATUS_FAILED = :failed

    # TYPE CONSTANTS
    TYPE_UNDEFINED = :undefined

    # - QUERY TYPES
    TYPE_COUNT   = :count
    TYPE_SEARCH  = :search
    TYPE_MSEARCH = :msearch
    TYPE_SQL     = :sql

    # - DOCUMENT TYPES
    TYPE_CREATE          = :create
    TYPE_UPDATE          = :update
    TYPE_UPDATE_BY_QUERY = :update_by_query
    TYPE_DELETE          = :delete
    TYPE_DELETE_BY_QUERY = :delete_by_query

    # - INDEX TYPES
    TYPE_INDEX_CREATE = :index_create

    # includes valid types only
    TYPES = [TYPE_COUNT, TYPE_SEARCH, TYPE_MSEARCH, TYPE_SQL, TYPE_CREATE, TYPE_UPDATE,
             TYPE_UPDATE_BY_QUERY, TYPE_DELETE, TYPE_DELETE_BY_QUERY, TYPE_INDEX_CREATE].freeze

    # includes reading types only
    READ_TYPES = [TYPE_COUNT, TYPE_SEARCH, TYPE_MSEARCH, TYPE_SQL].freeze

    # defines a body to be executed if the query fails - +(none)+ queries
    # acts like the SQL-query "where('1=0')"
    FAILED_SEARCH_BODY = { size: 0, query: { bool: { filter: [{ term: { _id: '_' } }] } } }.freeze

    # defines special api gates to be used per type.
    # if not defined it simply uses +[:core,self.type]+
    GATES = {
      TYPE_SQL          => [:sql, :query],
      TYPE_INDEX_CREATE => [:indices, :create],
    }

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

    # defines the query body - in most cases this is a hash
    # @!attribute Hash
    attr_reader :body

    # defines the query arguments to be passed to the API
    # @!attribute Hash
    attr_reader :arguments

    # defines the columns to assign from the query
    # @!attribute Array
    attr_reader :columns

    def initialize(index: nil, type: TYPE_UNDEFINED, status: STATUS_VALID, body: nil, refresh: nil, arguments: {}, columns: [])
      @index     = index
      @type      = type
      @status    = status
      @refresh   = refresh
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

    # builds the final query arguments.
    # Depends on the query status, index, body & refresh attributes.
    # Also used possible PRE-defined arguments to be merged with those mentioned attributes.
    # @return [Hash]
    def query_arguments
      # check for failed status
      return { index: self.index, body: FAILED_SEARCH_BODY } if self.status == STATUS_FAILED

      args           = @arguments.deep_dup

      # set index, if present
      args[:index]   = self.index if self.index.present?

      # set body, if present
      args[:body]    = self.body if self.body.present?

      # set refresh, if defined (also includes false value)
      args[:refresh] = self.refresh unless self.refresh.nil?

      args
    end

    alias :to_query :query_arguments
  end
end
