module ElasticsearchRecord
  class Query
    # STATUS CONSTANTS
    STATUS_VALID  = :valid
    STATUS_FAILED = :failed

    # TYPE CONSTANTS
    TYPE_UNDEFINED       = :undefined
    TYPE_SEARCH          = :search
    TYPE_MSEARCH         = :msearch
    TYPE_CREATE          = :create
    TYPE_UPDATE          = :update
    TYPE_UPDATE_BY_QUERY = :update_by_query
    TYPE_DELETE          = :delete
    TYPE_DELETE_BY_QUERY = :delete_by_query

    TYPES = [TYPE_SEARCH, TYPE_MSEARCH, TYPE_CREATE, TYPE_UPDATE, TYPE_UPDATE_BY_QUERY, TYPE_DELETE, TYPE_DELETE_BY_QUERY].freeze
    # defines which queries are read & write queries ...
    READ_TYPES = [TYPE_SEARCH, TYPE_MSEARCH].freeze

    # defines a query to be executed if the query fails - +(none)+ queries
    # acts like the SQL-query "where('1=0')"
    FAILED_SEARCH_BODY = { size: 0, query: { bool: { filter: [{ term: { _id: '_' } }] } } }.freeze

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
    attr_accessor :body

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
      index.present? && TYPES.include?(self.type)
    end

    # returns the API gate to be called to execute the query.
    # each query type needs a different endpoint.
    # @see Elasticsearch::API
    # @return [Array<Symbol>,<Symbol>] [<namespace>,<action>]
    def api_gate
      [:core, self.type]
    end

    # returns true if this is a write query
    # @return [Boolean]
    def write?
      # please mention the +!+ NOT operator
      !READ_TYPES.include?(self.type)
    end

    # builds the final query arguments.
    # Depends on the query status, index, body & refresh attributes.
    # Also used possible PRE-defined arguments to be merged with those mentioned attributes.
    # @return [Hash]
    def arguments
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

    alias :to_query :arguments
  end
end
