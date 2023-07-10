# frozen_string_literal: true

module ElasticsearchRecord
  class ModelApi
    attr_reader :klass

    def initialize(klass)
      @klass = klass
    end

    # undelegated schema methods: clone rename create
    # those should not be quick-accessible, since they might end in heavily broken index

    # delegated dangerous methods (created with exclamation mark)
    # not able to provide individual arguments - always the defaults will be used!
    #
    # @example
    #   open!
    #   close!
    #   refresh!
    #   block!
    #   unblock!
    %w(open close refresh block unblock).each do |method|
      define_method("#{method}!") do
        _connection.send("#{method}_table", _index_name)
      end
    end

    # delegated dangerous methods with confirm parameter (created with exclamation mark)
    # a exception will be raised, if +confirm:true+ is missing.
    #
    # @example
    #   drop!(confirm: true)
    #   truncate!(confirm: true)
    %w(drop truncate).each do |method|
      define_method("#{method}!") do |confirmed: false|
        raise "#{method} of table '#{_index_name}' aborted!\nexecution not confirmed!\ncall with: #{klass}.api.#{method}!(confirmed: true)" unless confirmed
        _connection.send("#{method}_table", _index_name)
      end
    end

    # delegated table methods
    #
    # @example
    #   mappings
    #   metas
    #   settings
    #   aliases
    #   state
    #   schema
    #   exists?
    %w(mappings metas settings aliases state schema exists?).each do |method|
      define_method(method) do |*args|
        _connection.send("table_#{method}", _index_name, *args)
      end
    end

    # delegated plain methods
    #
    # @example
    #   alias_exists?
    #   setting_exists?
    #   mapping_exists?
    #   meta_exists?
    %w(alias_exists? setting_exists? mapping_exists? meta_exists?).each do |method|
      define_method(method) do |*args|
        _connection.send(method, _index_name, *args)
      end
    end

    # fast insert/update data.
    #
    # @example
    #   index([{name: 'Hans', age: 34}, {name: 'Peter', age: 22}])
    #
    #   index({id: 5, name: 'Georg', age: 87})
    #
    # @param [Array<Hash>,Hash] data
    # @param [Hash] options
    def index(data, **options)
      bulk(data, :index, **options)
    end

    # fast insert new data.
    #
    # @example
    #   insert([{name: 'Hans', age: 34}, {name: 'Peter', age: 22}])
    #
    #   insert({name: 'Georg', age: 87})
    #
    # @param [Array<Hash>,Hash] data
    # @param [Hash] options
    def insert(data, **options)
      bulk(data, :create, **options)
    end

    # fast update existing data.
    #
    # @example
    #   update([{id: 1, name: 'Hansi'}, {id: 2, name: 'Peter Parker', age: 42}])
    #
    #   update({id: 3, name: 'Georg McCain'})
    #
    # @param [Array<Hash>,Hash] data
    # @param [Hash] options
    def update(data, **options)
      bulk(data, :update, **options)
    end

    # fast delete data.
    #
    # @example
    #   delete([1,2,3,5])
    #
    #   delete(3)
    #
    #   delete({id: 2})
    #
    # @param [Array<Hash>,Hash] data
    # @param [Hash] options
    def delete(data, **options)
      data = [data] unless data.is_a?(Array)

      if data[0].is_a?(Hash)
        bulk(data, :delete, **options)
      else
        bulk(data.map { |id| { id: id } }, :delete, **options)
      end
    end

    # bulk handle provided data (single Hash or multiple Array<Hash>).
    # @param [Hash,Array<Hash>] data - the data to insert/update/delete ...
    # @param [Symbol] operation
    # @param [Boolean, Symbol] refresh
    def bulk(data, operation = :index, refresh: true, **options)
      data = [data] unless data.is_a?(Array)

      _connection.api(:core, :bulk, {
        index:   _index_name,
        body:    data.map { |item| { operation => { _id: item[:id], data: item.except(:id) } } },
        refresh: refresh
      }, "BULK #{operation.to_s.upcase}", **options)
    end

    private

    def _index_name
      klass.index_name
    end

    def _connection
      klass.connection
    end
  end
end